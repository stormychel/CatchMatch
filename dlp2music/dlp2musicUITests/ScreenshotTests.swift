//
//  ScreenshotTests.swift
//  dlp2musicUITests
//
//  Created by Michel Storms on 19/09/2026.
//

import XCTest

/// Captures the marketing scenes for the Gumroad listing and landing page.
/// Run via Scripts/generate_screenshots.sh; the attachments are pulled out of
/// the xcresult and framed by Scripts/screenshots/compose_screenshots.py. #105
@MainActor
final class ScreenshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchApp(scene: String, showDetails: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-SCREENSHOT_MODE", "-SCREENSHOT_SCENE", scene,
            // Argument-domain defaults: read for this launch only, never persisted.
            "-hasCompletedOnboarding", "YES",
            "-imessageWatcherEnabled", "NO",
            "-showLogDetails", showDetails ? "YES" : "NO",
            "-importToMusic", "YES",
            "-importToMusicVideo", "NO",
            "-importToTV", "YES",
            "-importToDownloads", "NO",
            "-importToDownloadsAudio", "NO",
            "-SUEnableAutomaticChecks", "NO",
        ]
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "CatchMatch window did not appear")

        // A window screenshot is taken from the screen, so anything in front of
        // it lands in the image — a calendar window once ended up in a shot that
        // went on the website. Bring the app forward and let it settle first.
        app.activate()
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        sleep(2)
        return app
    }

    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        // No explicit terminate: the next launch() replaces this instance anyway,
        // and terminate() fails the test when another copy is running.
    }

    func test01Queue() {
        capture("01_Queue", app: launchApp(scene: "queue"))
    }

    func test02Imported() {
        capture("02_Imported", app: launchApp(scene: "imported", showDetails: true))
    }

    func test03Empty() {
        capture("03_Empty", app: launchApp(scene: "empty"))
    }
}
