//
//  AppSettings.swift
//  dlp2music
//
//  Created by Michel Storms on 10/05/2026.
//

import Foundation
import SwiftUI
import ServiceManagement
import AppKit

/// Settings that other views observe through @ObservedObject. We use @Published with
/// manual UserDefaults sync rather than @AppStorage because @AppStorage inside an
/// ObservableObject does not emit objectWillChange — observers (eg the MenuBarExtra
/// scene) wouldn't see updates until an unrelated refresh.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Key {
        static let menuBarEnabled = "menuBarEnabled"
        static let dockIconHidden = "dockIconHidden"
    }

    // Not @Published: that announces a change on every assignment, even of the
    // same value. MenuBarExtra(isInserted:) writes its binding back during scene
    // updates, so every write re-ran the App body, which rebuilt the
    // MenuBarExtra, which wrote the binding again: the app hung at 100% CPU on
    // launch. Only announce real changes.
    var menuBarEnabled: Bool {
        willSet { if newValue != menuBarEnabled { objectWillChange.send() } }
        didSet {
            guard menuBarEnabled != oldValue else { return }
            UserDefaults.standard.set(menuBarEnabled, forKey: Key.menuBarEnabled)
        }
    }

    var dockIconHidden: Bool {
        willSet { if newValue != dockIconHidden { objectWillChange.send() } }
        didSet {
            guard dockIconHidden != oldValue else { return }
            UserDefaults.standard.set(dockIconHidden, forKey: Key.dockIconHidden)
        }
    }

    @Published var launchAtLoginEnabled: Bool

    private init() {
        let defaults = UserDefaults.standard
        self.menuBarEnabled = (defaults.object(forKey: Key.menuBarEnabled) as? Bool) ?? true
        self.dockIconHidden = (defaults.object(forKey: Key.dockIconHidden) as? Bool) ?? false
        self.launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }

    func refreshLaunchAtLogin() {
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }

    /// Toggles SMAppService for the main app. Returns the resulting boolean state.
    @discardableResult
    func setLaunchAtLogin(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            AppLog.shared.log(
                "SMAppService toggle failed (target=\(enabled)): \(error)",
                level: .error
            )
        }
        refreshLaunchAtLogin()
        return launchAtLoginEnabled
    }

    /// Switches between regular (Dock icon visible) and accessory (menu-bar-only)
    /// activation policies. The app's LSUIElement Info.plist value is left as the
    /// default; we toggle the policy at runtime.
    func applyDockIconPolicy() {
        let policy: NSApplication.ActivationPolicy = dockIconHidden ? .accessory : .regular
        NSApp.setActivationPolicy(policy)
    }
}
