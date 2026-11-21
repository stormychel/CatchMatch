//
//  ScreenshotMode.swift
//  dlp2music
//
//  Created by Michel Storms on 19/09/2026.
//

import Foundation

/// Marketing-screenshot mode, driven by launch arguments from `ScreenshotTests`
/// (`-SCREENSHOT_MODE -SCREENSHOT_SCENE <scene>`). The window shows a fixed demo
/// state: no dependency check, no iMessage watcher, no onboarding, no network. #105
enum ScreenshotMode {
    /// Debug builds only: in a shipped build the launch argument would be a way
    /// to skip onboarding, licence revalidation, the dependency check and the
    /// iMessage watcher.
    static let isActive: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-SCREENSHOT_MODE")
        #else
        return false
        #endif
    }()

    /// `ready` (default), `missing`, `stale` or `blocked`: which dependency
    /// footer to show. The names this app must not say lived in those states,
    /// so the tests need a way to render them. #113
    static var dependencyState: String {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-SCREENSHOT_DEPS"), i + 1 < args.count else { return "ready" }
        return args[i + 1]
    }

    /// `empty`, `queue` or `imported`; nil outside screenshot mode.
    static var scene: String? {
        guard isActive else { return nil }
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-SCREENSHOT_SCENE"), i + 1 < args.count else { return "queue" }
        return args[i + 1]
    }

    /// Demo inputs. All invented, and all the kind of material the product is
    /// positioned for (#103): own recordings, open archives, purchases.
    /// Never real artists, songs, or streaming-service URLs.
    static let demoInputs: [String] = [
        "https://archive.org/details/village-hall-sessions-1974",
        "/Users/demo/Movies/Garden Gig — June 2026.mov",
        "https://archive.org/details/lecture-listening-to-rooms",
        "https://northfield-choir.bandcamp.com/album/winter-rehearsals",
        "/Users/demo/Movies/Rehearsal Take 3.mp4",
    ]
}
