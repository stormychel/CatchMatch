//
//  QueueUITests.swift
//  dlp2musicUITests
//
//  Created by Michel Storms on 21/09/2026.
//

import XCTest

/// Drives the real window: adding a link, choosing destinations, clearing.
/// Launched in screenshot mode, so there is no dependency check, no iMessage
/// watcher and no network — and nothing here presses Convert & Import, so no
/// import ever runs. #109
@MainActor
final class QueueUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = launchApp()
    }

    /// `deps` picks the dependency footer: ready, missing, stale or blocked.
    @discardableResult
    private func launchApp(deps: String = "ready") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-SCREENSHOT_DEPS", deps]
        app.launchArguments += [
            "-SCREENSHOT_MODE", "-SCREENSHOT_SCENE", "empty",
            // Argument-domain defaults: this launch only, never persisted.
            "-hasCompletedOnboarding", "YES",
            "-imessageWatcherEnabled", "NO",
            "-showLogDetails", "NO",
            "-SUEnableAutomaticChecks", "NO",
            "-importToMusic", "YES",
            "-importToMusicVideo", "NO",
            "-importToTV", "NO",
            "-importToDownloads", "NO",
            "-importToDownloadsAudio", "NO",
        ]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15), "window did not appear")
        return app
    }

    override func tearDown() {
        app = nil
    }

    private var linkField: XCUIElement {
        app.textFields["Paste or type a link, then press Return"]
    }

    /// Types a link and confirms it landed before pressing Return. Clicking and
    /// typing straight away is a race: if the field has not taken focus yet the
    /// keystrokes are dropped, the queue ends up short, and the failure appears
    /// in whichever test typed next — which is what made this suite flaky.
    private func addLink(_ url: String, file: StaticString = #filePath, line: UInt = #line) {
        let field = linkField
        XCTAssertTrue(field.waitForExistence(timeout: 5), "link field missing", file: file, line: line)

        for attempt in 1...3 {
            field.click()
            field.typeText(url)
            if (field.value as? String) == url { break }

            // Clear whatever partially landed and try again. typeText can't
            // hold down Command — typeKey can.
            field.click()
            app.typeKey("a", modifierFlags: .command)
            app.typeKey(.delete, modifierFlags: [])
            XCTAssertNotEqual(attempt, 3, "the link field never took the text", file: file, line: line)
        }
        field.typeText("\r")
    }

    func testAddingALinkPutsItInTheQueue() {
        addLink("https://archive.org/details/village-hall-sessions")
        let row = app.staticTexts["https://archive.org/details/village-hall-sessions"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the link did not appear in the queue")
    }

    func testTheButtonCountsWhatItWillImport() {
        addLink("https://archive.org/details/one")
        XCTAssertTrue(app.buttons["Convert & Import 1 item"].waitForExistence(timeout: 5),
                      "button did not name one item")

        addLink("https://archive.org/details/two")
        XCTAssertTrue(app.buttons["Convert & Import 2 items"].waitForExistence(timeout: 5),
                      "button did not name two items")
    }

    func testTheSameLinkIsNotQueuedTwice() {
        addLink("https://archive.org/details/same")
        XCTAssertTrue(app.buttons["Convert & Import 1 item"].waitForExistence(timeout: 5))
        addLink("https://archive.org/details/same")
        XCTAssertTrue(app.buttons["Convert & Import 1 item"].exists,
                      "a duplicate link should not add a second row")
    }

    func testClearEmptiesTheQueue() {
        addLink("https://archive.org/details/clear-me")
        let row = app.staticTexts["https://archive.org/details/clear-me"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))

        app.buttons["Clear"].click()
        XCTAssertFalse(row.waitForExistence(timeout: 2), "the row survived Clear")
    }

    /// Only a row's own chips are touched, never the window's defaults: those
    /// are @AppStorage-backed, and clicking them in a test would rewrite the
    /// real user's settings (launch arguments override reads, not writes).
    func testARowsDestinationsCanBeToggled() {
        for id in ["destination.song", "destination.musicVideo",
                   "destination.appleTV", "destination.downloads"] {
            XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 5), "\(id) chip missing")
        }

        addLink("https://archive.org/details/destinations")
        let song = app.buttons["item.song"].firstMatch
        let video = app.buttons["item.musicVideo"].firstMatch
        XCTAssertTrue(song.waitForExistence(timeout: 5), "the row has no Song chip")

        // The launch arguments asked for song-only, so the row starts that way.
        XCTAssertEqual(song.value as? String, "On")
        XCTAssertEqual(video.value as? String, "Off")

        toggle(video, to: "On")
        toggle(song, to: "Off")

        // Turning everything off leaves nothing to import.
        let tv = app.buttons["item.appleTV"].firstMatch
        toggle(tv, to: "On")
        toggle(tv, to: "Off")
        toggle(video, to: "Off")
        XCTAssertTrue(app.buttons["Convert & Import"].waitForExistence(timeout: 3),
                      "with no destination left the button should not offer to import an item")
    }

    /// Downloads is a destination like any other, and works on its own: the
    /// point of it is that no Music library is needed (#111).
    func testAnItemCanGoToDownloadsAlone() {
        addLink("https://archive.org/details/downloads-only")
        let song = app.buttons["item.song"].firstMatch
        let downloads = app.buttons["item.downloads"].firstMatch
        XCTAssertTrue(downloads.waitForExistence(timeout: 5), "the row has no Downloads chip")

        toggle(downloads, to: "On")
        toggle(song, to: "Off")   // leaves Downloads as the only destination
        XCTAssertTrue(app.buttons["Convert & Import 1 item"].waitForExistence(timeout: 3),
                      "an item bound only for Downloads should still be importable")
    }

    /// The window should read as one app, not as a wrapper around two command
    /// line tools — naming a downloader in the interface is also the signal the
    /// positioning work avoids (#113). About keeps its credits, and Show Details
    /// still shows the tools' own output; neither is covered here.
    func testTheWindowDoesNotNameTheTools() {
        // Every dependency state, not just the ready one: the names lived in
        // the missing, stale and blocked footers, so a test that only saw
        // "installed" would pass while every state it was written for regressed.
        for state in ["ready", "missing", "stale", "blocked"] {
            app.terminate()
            app = launchApp(deps: state)
            let offenders = toolNamesVisible()
            XCTAssertTrue(offenders.isEmpty,
                          "the \(state) state names its tools: \(offenders.joined(separator: "; "))")
        }
    }

    /// Every element in the window, not a chosen few types: the footer's status
    /// line is not a button or a checkbox, and an earlier version of this test
    /// missed it for exactly that reason.
    /// Clicks a chip and waits for it to actually flip. Clicking several in a
    /// row without this outruns SwiftUI's update, and the next assertion reads
    /// the old value.
    private func toggle(_ chip: XCUIElement, to expected: String,
                        file: StaticString = #filePath, line: UInt = #line) {
        chip.click()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if (chip.value as? String) == expected { return }
            usleep(100_000)
        }
        XCTFail("chip did not turn \(expected)", file: file, line: line)
    }

    private func toolNamesVisible() -> [String] {
        let banned = ["yt-dlp", "ffmpeg", "FFmpeg", "Homebrew", "brew"]
        var offenders: [String] = []
        for element in app.windows.firstMatch.descendants(matching: .any).allElementsBoundByIndex {
            for text in [element.label, (element.value as? String) ?? ""] where !text.isEmpty {
                for name in banned where text.contains(name) {
                    offenders.append("\(name) in “\(text)”")
                }
            }
        }
        return offenders
    }

    /// ⌘O should mean Open File…, and it has to actually open the panel: an
    /// earlier version of this test only looked at the menu, which passes just
    /// as well when the command is misrouted and does nothing (#33).
    func testOpenFileCommandOpensThePanel() {
        let fileMenu = app.menuBars.menuBarItems["File"]
        XCTAssertTrue(fileMenu.waitForExistence(timeout: 5), "no File menu")
        fileMenu.click()

        let item = app.menuBars.menuItems["Open File…"]
        XCTAssertTrue(item.waitForExistence(timeout: 3), "File menu has no Open File…")
        XCTAssertTrue(item.isEnabled, "Open File… is disabled")
        // Replacing .newItem would have taken New Window with it.
        XCTAssertTrue(app.menuBars.menuItems["New Window"].exists, "New Window is gone")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])

        app.typeKey("o", modifierFlags: .command)
        let panel = app.dialogs.firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 10), "⌘O opened no file panel")
        XCTAssertTrue(panel.buttons["Cancel"].exists, "that dialog is not a file panel")
        panel.buttons["Cancel"].click()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
    }

    /// A file path is not a link: it should be rejected rather than queued as a URL.
    func testRubbishIsRejected() {
        addLink("not a link at all")
        XCTAssertFalse(app.staticTexts["not a link at all"].waitForExistence(timeout: 2),
                       "nonsense was queued as if it were a link")
    }
}
