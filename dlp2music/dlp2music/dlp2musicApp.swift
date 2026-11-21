//
//  dlp2musicApp.swift
//  dlp2music
//
//  Created by Michel Storms on 19/02/2025.
//

import SwiftUI
import AppKit
import Sparkle

@main
struct dlp2musicApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var iMessageWatcher = IMessageWatcher()

    /// Sparkle: reads SUFeedURL / SUPublicEDKey from CatchMatch-Info.plist and
    /// schedules background checks (SUEnableAutomaticChecks). #100
    /// Never started in a Setapp copy: Setapp delivers its updates (#107).
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: !Constants.isSetappBuild,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding: Bool = false
    @State private var showOnboarding: Bool = false
    @StateObject private var settings = AppSettings.shared
    @State private var didHandleLaunch = false

    @AppStorage("imessageWatcherEnabled") private var imessageEnabled: Bool = false
    @AppStorage("imessageWatcherChatGUID") private var imessageChatGUID: String = ""
    @AppStorage("imessageWatcherChatLabel") private var imessageChatLabel: String = ""

    init() {
        // Before any view exists, because @AppStorage reads its value the first
        // time the body is evaluated — an onAppear migration would already be
        // too late.
        Self.migrateMusicDestinationIfNeeded()
        Self.migrateDownloadsDestinationIfNeeded()
    }

    /// The Music destination used to be one setting. Someone who had it off — a
    /// TV-only user — would otherwise inherit the new video half's default of on,
    /// quietly turning Music imports back on for them. Seed the new key from the
    /// old one once, the first time this version runs.
    private static func migrateMusicDestinationIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "importToMusicVideo") == nil else { return }
        defaults.set(defaults.object(forKey: "importToMusic") as? Bool ?? true,
                     forKey: "importToMusicVideo")
    }

    /// Downloads used to be one setting that mirrored the libraries: the song
    /// when Song was on, the video when Video or TV was, the video when nothing
    /// else was. It is now two chips (#164); seed them once from that rule so
    /// someone who had Downloads on keeps getting the same files.
    private static func migrateDownloadsDestinationIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "importToDownloadsAudio") == nil else { return }
        guard defaults.bool(forKey: "importToDownloads") else {
            defaults.set(false, forKey: "importToDownloadsAudio")
            return
        }
        let musicAudio = defaults.object(forKey: "importToMusic") as? Bool ?? true
        let musicVideo = defaults.object(forKey: "importToMusicVideo") as? Bool ?? true
        let tv = defaults.bool(forKey: "importToTV")
        defaults.set(musicAudio, forKey: "importToDownloadsAudio")
        defaults.set(musicVideo || tv || !musicAudio, forKey: "importToDownloads")
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView(iMessageWatcher: iMessageWatcher)
                .sheet(isPresented: $showOnboarding) {
                    OnboardingView()
                        .onDisappear {
                            if !hasCompletedOnboarding { UsageAnalytics.shared.send(.onboardingCompleted) }
                            hasCompletedOnboarding = true
                        }
                }
                // Without this SwiftUI opens a new window for every catchmatch://
                // link, so each Safari send left another one behind (#84). The
                // existing window takes it instead; one opens only if none is.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                .onOpenURL { url in
                    let fromExtension = ExtensionSender.sentByOurExtension(url)
                    AppLog.shared.log("catchmatch:// link received (from our Safari extension: \(fromExtension))", level: .info)
                    ExternalRequestRouter.shared.accept(url, autoStart: fromExtension)
                }
                .onAppear {
                    if ScreenshotMode.isActive { return } // #105: fixed demo state only
                    if !hasCompletedOnboarding { showOnboarding = true }
                    settings.applyDockIconPolicy()
                    // Menu-bar-only means menu-bar-only: without this the window
                    // still opens at launch, which is exactly the moment it was
                    // asked not to — most visibly when launched at login. Not on
                    // first run, where onboarding needs somewhere to appear.
                    // Settings won't let both this and the menu bar item be off,
                    // so there is always a way back to the window.
                    if !didHandleLaunch {
                        didHandleLaunch = true
                        UsageAnalytics.shared.appLaunched(freshInstall: !hasCompletedOnboarding)
                        if settings.dockIconHidden, hasCompletedOnboarding {
                            DispatchQueue.main.async { NSApp.keyWindow?.close() }
                        }
                    }
                    if imessageEnabled, !imessageChatGUID.isEmpty, FullDiskAccessGuide.isGranted() {
                        iMessageWatcher.start(
                            chatGUID: imessageChatGUID,
                            chatLabel: imessageChatLabel,
                            seedFromLatest: false
                        )
                    }
                }
        }
        .commands {
            // After .newItem, not replacing it: replacing takes SwiftUI's
            // New Window with it, and this is a WindowGroup that supports
            // several windows (#33).
            CommandGroup(after: .newItem) {
                OpenFileCommand()
            }
            CommandGroup(after: .appInfo) {
                if !Constants.isSetappBuild {
                    CheckForUpdatesView(updater: updaterController.updater)
                }
            }
            CommandGroup(after: .help) {
                Button("Run Setup Check…") { showOnboarding = true }
                    .keyboardShortcut("?", modifiers: [.command, .shift])
                Divider()
                Button("Reveal Log in Finder") { AppLog.shared.revealInFinder() }
                Button("Copy Log Path") { AppLog.shared.copyPathToPasteboard() }
                Button("Copy Diagnostics") { AppLog.shared.copyDiagnosticsToPasteboard() }
            }
        }

        Settings {
            SettingsView()
        }

        MenuBarExtra(isInserted: $settings.menuBarEnabled) {
            MenuBarContent()
        } label: {
            Image(systemName: "music.note.list")
        }
        .menuBarExtraStyle(.menu)
    }
}

/// File ▸ Open File…. A view rather than a bare Button so it can reach
/// `openWindow`: with the main window closed — menu-bar-only mode, or the
/// Settings window focused — there is no ContentView to hear the notification,
/// and the command would silently do nothing. #33
private struct OpenFileCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open File…") {
            // A window hosting a queue, rather than whatever happens to be key
            // (Settings, say). nil when there is none.
            let target = NSApp.windows.first { $0.isKeyWindow && $0.identifier?.rawValue.contains("main") == true }
            if target == nil {
                openWindow(id: "main")
                // The new window becomes key; let it settle before asking.
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .openFilePicker, object: nil)
                }
            } else {
                NotificationCenter.default.post(name: .openFilePicker, object: target)
            }
        }
        .keyboardShortcut("o", modifiers: [.command])
    }
}

private struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Show Window") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }
        Divider()
        Button("Reveal Log in Finder") { AppLog.shared.revealInFinder() }
        Button("Copy Diagnostics") { AppLog.shared.copyDiagnosticsToPasteboard() }
        Divider()
        SettingsLink {
            Text("Settings…")
        }
        Divider()
        Button("Quit \(Constants.appName)") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
