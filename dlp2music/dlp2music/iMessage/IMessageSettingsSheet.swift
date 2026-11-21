//
//  IMessageSettingsSheet.swift
//  dlp2music
//
//  Created by Michel Storms on 26/05/2026.
//

import SwiftUI

struct IMessageSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var watcher: IMessageWatcher

    @AppStorage("imessageWatcherEnabled") private var enabled: Bool = false
    @AppStorage("imessageWatcherChatGUID") private var chatGUID: String = ""
    @AppStorage("imessageWatcherChatLabel") private var chatLabel: String = ""

    @State private var chats: [MessagesDatabase.ChatSummary] = []
    @State private var loadError: String?
    @State private var fdaGranted: Bool = false
    @State private var search: String = ""

    private var filteredChats: [MessagesDatabase.ChatSummary] {
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return chats }
        return chats.filter { chat in
            chat.label.lowercased().contains(trimmed) ||
            chat.chatIdentifier.lowercased().contains(trimmed) ||
            chat.participants.contains(where: { $0.lowercased().contains(trimmed) })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("iMessage Drop Chat").font(.title2).bold()

            Text("Pick one iMessage chat. \(Constants.appName) will watch it for links you send and import them automatically.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            permissionRow

            Divider()

            // The watch switch belongs *with* the chat it acts on, not above it:
            // on its own it read as a global setting and sat disabled before a
            // selection existed. A plain switch, per the macOS convention — an
            // off watcher is a valid, reversible state, not an error, so it gets
            // no red treatment; the state is carried by adjacent text + symbol
            // instead (never colour alone), because granting Full Disk Access and
            // picking a chat reads as "connected" while this is still off.
            if !chatGUID.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        (Text("Selected: ") + Text(chatLabel).bold())
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Toggle("Watch", isOn: $enabled)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .disabled(!fdaGranted)
                            .onChange(of: enabled) { _, newValue in
                                applyWatcherState(enabled: newValue)
                            }
                            .accessibilityLabel("Watch selected chat")
                        Button("Clear") {
                            enabled = false
                            chatGUID = ""
                            chatLabel = ""
                            watcher.stop()
                        }.controlSize(.small)
                    }
                    .font(.callout)

                    if !enabled {
                        Label("Off — this chat is selected but isn't being monitored.",
                              systemImage: "pause.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                Label("Pick a chat below, then turn on Watch to start monitoring it.",
                      systemImage: "hand.point.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextField("Filter…", text: $search)
                .textFieldStyle(.roundedBorder)

            if let err = loadError {
                Text(err).font(.caption).foregroundStyle(.red)
            }

            chatList

            statusRow

            privacyDisclosure

            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 620)
        .onAppear(perform: refresh)
    }

    private var permissionRow: some View {
        HStack(spacing: 8) {
            Image(systemName: fdaGranted ? "lock.open.fill" : "lock.fill")
                .foregroundStyle(fdaGranted ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(fdaGranted ? "Full Disk Access granted" : "Full Disk Access required")
                    .font(.callout).bold()
                Text(fdaGranted
                     ? "\(Constants.appName) can read the Messages database in read-only mode."
                     : "\(Constants.appName) needs Full Disk Access to read iMessages. Grant it in System Settings, then return here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !fdaGranted {
                Button("Open Settings") { FullDiskAccessGuide.openSettings() }
            }
            Button("Recheck") { refresh() }.controlSize(.small)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.08)))
    }

    private var chatList: some View {
        List(filteredChats, selection: Binding<String?>(
            get: { chatGUID.isEmpty ? nil : chatGUID },
            set: { newValue in
                guard let new = newValue, let row = chats.first(where: { $0.guid == new }) else { return }
                selectChat(row)
            }
        )) { chat in
            HStack(spacing: 8) {
                Image(systemName: chat.isSelfChat ? "person.fill" : "person.2.fill")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(chat.label).font(.callout)
                    if !chat.participants.isEmpty {
                        Text(chat.participants.joined(separator: ", "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
            .tag(chat.guid)
            .contentShape(Rectangle())
        }
        .listStyle(.bordered)
        .frame(minHeight: 220)
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            switch watcher.status {
            case .stopped:
                Image(systemName: "pause.circle.fill").foregroundStyle(.secondary)
                if chatGUID.isEmpty {
                    Text("Watcher off — no chat selected")
                } else {
                    Text("Watcher off — turn on ") + Text("Watch").bold() + Text(" to begin.")
                }
            case .noPermission:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Cannot read chat.db. Check Full Disk Access.")
            case .running(let label):
                Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.green)
                Text("Watching: ") + Text(label).bold()
            case .error(let m):
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                Text(m).lineLimit(2)
            }
            Spacer()
            if let last = watcher.lastSeenAt {
                Text("Last poll: \(last.formatted(date: .omitted, time: .standard))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Imports: \(watcher.importsToday)")
                .font(.caption).foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    private var privacyDisclosure: some View {
        Text("Privacy: \(Constants.appName) reads the Messages database in read-only mode and only queries the single chat you select above. No data leaves your Mac.")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func refresh() {
        fdaGranted = FullDiskAccessGuide.isGranted()
        guard fdaGranted else {
            chats = []
            loadError = nil
            return
        }
        do {
            let db = try MessagesDatabase()
            chats = db.listChats()
            loadError = nil
        } catch {
            chats = []
            loadError = "Could not open chat.db: \(error)"
        }
    }

    private func selectChat(_ chat: MessagesDatabase.ChatSummary) {
        chatGUID = chat.guid
        chatLabel = chat.label
        if enabled {
            applyWatcherState(enabled: true)
        }
    }

    private func applyWatcherState(enabled: Bool) {
        if enabled, !chatGUID.isEmpty, fdaGranted {
            watcher.start(chatGUID: chatGUID, chatLabel: chatLabel, seedFromLatest: true)
        } else {
            watcher.stop()
        }
    }
}
