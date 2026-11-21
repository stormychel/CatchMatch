//
//  OnboardingCheck.swift
//  dlp2music
//
//  Created by Michel Storms on 10/05/2026.
//

import Foundation
import AppKit

enum OnboardingStatus: Equatable {
    case unknown
    case running
    case pass(String?)
    case fail(String)
    /// Not run yet: running it would raise a system permission prompt, so it
    /// waits for the user to read why and press the row's button (#147).
    case gated
}

struct OnboardingCheck: Identifiable {
    let id: String
    let title: String
    let detail: String
    let runner: () async -> OnboardingStatus
    let fix: OnboardingFix?
    var gate: OnboardingGate? = nil
}

/// Holds back a check whose probe makes macOS ask for a permission. A system
/// prompt that appears on launch, before anything says why, reads as alarming;
/// behind a gate the row explains what's about to be asked, and the prompt only
/// appears once the user presses the button (#147).
struct OnboardingGate {
    /// Rows that would raise the same prompt share a key, so one press opens them all.
    let key: String
    let explanation: String
    let buttonLabel: String

    private var defaultsKey: String { "onboarding.gateOpened.\(key)" }

    /// Once pressed, stays open: macOS asks only once, and after that the check
    /// is a quiet probe like any other.
    var isOpen: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

    func open() { UserDefaults.standard.set(true, forKey: defaultsKey) }
}

struct OnboardingFix {
    let label: String
    /// Awaited before the check re-runs, so a fix that downloads something is
    /// finished before its row is judged again. Quick fixes are plain closures.
    let action: @MainActor () async -> Void
}

enum OnboardingChecks {
    /// Reading Music's settings makes macOS ask for access to Apple Music and
    /// the media library. The folder checks don't: tested on a real Mac, they
    /// pass before the prompt is answered and after Don't Allow (#147).
    static let musicSettingsGate = OnboardingGate(
        key: "media-library",
        explanation: "To see whether your account can sync imports to your other devices, CatchMatch reads Music's settings. macOS will ask you to allow access to Apple Music and your media library. Imports work either way.",
        buttonLabel: "Check Music Settings"
    )

    static func all() -> [OnboardingCheck] {
        [macOSVersion(), musicAutoAddFolder(), syncLibrary(), tvAutoAddFolder(),
         iMessageFullDiskAccess(), ytdlp(), ffmpeg(), network()]
    }

    static func macOSVersion() -> OnboardingCheck {
        OnboardingCheck(
            id: "macos",
            title: "macOS version",
            detail: "Requires macOS 14 (Sonoma) or later.",
            runner: {
                let v = ProcessInfo.processInfo.operatingSystemVersion
                let ok = v.majorVersion >= 14
                return ok
                    ? .pass("macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)")
                    : .fail("macOS \(v.majorVersion).\(v.minorVersion) is too old. Update via System Settings → General → Software Update.")
            },
            fix: nil
        )
    }

    /// Whether imports will reach the user's other devices.
    ///
    /// Nothing here blocks an import: a track lands in the local library either
    /// way. What Sync Library changes is whether it then appears on the phone —
    /// and someone who assumed it would is the person who asks for a refund.
    ///
    /// There is no documented way to read "Sync Library is on" from outside
    /// Music; the flag lives in the library's binary `musicdb`. What *is*
    /// readable is whether the account can do it at all, so the check reports
    /// that and always says where the switch is rather than claiming more
    /// certainty than it has.
    static func syncLibrary() -> OnboardingCheck {
        OnboardingCheck(
            id: "sync-library",
            title: "Apple Music Sync Library",
            detail: "Needed for imported tracks to appear on your other devices. Music → Settings → General → Sync Library.",
            runner: {
                let defaults = UserDefaults(suiteName: "com.apple.Music")
                let subscribed = defaults?.object(forKey: "_MPCloudServiceStatusControllerSubscriptionAvailability") as? Int
                let matchStatus = defaults?.object(forKey: "_MPCloudServiceStatusControllerMatchStatus") as? Int
                let storeSupports = defaults?.object(forKey: "doesStoreSupportCloudMusicLibrary") as? Int

                let libraryPath = ("~/Music/Music/Music Library.musiclibrary" as NSString).expandingTildeInPath
                guard FileManager.default.fileExists(atPath: libraryPath) else {
                    return .fail("No Music library found yet. Open Music once, then re-check.")
                }

                // Never a hard failure. These keys describe what the account
                // *can* do, and they can be absent or stale for reasons that
                // have nothing to do with the user's setup — reporting that as
                // "not eligible" would be wrong more often than it is right.
                if subscribed == 1 || (matchStatus ?? 0) > 0 || storeSupports == 1 {
                    return .pass("This account can use a cloud library — make sure Sync Library is on in Music → Settings → General")
                }
                return .pass("Couldn't tell from here. Imports work either way; they reach your other devices only with Sync Library or iTunes Match on, in Music → Settings → General.")
            },
            fix: OnboardingFix(label: "Open Music") {
                // Music exposes no way to open its settings directly, so this
                // opens the app and the text says which pane to go to.
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Music.app"))
            },
            gate: musicSettingsGate
        )
    }

