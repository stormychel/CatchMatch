//
//  IMessageSender.swift
//  dlp2music
//
//  Created by Michel Storms on 26/05/2026.
//

import Foundation

/// Sends a confirmation message back to an iMessage chat via `osascript` driving
/// Messages.app. Requires the Automation/Apple Events TCC grant — the first call
/// triggers the system prompt; subsequent calls go through silently if granted.
enum IMessageSender {

    enum SendError: Error, CustomStringConvertible {
        case scriptFailed(status: Int32, stderr: String)
        case launchFailed(String)
        case empty

        var description: String {
            switch self {
            case .scriptFailed(let s, let err):
                return "osascript exited \(s): \(err)"
            case .launchFailed(let m):
                return "failed to launch osascript: \(m)"
            case .empty:
                return "empty message body"
            }
        }
    }

    /// Sends `text` to the chat identified by `chatGUID` (e.g. `iMessage;-;+1234567890`
    /// or `iMessage;+;chat123...`). Blocking call — wrap in a background queue from callers.
    @discardableResult
    static func send(text: String, toChatGUID chatGUID: String) -> Result<Void, SendError> {
        guard !text.isEmpty else { return .failure(.empty) }

        // Escape backslashes and double-quotes for the AppleScript literal.
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let escapedGUID = chatGUID
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        tell application "Messages"
            try
                set theChat to first chat whose id is "\(escapedGUID)"
                send "\(escaped)" to theChat
            on error errMsg
                return "ERROR:" & errMsg
            end try
        end tell
        """

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]

        let stdout = Pipe()
        let stderr = Pipe()
        task.standardOutput = stdout
        task.standardError = stderr

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return .failure(.launchFailed(error.localizedDescription))
        }

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        let outText = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let errText = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if outText.hasPrefix("ERROR:") {
            return .failure(.scriptFailed(status: task.terminationStatus, stderr: outText))
        }
        if task.terminationStatus != 0 {
            return .failure(.scriptFailed(status: task.terminationStatus, stderr: errText.isEmpty ? outText : errText))
        }
        return .success(())
    }
}
