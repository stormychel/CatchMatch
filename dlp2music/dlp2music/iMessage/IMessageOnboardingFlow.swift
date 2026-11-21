//
//  IMessageOnboardingFlow.swift
//  dlp2music
//
//  Created by Michel Storms on 30/08/2026.
//

import SwiftUI

/// First-run setup for the iMessage drop chat.
///
/// The settings sheet is a control panel: it assumes you already know what the
/// feature is, that Full Disk Access is the gate, which chat to pick and why a
/// chat with only yourself in it is the useful one. That is a lot to infer from
/// a list of checkboxes, and it is the feature the product is pitched on — so
/// the first run is a guided sequence instead, one decision per step, with the
/// two steps that normally lose people (granting access, proving it works)
/// resolving themselves by watching rather than by asking.
struct IMessageOnboardingFlow: View {
    @ObservedObject var watcher: IMessageWatcher
    @Environment(\.dismiss) private var dismiss

    @AppStorage("imessageWatcherEnabled") private var enabled: Bool = false
    @AppStorage("imessageWatcherChatGUID") private var chatGUID: String = ""
    @AppStorage("imessageWatcherChatLabel") private var chatLabel: String = ""
    @AppStorage("imessageOnboardingDone") private var onboardingDone: Bool = false

    private enum Step: Int, CaseIterable {
        case what, access, chat, test, done
    }

    @State private var step: Step = .what
    @State private var fdaGranted = false
    @State private var chats: [MessagesDatabase.ChatSummary] = []
    @State private var selected: MessagesDatabase.ChatSummary?
    @State private var loadError: String?
    @State private var sawTestURL = false
    @State private var search = ""
    /// Whether this flow is the thing that turned the watcher on, and what the
    /// settings were before it did — so cancelling can put them back.
    @State private var startedWatcher = false
    @State private var priorEnabled = false
    @State private var priorGUID = ""
    @State private var priorLabel = ""