    static func musicAutoAddFolder() -> OnboardingCheck {
        OnboardingCheck(
            id: "auto-add",
            title: "Apple Music auto-add folder",
            detail: "Tracks dropped here are imported into your Music library automatically.",
            runner: {
                let path = ("~/Music/Music/Media.localized/Automatically Add to Music.localized" as NSString).expandingTildeInPath
                if FileManager.default.fileExists(atPath: path) {
                    return .pass(path)
                }
                return .fail("Open Music.app once to create your library — the auto-add folder is created on first launch.")
            },
            fix: OnboardingFix(label: "Open Music") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Music.app"))
            }
        )
    }

    static func tvAutoAddFolder() -> OnboardingCheck {
        OnboardingCheck(
            id: "tv-auto-add",
            title: "Apple TV auto-add folder (optional)",
            detail: "Only required if you import to the Apple TV library. Music-only workflows can ignore this.",
            runner: {
                let candidates = [
                    "~/Movies/TV/Media.localized/Automatically Add to TV.localized",
                    "~/Movies/TV/TV Media.localized/Automatically Add to TV.localized"
                ].map { ($0 as NSString).expandingTildeInPath }
                if let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
                    return .pass(found)
                }
                return .fail("Open TV.app once to create the auto-add folder. You can ignore this if you only import to Apple Music.")
            },
            fix: OnboardingFix(label: "Open TV") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/TV.app"))
            }
        )
    }

    static func iMessageFullDiskAccess() -> OnboardingCheck {
        OnboardingCheck(
            id: "imessage-fda",
            title: "iMessage chat watcher (optional)",
            detail: "Only required if you enable the iMessage watcher in Settings. Needs Full Disk Access to read ~/Library/Messages/chat.db.",
            runner: {
                FullDiskAccessGuide.isGranted()
                    ? .pass(nil)
                    : .fail("Full Disk Access not granted. Open System Settings and toggle CatchMatch on in Privacy → Full Disk Access, then relaunch the app.")
            },
            fix: OnboardingFix(label: "Open Full Disk Access") {
                FullDiskAccessGuide.openSettings()
            }
        )
    }

    static func ytdlp() -> OnboardingCheck {
        OnboardingCheck(
            id: "yt-dlp",
            title: "Media fetcher",
            detail: "Optional. Needed only when you import from a link — local files don't need it.",
            runner: {
                if which("yt-dlp") != nil { return .pass("Installed") }
                return .fail("Not installed. Install fetches it — there's nothing else to set up.")
            },
            fix: OnboardingFix(label: "Install") {
                _ = await ToolManager.shared.installYtDlp()
            }
        )
    }

    static func ffmpeg() -> OnboardingCheck {
        OnboardingCheck(
            id: "ffmpeg",
            title: "Media converter",
            detail: "Required. Converts the video and extracts the audio.",
            runner: {
                // The pipeline runs both, so one without the other is not installed.
                if which("ffmpeg") != nil && which("ffprobe") != nil { return .pass("Installed") }
                return .fail("Not installed. Install fetches it — there's nothing else to set up.")
            },
            fix: OnboardingFix(label: "Install") {
                _ = await ToolManager.shared.installFfmpeg()
            }
        )
    }

    static func network() -> OnboardingCheck {
        OnboardingCheck(
            id: "network",
            title: "Network reachability",
            detail: "Required to fetch online sources and to install dependencies.",
            runner: {
                let ok = await pingHTTP(URL(string: "https://www.apple.com/library/test/success.html")!)
                return ok ? .pass(nil) : .fail("Couldn't reach the internet. Check your Wi-Fi or Ethernet.")
            },
            fix: nil
        )
    }
}

@discardableResult
private func which(_ tool: String) -> String? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/bash")
    // Same order the pipeline uses, so onboarding can't disagree with the main
    // window about whether a downloaded tool exists.
    let path = ToolManager.managedBinDirectory.path
        + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    task.arguments = ["-lc", "PATH=\"\(path)\" command -v \(tool)"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    do {
        try task.run()
        task.waitUntilExit()
    } catch { return nil }
    guard task.terminationStatus == 0 else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    return (s?.isEmpty == false) ? s : nil
}

private func pingHTTP(_ url: URL) async -> Bool {
    var request = URLRequest(url: url)
    request.timeoutInterval = 4
    request.httpMethod = "HEAD"
    do {
        let (_, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) { return true }
    } catch { return false }
    return false
}
