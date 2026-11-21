//
//  MessagesDatabase.swift
//  dlp2music
//
//  Created by Michel Storms on 26/05/2026.
//

import Foundation
import SQLite3

/// Read-only access to `~/Library/Messages/chat.db`. Requires Full Disk Access TCC grant.
/// Opens with `SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX` and only ever queries; never writes.
final class MessagesDatabase {

    static let defaultPath: String = {
        let home = NSString(string: "~").expandingTildeInPath
        return "\(home)/Library/Messages/chat.db"
    }()

    struct ChatSummary: Identifiable, Hashable {
        let guid: String
        let displayName: String
        let chatIdentifier: String
        let participants: [String]
        let lastReadTimestamp: Int64
        var id: String { guid }

        var label: String {
            if !displayName.isEmpty { return displayName }
            if !participants.isEmpty { return participants.joined(separator: ", ") }
            return chatIdentifier
        }

        var isSelfChat: Bool {
            participants.count <= 1
        }
    }

    struct MessageRow {
        let rowID: Int64
        let text: String?
        let attributedBodyBytes: Data?
        let isFromMe: Bool
        let dateNanos: Int64
    }

    enum OpenError: Error {
        case cannotOpen(code: Int32, message: String)
    }

    private var db: OpaquePointer?

    init(path: String = MessagesDatabase.defaultPath) throws {
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(path, &db, flags, nil)
        guard result == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let db = db { sqlite3_close_v2(db) }
            db = nil
            throw OpenError.cannotOpen(code: result, message: msg)
        }
    }

    deinit {
        if let db = db { sqlite3_close_v2(db) }
    }

    func listChats(limit: Int = 200) -> [ChatSummary] {
        let sql = """
        SELECT c.guid,
               COALESCE(c.display_name, ''),
               COALESCE(c.chat_identifier, ''),
               COALESCE((
                   SELECT GROUP_CONCAT(h.id, '|')
                   FROM chat_handle_join chj
                   JOIN handle h ON chj.handle_id = h.ROWID
                   WHERE chj.chat_id = c.ROWID
               ), ''),
               COALESCE(c.last_read_message_timestamp, 0)
        FROM chat c
        WHERE c.is_archived = 0
        ORDER BY c.last_read_message_timestamp DESC
        LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))

        var out: [ChatSummary] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let guid = MessagesDatabase.column(stmt, 0) ?? ""
            let displayName = MessagesDatabase.column(stmt, 1) ?? ""
            let chatIdentifier = MessagesDatabase.column(stmt, 2) ?? ""
            let handlesRaw = MessagesDatabase.column(stmt, 3) ?? ""
            let ts = sqlite3_column_int64(stmt, 4)
            let parts = handlesRaw.isEmpty ? [] : handlesRaw.split(separator: "|").map(String.init)
            out.append(ChatSummary(
                guid: guid,
                displayName: displayName,
                chatIdentifier: chatIdentifier,
                participants: parts,
                lastReadTimestamp: ts
            ))
        }
        return out
    }

    /// Returns the current maximum ROWID across messages in the given chat — used to seed the
    /// watermark when the user first selects a chat, so we don't replay history.
    func currentMaxRowID(forChatGUID guid: String) -> Int64 {
        let sql = """
        SELECT COALESCE(MAX(m.ROWID), 0)
        FROM message m
        JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        JOIN chat c ON cmj.chat_id = c.ROWID
        WHERE c.guid = ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, guid, -1, MessagesDatabase.SQLITE_TRANSIENT)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return sqlite3_column_int64(stmt, 0)
        }
        return 0
    }

    /// Fetches messages newer than `afterRowID` in the given chat, ordered by ROWID ascending.
    func messages(afterRowID: Int64, inChatGUID guid: String, limit: Int = 200) -> [MessageRow] {
        let sql = """
        SELECT m.ROWID, m.text, m.attributedBody, m.is_from_me, m.date
        FROM message m
        JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        JOIN chat c ON cmj.chat_id = c.ROWID
        WHERE c.guid = ? AND m.ROWID > ?
        ORDER BY m.ROWID ASC
        LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, guid, -1, MessagesDatabase.SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 2, afterRowID)
        sqlite3_bind_int(stmt, 3, Int32(limit))

        var out: [MessageRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowID = sqlite3_column_int64(stmt, 0)
            let text = MessagesDatabase.column(stmt, 1)
            let blobBytes: Data? = {
                guard let raw = sqlite3_column_blob(stmt, 2) else { return nil }
                let len = Int(sqlite3_column_bytes(stmt, 2))
                guard len > 0 else { return nil }
                return Data(bytes: raw, count: len)
            }()
            let isFromMe = sqlite3_column_int(stmt, 3) != 0
            let dateNanos = sqlite3_column_int64(stmt, 4)
            out.append(MessageRow(
                rowID: rowID,
                text: text,
                attributedBodyBytes: blobBytes,
                isFromMe: isFromMe,
                dateNanos: dateNanos
            ))
        }
        return out
    }

    // MARK: - Helpers

    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func column(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let raw = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: raw)
    }
}
