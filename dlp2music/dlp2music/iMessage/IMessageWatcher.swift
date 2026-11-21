//
//  IMessageWatcher.swift
//  dlp2music
//
//  Created by Michel Storms on 26/05/2026.
//

import Foundation
import Combine

/// Polls `chat.db` every 2s for new messages in the selected chat, extracts http(s) URLs,
/// dedups against a recent-window, and dispatches new URLs to a consumer closure.
///
/// Lifecycle is owned by the app; UI binds to `@Published` state for status display.
@MainActor
final class IMessageWatcher: ObservableObject {

    enum Status: Equatable {
        case stopped
        case noPermission
        case running(chatLabel: String)
        case error(String)
    }

    @Published private(set) var status: Status = .stopped
    @Published private(set) var lastSeenAt: Date?
    @Published private(set) var importsToday: Int = 0
    @Published private(set) var lastError: String?

    /// Called on the main actor with the array of URLs extracted from a single message row.
    /// The consumer is responsible for enqueuing into the pipeline.
    var onURLsFound: (([String]) -> Void)?

    private var timer: Timer?
    private var dedupRecent: [(url: String, at: Date)] = []
    private let dedupWindow: TimeInterval = 5 * 60

    private let pollInterval: TimeInterval = 2.0
    private let pollQueue = DispatchQueue(label: "dlp2music.imessage.poll", qos: .utility)

    private(set) var watermarkRowID: Int64 = 0
    private(set) var selectedChatGUID: String?
    private(set) var selectedChatLabel: String = ""

    /// Increments on every `start` and `stop` so in-flight background polls can detect
    /// that the watcher state has changed under them and discard their results.
    private var sessionToken: UUID = UUID()

    func start(chatGUID: String, chatLabel: String, seedFromLatest: Bool) {
        stop()
        sessionToken = UUID()
        selectedChatGUID = chatGUID
        selectedChatLabel = chatLabel

        // Seed the watermark either from saved state or from current MAX(ROWID) to avoid
        // replaying historical messages on first start.
        let key = Self.watermarkKey(forChat: chatGUID)
        let saved = UserDefaults.standard.object(forKey: key) as? Int64 ?? 0
        if seedFromLatest || saved == 0 {
            do {
                let db = try MessagesDatabase()
                watermarkRowID = db.currentMaxRowID(forChatGUID: chatGUID)
            } catch {
                status = .noPermission
                lastError = String(describing: error)
                return
            }
            UserDefaults.standard.set(watermarkRowID, forKey: key)
        } else {
            watermarkRowID = saved
        }

        status = .running(chatLabel: chatLabel)
        lastError = nil

        let t = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer = t
        // First tick immediately so users see activity without waiting 2s.
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        // Invalidate any in-flight polls so their callbacks become no-ops.
        sessionToken = UUID()
        selectedChatGUID = nil
        if case .running = status { status = .stopped }
    }

    private func tick() {
        guard let chatGUID = selectedChatGUID else { return }
        let after = watermarkRowID
        let token = sessionToken
        pollQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                let db = try MessagesDatabase()
                let rows = db.messages(afterRowID: after, inChatGUID: chatGUID)
                Task { @MainActor in
                    // Discard results if the watcher was stopped or reconfigured
                    // while this poll was in flight.
                    guard self.sessionToken == token,
                          self.selectedChatGUID == chatGUID else { return }
                    self.handle(rows: rows)
                }
            } catch {
                Task { @MainActor in
                    guard self.sessionToken == token else { return }
                    self.status = .noPermission
                    self.lastError = String(describing: error)
                    self.stop()
                }
            }
        }
    }

    private func handle(rows: [MessagesDatabase.MessageRow]) {
        guard !rows.isEmpty else {
            lastSeenAt = Date()
            return
        }

        var collectedURLs: [String] = []
        for row in rows {
            var found: [String] = []
            if let t = row.text, !t.isEmpty {
                found.append(contentsOf: URLExtractor.urls(in: t))
            }
            if found.isEmpty, let blob = row.attributedBodyBytes {
                found.append(contentsOf: URLExtractor.urls(inAttributedBodyBytes: blob))
            }
            for url in found where shouldAccept(url: url) {
                collectedURLs.append(url)
                dedupRecent.append((url, Date()))
            }
            watermarkRowID = max(watermarkRowID, row.rowID)
        }
        if let guid = selectedChatGUID {
            UserDefaults.standard.set(watermarkRowID, forKey: Self.watermarkKey(forChat: guid))
        }

        pruneDedup()
        lastSeenAt = Date()

        if !collectedURLs.isEmpty {
            importsToday += collectedURLs.count
            onURLsFound?(collectedURLs)
        }
    }

    private func shouldAccept(url: String) -> Bool {
        let now = Date()
        if let recent = dedupRecent.first(where: { $0.url == url && now.timeIntervalSince($0.at) < dedupWindow }) {
            _ = recent
            return false
        }
        return true
    }

    private func pruneDedup() {
        let now = Date()
        dedupRecent.removeAll { now.timeIntervalSince($0.at) >= dedupWindow }
    }

    private static func watermarkKey(forChat guid: String) -> String {
        "iMessageWatcher.watermark.\(guid)"
    }
}
