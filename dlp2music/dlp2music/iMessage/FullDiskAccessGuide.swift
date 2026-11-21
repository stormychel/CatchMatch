//
//  FullDiskAccessGuide.swift
//  dlp2music
//
//  Created by Michel Storms on 26/05/2026.
//

import Foundation
import AppKit

/// Probes whether the app currently has Full Disk Access (by trying to open `chat.db`),
/// and helps the user grant it by deep-linking to System Settings.
enum FullDiskAccessGuide {

    static func isGranted() -> Bool {
        // Try to read 1 byte from chat.db; if the file is unreadable we lack FDA.
        let path = MessagesDatabase.defaultPath
        guard FileManager.default.fileExists(atPath: path) else { return false }
        guard let fh = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? fh.close() }
        do {
            _ = try fh.read(upToCount: 1)
            return true
        } catch {
            return false
        }
    }

    /// Deep-link to the Full Disk Access pane in System Settings.
    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }
}
