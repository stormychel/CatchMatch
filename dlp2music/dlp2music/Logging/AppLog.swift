//
//  AppLog.swift
//  dlp2music
//
//  Created by Michel Storms on 10/05/2026.
//

import Foundation
import AppKit

enum LogLevel: String {
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"
}

final class AppLog {
    static let shared = AppLog()

    private let queue = DispatchQueue(label: "dlp2music.applog", qos: .utility)
    private let fileURL: URL
    private let rotatedURL: URL
    private let maxBytes: UInt64 = 5 * 1024 * 1024
    private var handle: FileHandle?

    private static var dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    var logFileURL: URL { fileURL }

    private convenience init() {
        let logsRoot = (try? FileManager.default.url(
            for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        )) ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        self.init(directory: logsRoot.appendingPathComponent("Logs/dlp2music", isDirectory: true))
    }

    /// Tests pass a temporary directory: the shared instance writes to, and
    /// diagnostics read from, the real user's log, which a test must not touch.
    init(directory dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        self.fileURL = dir.appendingPathComponent("dlp2music.log")
        self.rotatedURL = dir.appendingPathComponent("dlp2music.log.1")
        openHandle()
    }

    deinit {
        try? handle?.close()
    }

    private func openHandle() {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: fileURL)
        _ = try? handle?.seekToEnd()
    }

    private func rotateIfNeeded() {
        guard let h = handle else { return }
        let size = (try? h.offset()) ?? 0
        guard size >= maxBytes else { return }
        try? h.close()
        handle = nil
        // Move current → .log.1, drop any older rotated copy.
        try? FileManager.default.removeItem(at: rotatedURL)
        try? FileManager.default.moveItem(at: fileURL, to: rotatedURL)
        openHandle()
    }

    func log(_ message: String, level: LogLevel = .info, file: String = #file, line: Int = #line) {
        // Capture the timestamp at call time on the calling thread (Date() is thread-safe);
        // do all formatter access on the serial queue so the shared formatter is never
        // touched concurrently. ISO8601DateFormatter is documented thread-safe, but
        // this keeps the contract local and obvious.
        let timestamp = Date()
        let location = (file as NSString).lastPathComponent
        queue.async { [weak self] in
            guard let self else { return }
            let stamp = Self.dateFormatter.string(from: timestamp)
            let formatted = "\(stamp) [\(level.rawValue)] \(location):\(line) \(message)\n"
            self.rotateIfNeeded()
            if let data = formatted.data(using: .utf8) {
                try? self.handle?.write(contentsOf: data)
            }
            FileHandle.standardError.write(Data(formatted.utf8))
        }
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    func copyPathToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(fileURL.path, forType: .string)
    }

    func diagnosticsBundle() -> String {
        // Drain pending writes from the async queue before reading from disk,
        // otherwise the bundle can omit the very lines that triggered the user
        // to copy diagnostics in the first place.
        queue.sync {
            _ = try? handle?.synchronize()
        }
        var out: [String] = []
        out.append("CatchMatch diagnostics")
        let now = Date()
        let stamp = queue.sync { Self.dateFormatter.string(from: now) }
        out.append("Generated: \(stamp)")
        let osv = ProcessInfo.processInfo.operatingSystemVersion
        out.append("macOS: \(osv.majorVersion).\(osv.minorVersion).\(osv.patchVersion)")
        if let bundle = Bundle.main.infoDictionary {
            let v = bundle["CFBundleShortVersionString"] as? String ?? "?"
            let b = bundle["CFBundleVersion"] as? String ?? "?"
            out.append("App: \(v) (\(b))")
        }
        out.append("Log: \(fileURL.path)")
        out.append("")
        out.append("---- last 200 log lines ----")
        var combined = ""
        if let rotated = try? String(contentsOf: rotatedURL, encoding: .utf8) {
            combined.append(rotated)
        }
        if let current = try? String(contentsOf: fileURL, encoding: .utf8) {
            combined.append(current)
        }
        let lines = combined.split(separator: "\n").suffix(200).joined(separator: "\n")
        out.append(lines)
        return out.joined(separator: "\n")
    }

    func copyDiagnosticsToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnosticsBundle(), forType: .string)
    }
}