    /// Polls while the sheet is open. Granting Full Disk Access happens in
    /// another app, so there is no event to wait on — and asking the user to
    /// come back and press Recheck is the step people give up on.
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            Group {
                switch step {
                case .what: whatStep
                case .access: accessStep
                case .chat: chatStep
                case .test: testStep
                case .done: doneStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(20)

            Divider()

            footer
        }
        .frame(width: 560, height: 520)
        .onReceive(poll) { _ in tick() }
        .onAppear {
            fdaGranted = FullDiskAccessGuide.isGranted()
            priorEnabled = enabled
            priorGUID = chatGUID
            priorLabel = chatLabel

            // Chain rather than replace: a link that arrives during setup is a
            // real import as well as proof the watcher works. Owning the callback
            // outright would swallow it — and the watermark moves on, so it would
            // be gone for good.
            let existing = watcher.onURLsFound
            watcher.onURLsFound = { urls in
                existing?(urls)
                sawTestURL = true
            }
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.title2)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text("Set up the iMessage drop chat").font(.headline)
                Text("Step \(step.rawValue + 1) of \(Step.allCases.count)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { cancel() }
            Spacer()
            if step != .done {
                Button("Skip") { advance() }
                    .disabled(step == .chat && selected == nil)
            }
            Button(primaryTitle) {
                if step == .done { finish() } else { advance() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(primaryDisabled)
        }
        .padding(20)
    }

    private var primaryTitle: String {
        switch step {
        case .done: return "Done"
        case .access: return fdaGranted ? "Continue" : "Waiting…"
        default: return "Continue"
        }
    }

    private var primaryDisabled: Bool {
        switch step {
        case .access: return !fdaGranted
        case .chat: return selected == nil
        default: return false
        }
    }

    // MARK: - Steps

    private var whatStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                stepGlyph("iphone", caption: "Text a link")
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                stepGlyph("desktopcomputer", caption: "Your Mac")
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                stepGlyph("music.note.house.fill", caption: "Your library")
            }
            .frame(maxWidth: .infinity)

            Text("Send a video link to one chat, and \(Constants.appName) imports it on its own.")
                .font(.title3)
            Text("It watches a single chat you choose — nothing else. The usual choice is a chat with only yourself in it, so the link goes nowhere but your own devices.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var accessStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(fdaGranted ? "Full Disk Access granted" : "Full Disk Access needed",
                  systemImage: fdaGranted ? "lock.open.fill" : "lock.fill")
                .font(.headline)
                .foregroundStyle(fdaGranted ? .green : .orange)

            Text("Reading a chat means reading the Messages database, which macOS keeps behind Full Disk Access. \(Constants.appName) opens it read-only and only ever queries the one chat you pick.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !fdaGranted {
                VStack(alignment: .leading, spacing: 6) {
                    instruction(1, "Click the button below — System Settings opens on the right pane.")
                    instruction(2, "Find \(Constants.appName) in the list and switch it on.")
                    instruction(3, "Come back here. This screen notices on its own.")
                }
                Button("Open Full Disk Access settings") { FullDiskAccessGuide.openSettings() }
                    .buttonStyle(.borderedProminent)

                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for access…").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Nothing else to do here.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var chatStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Which chat should it watch?").font(.headline)

            if let loadError {
                Text(loadError).font(.callout).foregroundStyle(.orange)
            }

            TextField("Filter…", text: $search)
                .textFieldStyle(.roundedBorder)

            List(selection: Binding(
                get: { selected?.id },
                set: { id in selected = chats.first { $0.id == id } }
            )) {
                if !selfChats.isEmpty {
                    Section("Just you (recommended)") {
                        ForEach(selfChats) { chat in chatRow(chat) }
                    }
                }
                if !otherChats.isEmpty {
                    Section("Other chats") {
                        ForEach(otherChats) { chat in chatRow(chat) }
                    }
                }
            }
            .frame(maxHeight: .infinity)

            DisclosureGroup("No chat with just yourself?") {
                Text("In Messages, start a new conversation and address it to your own phone number or Apple Account address. It will appear in the list above once it has a message in it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.callout)
        }
        .onAppear(perform: loadChats)
    }

    private var testStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(sawTestURL ? "That worked." : "Send it a link now").font(.headline)

            if sawTestURL {
                Label("Link received — the watcher is working.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Text("Send a link to \(selected?.label ?? chatLabel). This screen is watching that chat right now and will notice when it arrives.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Watching…").font(.caption).foregroundStyle(.secondary)
                }
                Text("No rush — you can skip this and test whenever.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .onAppear(perform: startWatchingForTest)
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Set up", systemImage: "checkmark.seal.fill")
                .font(.headline)
                .foregroundStyle(.green)
            Text("\(Constants.appName) is watching \(chatLabel.isEmpty ? (selected?.label ?? "your chat") : chatLabel).")
            Text("The Messages button in the main window shows the status from now on — green while it's watching — and everything here can be changed there.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Pieces

    private func stepGlyph(_ symbol: String, caption: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 30, weight: .light))
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func instruction(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func chatRow(_ chat: MessagesDatabase.ChatSummary) -> some View {
        HStack(spacing: 8) {
            Image(systemName: chat.isSelfChat ? "person.crop.circle" : "person.2")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(chat.label).lineLimit(1)
                if !chat.participants.isEmpty {
                    Text(chat.participants.joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .tag(chat.id)
    }

    private var filtered: [MessagesDatabase.ChatSummary] {
        guard !search.isEmpty else { return chats }
        let needle = search.lowercased()
        return chats.filter { $0.label.lowercased().contains(needle) }
    }

    private var selfChats: [MessagesDatabase.ChatSummary] { filtered.filter(\.isSelfChat) }
    private var otherChats: [MessagesDatabase.ChatSummary] { filtered.filter { !$0.isSelfChat } }

    // MARK: - Behaviour

    private func tick() {
        guard step == .access, !fdaGranted else { return }
        fdaGranted = FullDiskAccessGuide.isGranted()
        // Granting it is the whole step; there is nothing to confirm afterwards.
        if fdaGranted { advance() }
    }

    private func loadChats() {
        guard fdaGranted else {
            loadError = "Full Disk Access isn't granted, so the chat list can't be read."
            return
        }
        do {
            let database = try MessagesDatabase()
            chats = database.listChats()
            loadError = chats.isEmpty ? "No chats found in Messages yet." : nil
        } catch {
            chats = []
            loadError = "Couldn't read the chat list: \(error.localizedDescription)"
        }
    }

    /// Starts the watcher for real, seeded from the latest message so the test
    /// link the user is about to send is the first thing it sees.
    private func startWatchingForTest() {
        guard let chat = selected else { return }
        chatGUID = chat.guid
        chatLabel = chat.label
        enabled = true
        sawTestURL = false
        startedWatcher = true
        watcher.start(chatGUID: chat.guid, chatLabel: chat.label, seedFromLatest: true)
    }

    private func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        step = next
    }

    private func finish() {
        onboardingDone = true
        dismiss()
    }

    /// Leaving halfway shouldn't leave the watcher running against a chat the
    /// user never confirmed. Put back exactly what was there before.
    private func cancel() {
        if startedWatcher {
            watcher.stop()
            enabled = priorEnabled
            chatGUID = priorGUID
            chatLabel = priorLabel
            if priorEnabled, !priorGUID.isEmpty {
                watcher.start(chatGUID: priorGUID, chatLabel: priorLabel, seedFromLatest: false)
            }
        }
        dismiss()
    }
}
