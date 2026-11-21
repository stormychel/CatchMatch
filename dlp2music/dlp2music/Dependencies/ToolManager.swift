//
//  ToolManager.swift
//  dlp2music
//
//  Created by Michel Storms on 30/08/2026.
//

import Foundation
import CryptoKit
import Darwin

/// Installs and updates the tools the pipeline needs without Homebrew.
///
/// Homebrew is the wrong ask for a consumer app: bootstrapping it needs Terminal,
/// the Xcode command line tools and an admin password, none of which can honestly
/// be hidden behind a progress sheet. yt-dlp ships a single self-contained macOS
/// binary and publishes checksums for it, so the app can fetch and verify it
/// directly. ffmpeg and ffprobe are our own LGPL build (Scripts/build_ffmpeg.sh),
/// published on the product site beside their source (#80).
///
/// Binaries live in Application Support rather than the app bundle: the bundle is
/// signed and sealed, so a copy inside it could never update itself — and yt-dlp
/// needs updating on the order of weeks.
@MainActor
final class ToolManager: ObservableObject {
    static let shared = ToolManager()

    enum Progress: Equatable {
        case idle
        case working(String, fraction: Double?)
        case failed(String)
        case done
    }

    @Published private(set) var progress: Progress = .idle

    /// Installs in flight, keyed by tool. The main window and onboarding can
    /// both ask for the same tool; the second caller waits on the first
    /// download instead of starting another that races it for `progress`.
    private var inFlight: [String: Task<Bool, Never>] = [:]

    private init() {}

    private func once(_ key: String, _ work: @escaping @MainActor () async -> Bool) async -> Bool {
        if let running = inFlight[key] { return await running.value }
        let task = Task { await work() }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }

    /// Where downloaded tools live, and the first entry on the pipeline's PATH.
    nonisolated static var managedBinDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("CatchMatch/bin", isDirectory: true)
    }

    nonisolated static var managedYtDlp: URL { managedBinDirectory.appendingPathComponent("yt-dlp") }

    nonisolated static var hasManagedYtDlp: Bool {
        FileManager.default.isExecutableFile(atPath: managedYtDlp.path)
    }

    nonisolated static var managedFfmpeg: URL { managedBinDirectory.appendingPathComponent("ffmpeg") }
    nonisolated static var managedFfprobe: URL { managedBinDirectory.appendingPathComponent("ffprobe") }

    nonisolated static var hasManagedFfmpeg: Bool {
        FileManager.default.isExecutableFile(atPath: managedFfmpeg.path)
            && FileManager.default.isExecutableFile(atPath: managedFfprobe.path)
    }

    /// The licences that came with the ffmpeg build. The LGPL expects them to
    /// travel with the binaries, so they are kept beside them.
    nonisolated static var ffmpegLicensesDirectory: URL {
        managedBinDirectory.deletingLastPathComponent()
            .appendingPathComponent("licenses/ffmpeg", isDirectory: true)
    }

    // MARK: - ffmpeg

    /// Our LGPL ffmpeg and ffprobe, built by Scripts/build_ffmpeg.sh.
    ///
    /// Pinned, unlike yt-dlp: yt-dlp changes weekly, so its checksum has to come
    /// from the same release as the binary; this changes rarely, so its hash is
    /// compiled in, and even a compromised download host can't substitute a
    /// different binary. A new build ships with an app update.
    static let ffmpegArchiveURL = URL(string:
        "https://michelstorms.com/catchmatch/tools/catchmatch-ffmpeg-9.0.2-macos-universal.zip")!
    static let ffmpegArchiveSHA256 = "d0242417f6e03f246ce026869a04e0acb00a4b2074bd27e55eecdf558fdd58b7"

    func installFfmpeg() async -> Bool {
        await once("ffmpeg") { await self.performFfmpegInstall() }
    }

    private func performFfmpegInstall() async -> Bool {
        do {
            progress = .working("Downloading the media converter…", fraction: nil)
            let archive = try await data(from: Self.ffmpegArchiveURL)
            progress = .working("Verifying…", fraction: nil)
            // Hashing, unzipping and writing ~100 MB would stall the window if it
            // ran here on the main actor.
            let expected = Self.ffmpegArchiveSHA256
            try await Task.detached(priority: .userInitiated) {
                try Self.installFfmpegArchive(archive, expectedSHA256: expected,
                                              binDirectory: Self.managedBinDirectory,
                                              licensesDirectory: Self.ffmpegLicensesDirectory)
            }.value
            progress = .done
            return true
        } catch {
            progress = .failed(error.localizedDescription)
            return false
        }
    }

    /// Checks the archive against its pinned hash, unpacks it, and installs
    /// ffmpeg and ffprobe together — both or neither — with their licences.
    /// Separate from the download so it can be tested against a throwaway
    /// directory rather than the user's Application Support.
    nonisolated static func installFfmpegArchive(_ archive: Data, expectedSHA256: String,
                                                 binDirectory: URL, licensesDirectory: URL) throws {
        let actual = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
        guard actual == expectedSHA256 else {
            throw failure("The download didn't match the version this app expects. Nothing was installed.")
        }

        let fileManager = FileManager.default
        let work = fileManager.temporaryDirectory
            .appendingPathComponent("catchmatch-ffmpeg-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: work) }
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        let zip = work.appendingPathComponent("archive.zip")
        try archive.write(to: zip)
        let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
        try unzip(zip, into: unpacked)

        // Both binaries and the notices the LGPL asks for must be there before
        // anything is installed, so a damaged archive changes nothing.
        let binaries = ["ffmpeg", "ffprobe"].map { unpacked.appendingPathComponent($0) }
        let notices = try fileManager.contentsOfDirectory(atPath: unpacked.path)
            .filter { $0 == "NOTICE.txt" || $0.hasPrefix("LICENSE-") }
        guard binaries.allSatisfy({ fileManager.fileExists(atPath: $0.path) }),
              notices.contains("NOTICE.txt"), notices.contains(where: { $0.hasPrefix("LICENSE-") })
        else {
            throw failure("The download was incomplete. Nothing was installed.")
        }

        // Everything that can fail on a full disk happens before the swap: both
        // binaries are written beside their targets and the licences into a
        // directory beside theirs. A failure there leaves the old install as it was.
        var staged: [(staging: URL, destination: URL)] = []
        let stagedLicenses = licensesDirectory.appendingPathExtension("download")
        do {
            for binary in binaries {
                staged.append(try stage(try Data(contentsOf: binary),
                                        named: binary.lastPathComponent, in: binDirectory))
            }
            try? fileManager.removeItem(at: stagedLicenses)
            try fileManager.createDirectory(at: stagedLicenses, withIntermediateDirectories: true)
            for name in notices {
                try fileManager.copyItem(at: unpacked.appendingPathComponent(name),
                                         to: stagedLicenses.appendingPathComponent(name))
            }
        } catch {
            for file in staged { try? fileManager.removeItem(at: file.staging) }
            try? fileManager.removeItem(at: stagedLicenses)
            throw error
        }

        // Then the pair, then the licences. The current binaries are kept aside
        // until all three are in, and put back if a later swap fails, so the
        // pipeline never sees a new ffmpeg beside an old ffprobe, and the
        // NOTICE always describes the binaries beside it.
        var committed: [(destination: URL, previous: URL?)] = []
        do {
            for file in staged {
                var previous: URL?
                if fileManager.fileExists(atPath: file.destination.path) {
                    let aside = file.destination.appendingPathExtension("previous")
                    try? fileManager.removeItem(at: aside)
                    try fileManager.copyItem(at: file.destination, to: aside)
                    previous = aside
                }
                try commit(file.staging, to: file.destination)
                committed.append((file.destination, previous))
            }
            try commit(stagedLicenses, to: licensesDirectory)
        } catch {
            for file in committed.reversed() {
                if let previous = file.previous {
                    _ = try? fileManager.replaceItemAt(file.destination, withItemAt: previous)
                } else {
                    try? fileManager.removeItem(at: file.destination)
                }
            }
            for file in staged { try? fileManager.removeItem(at: file.staging) }
            try? fileManager.removeItem(at: stagedLicenses)
            throw error
        }
        for file in committed {
            if let previous = file.previous { try? fileManager.removeItem(at: previous) }
        }
    }

    nonisolated private static func unzip(_ zip: URL, into directory: URL) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        task.arguments = ["-x", "-k", zip.path, directory.path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw failure("The download couldn't be unpacked. Nothing was installed.")
        }
    }

    nonisolated private static func failure(_ message: String) -> NSError {
        NSError(domain: "ToolManager", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Downloads the current yt-dlp release and verifies it against the checksum
    /// file published alongside it.
    ///
    /// The checksum comes from the same release as the binary, so it proves the
    /// download arrived intact — not that the release itself is honest. That is
    /// the same trust Homebrew placed in the same publisher, and the alternative
    /// (pinning a signing key) is only worth it if yt-dlp starts publishing one. Re-running this is also how a managed copy
    /// updates: a fresh verified download beats `yt-dlp -U` rewriting itself.
    func installYtDlp() async -> Bool {
        await once("yt-dlp") { await self.performYtDlpInstall() }
    }

    private func performYtDlpInstall() async -> Bool {
        do {
            progress = .working("Finding the latest version…", fraction: nil)
            let release = try await latestRelease()

            guard let asset = release.assets.first(where: { $0.name == Self.assetName }),
                  let sums = release.assets.first(where: { $0.name == "SHA2-256SUMS" })
            else {
                progress = .failed("That release didn't include the build this Mac needs.")
                return false
            }

            progress = .working("Downloading \(release.tagName)…", fraction: nil)
            let binary = try await data(from: asset.browserDownloadURL)

            progress = .working("Verifying…", fraction: nil)
            let expected = try await expectedHash(sumsURL: sums.browserDownloadURL, forAsset: Self.assetName)
            let actual = SHA256.hash(data: binary).map { String(format: "%02x", $0) }.joined()
            guard let expected, expected == actual else {
                // Refuse rather than run something that didn't match. This is the
                // same trust level Homebrew gave; it is not worth more machinery,
                // but it is worth this much.
                progress = .failed("The download didn't match its published checksum. Nothing was installed.")
                return false
            }

            try Self.install(binary, named: Self.managedYtDlp.lastPathComponent, in: Self.managedBinDirectory)
            progress = .done
            return true
        } catch {
            progress = .failed(error.localizedDescription)
            return false
        }
    }

    // MARK: - Plumbing

    /// The official single-file macOS build.
    private static let assetName = "yt-dlp_macos"

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        let tagName: String
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case assets
        }
    }

    private func latestRelease() async throws -> Release {
        let url = URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(response)
        return try JSONDecoder().decode(Release.self, from: data)
    }

    private func data(from url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        try Self.check(response)
        return data
    }

    /// The sums file is `<hash>  <filename>` per line.
    private func expectedHash(sumsURL: URL, forAsset asset: String) async throws -> String? {
        let text = String(data: try await data(from: sumsURL), encoding: .utf8) ?? ""
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count >= 2, parts.last.map(String.init) == asset {
                return String(parts[0])
            }
        }
        return nil
    }

    nonisolated private static func install(_ binary: Data, named name: String, in directory: URL) throws {
        let file = try stage(binary, named: name, in: directory)
        try commit(file.staging, to: file.destination)
    }

    /// Writes `binary` beside its target, executable and unquarantined, ready to
    /// be moved into place by `commit`.
    nonisolated private static func stage(_ binary: Data, named name: String,
                                          in directory: URL) throws -> (staging: URL, destination: URL) {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(name)

        // Write beside the target and move into place, so an interrupted download
        // can't leave a half-written binary that looks installed.
        let staging = destination.appendingPathExtension("download")
        try? fileManager.removeItem(at: staging)
        try binary.write(to: staging, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.path)
        // Downloads through URLSession aren't quarantined unless the app opts in,
        // but strip the attribute defensively rather than ship a binary macOS
        // might refuse to exec. Absent is the normal case, hence the ignored
        // result.
        staging.path.withCString { path in
            _ = removexattr(path, "com.apple.quarantine", 0)
        }
        return (staging, destination)
    }

    nonisolated private static func commit(_ staging: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
        } else {
            try fileManager.moveItem(at: staging, to: destination)
        }
    }

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            // GitHub answers 403 for an unauthenticated rate limit, which is a
            // wait-and-retry rather than a real failure — say which it is.
            let message: String
            if http.statusCode == 403 || http.statusCode == 429 {
                message = "The download service is rate-limiting this Mac. Try again in a few minutes, or use Run Setup Check… in the Help menu to install it another way."
            } else {
                message = "The server answered \(http.statusCode)."
            }
            throw NSError(domain: "ToolManager", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: message
            ])
        }
    }
}
