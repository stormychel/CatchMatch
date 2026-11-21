//
//  StatusLineTests.swift
//  dlp2musicTests
//
//  Created by Michel Storms on 21/09/2026.
//

import Testing
@testable import dlp2music

/// The status line under the button shows the latest log line — except during
/// an install, whose lines are Homebrew's own and name the tools the window is
/// otherwise careful never to name. #80
@MainActor
struct StatusLineTests {

    @Test func anInstallShowsItsOwnMessage() {
        let text = ContentView.statusText(
            installStatus: "Installing components — this can take a few minutes…",
            entries: ["Ready", "Updating Homebrew…", "==> Updating Homebrew..."])
        #expect(text == "Installing components — this can take a few minutes…")
        for name in ["Homebrew", "brew", "yt-dlp", "ffmpeg"] {
            #expect(!text.contains(name), "the status line names \(name)")
        }
    }

    /// Every import announces which tools it found. The status line skips
    /// those and keeps the last line a customer should read.
    @Test func anImportNeverShowsAToolLine() {
        let text = ContentView.statusText(installStatus: nil, entries: [
            "Starting (1 URL)…",
            "Using yt-dlp 2026.08.19 at /opt/homebrew/bin/yt-dlp",
            "Using ffmpeg at /opt/homebrew/bin/ffmpeg",
        ])
        #expect(text == "Starting (1 URL)…")
    }

    @Test func toolNamesAreMatchedAsWords() {
        #expect(ContentView.namesATool("==> Updating Homebrew..."))
        #expect(ContentView.namesATool("ffmpeg failed on clip.mov"))
        #expect(ContentView.namesATool("Using YT-DLP"))
        // Not a tool: "brew" inside another word, or an ordinary line.
        #expect(!ContentView.namesATool("→ Music: Hebrew Folk Songs.m4a"))
        #expect(!ContentView.namesATool("converting: 2:30 of 10:00 (25%)"))
    }

    @Test func otherwiseItShowsTheLatestLine() {
        #expect(ContentView.statusText(installStatus: nil, entries: ["Ready", "Done."]) == "Done.")
    }

    @Test func blankLinesAreSkipped() {
        #expect(ContentView.statusText(installStatus: nil, entries: ["Done.", "", "   "]) == "Done.")
    }

    @Test func anEmptyLogReadsReady() {
        #expect(ContentView.statusText(installStatus: nil, entries: []) == "Ready")
    }
}
