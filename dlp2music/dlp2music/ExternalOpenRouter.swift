//
//  ExternalOpenRouter.swift
//  dlp2music
//
//  Created by Michel Storms on 30/08/2026.
//

import Foundation
import AppKit

/// Carries files opened from outside the window — a drop on the Dock icon, or
/// Finder's Open With — into the queue.
///
/// A holding pen rather than a notification because the two can race: opening
/// the app *by* dropping a file delivers the event before any view exists to
/// hear it, so the paths wait here until `ContentView` appears and drains them.
@MainActor
final class ExternalOpenRouter: ObservableObject {
    static let shared = ExternalOpenRouter()

    @Published private(set) var pendingPaths: [String] = []

    private init() {}

    func accept(_ urls: [URL]) {
        let paths = urls.filter(\.isFileURL).map(\.path)
        guard !paths.isEmpty else { return }
        pendingPaths.append(contentsOf: paths)
        // Raise the app, but leave *which window* to whichever one takes the
        // paths: picking one here can foreground a different window than the one
        // that ends up holding the file.
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Called by the view once it has queued them.
    func drain() -> [String] {
        defer { pendingPaths.removeAll() }
        return pendingPaths
    }

    /// Surfaces the app. A file arriving from the Dock or Finder is a direct
    /// request, so taking focus is what the user asked for — unlike an unrelated
    /// background event.
    func activate() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeKey }?.makeKeyAndOrderFront(nil)
    }
}

/// Only reason for a delegate: `application(_:open:)` has no SwiftUI equivalent
/// that covers Dock drops.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in ExternalOpenRouter.shared.accept(urls) }
    }
}
