//
//  ContentView.swift
//  dlp2music
//
//  Created by Michel Storms on 19/02/2025.
//

import SwiftUI
import os

private let scriptLog = Logger(subsystem: "com.dlp2music.app", category: "script")

struct ContentView: View {
    @ObservedObject var iMessageWatcher: IMessageWatcher

    /// The import queue. Typed rows rather than a free-text buffer: every entry
    /// is already validated, so the queue can't be edited into an invalid state
    /// (a half-typed path, a stray word appended to a filename).
    @State private var items: [InputItem] = []
    /// Set once the window's chips are changed by hand this session. From then
    /// on they are what new items get, not the learned prediction (#166).
    @State private var chipsChosenThisSession = false
    private let destinationPredictor = DestinationPredictor()
    /// This window's key in the Dock badge total.
    @State private var windowID = UUID()
    @State private var linkDraft: String = ""
    @State private var addError: String?
    @State private var isProcessing: Bool = false
    @State private var logEntries: [String] = ["Ready"]
    /// Shown in the status line instead of the latest log line while an
    /// install runs: the installer narrates in the voice of its own tools.
    @State private var installStatus: String?
    /// A component check is in flight; the footer says so instead of showing
    /// the previous verdict.
    @State private var checkingDependencies = false
    /// Set by the component check, so the installer fetches only what is missing.
    @State private var ytDlpReady = false
    @AppStorage("importToMusic") private var importMusicAudio: Bool = true
    @AppStorage("importToMusicVideo") private var importMusicVideo: Bool = true
    @AppStorage("importToTV") private var importToTV: Bool = false
    /// The video to ~/Downloads. The key predates the audio chip, when Downloads
    /// on its own meant the video, so a saved choice keeps meaning that (#164).
    @AppStorage("importToDownloads") private var importToDownloads: Bool = false
    @AppStorage("importToDownloadsAudio") private var importToDownloadsAudio: Bool = false
    @AppStorage("cleanMetadata") private var cleanMetadata: Bool = true
    @State private var showAbout: Bool = false
    @State private var showMessages: Bool = false
    @State private var showMessagesOnboarding: Bool = false
    @AppStorage("imessageOnboardingDone") private var iMessageOnboardingDone: Bool = false
    @AppStorage("imessageWatcherChatGUID") private var iMessageChatGUID: String = ""
    @State private var runningProcess: Process?
    @State private var dependenciesReady: Bool = false
    /// Tracked separately so Install fetches only what is missing.
    @State private var ffmpegReady: Bool = false
    /// Release string from `yt-dlp --version` ("2026.03.17"). yt-dlp ships a
    /// date-stamped release, so its age is what tells us whether YouTube
    /// extraction is likely to have rotted out from under it.
    @State private var ytDlpVersion: String?
    /// Signs, seen in run output, that yt-dlp is losing to YouTube's anti-bot
    /// measures. The symptom is not an error the user would recognise: the
    /// download "succeeds", just at 360p and 96 kbps, so nothing looks wrong
    /// until you play it.
    ///
    /// Kept as two observations rather than one verdict because the verdict
    /// depends on the version probe, which is asynchronous: a 360p fallback seen
    /// before the probe reports back would otherwise be judged against an
    /// unknown version and thrown away.
    @State private var solverFailureSeen: Bool = false
    @State private var format18FallbackSeen: Bool = false
    /// Whether the current run has already said so, to keep it to one log line.
    @State private var ytDlpBlockedAnnounced: Bool = false
    @State private var depCheckSeq: Int = 0

    /// Queued iMessage-triggered URLs that arrived while a pipeline run was already in
    /// flight. Each batch remembers the chat GUID it came from so the reply (sent on
    /// drain) goes back to the originating chat even if the user has since switched
    /// or cleared the watcher's current chat.
    @State private var pendingFromMessages: [(urls: [String], chatGUID: String, destination: Destination)] = []

    /// Remaining destination groups of the current run. A queue whose items don't
    /// all share the same destinations needs one script invocation per group.
    @State private var pendingBatches: [QueuedBatch] = []

    /// The item the script is currently on, tracked from its "=== Processing: X ==="
    /// banner, plus whether it has produced any "→ Music/TV" output line yet.
    @State private var currentItemRaw: String?
    @State private var currentItemProducedOutput: Bool = false
    /// Whether the script reported a failure while on the current item. A
    /// playlist expands to many videos inside one item, so "produced some
    /// output" alone is not enough to call the item imported.
    @State private var currentItemHadError: Bool = false

    private var currentItemSucceeded: Bool { currentItemProducedOutput && !currentItemHadError }

    @ObservedObject private var externalRequests = ExternalRequestRouter.shared
    @ObservedObject private var externalOpens = ExternalOpenRouter.shared
    /// This view's window, so the window that takes a file is the one that comes
    /// forward. Held weakly: the window owns the view graph that owns this
    /// state, and a strong reference here would keep a closed window alive.
    @State private var hostWindow = WeakWindow()
    @State private var isDropTargeted: Bool = false
    @AppStorage("showLogDetails") private var showLogDetails: Bool = false

    private let dropHint = "…or paste one or more links, one per line. Playlists, channels and search pages are expanded automatically."

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            // Whichever of the input card / detail log is the "main" area for the
            // current state takes the window's slack, so growing the window never
            // leaves a dead gap in the middle.
            sourceCard

            destinationRow

            actionRow

            statusStrip

            if showLogDetails {
                logPane
                    .frame(maxHeight: .infinity)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            dependencyFooter
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 440)
        // Accept drops anywhere in the window, not only on the card: a drop that
        // lands on the chips or the button still queues the file.
        .background(WindowReader { window in
            hostWindow.window = window
            // A window screenshot is cropped out of the screen, so anything in
            // front of the window lands in the image — a browser window once
            // ended up in a shot bound for the website. Floating above other
            // apps is the only reliable way to be the thing that gets captured.
            // Screenshot mode is Debug-only (#113), so this cannot ship. #105
            if ScreenshotMode.isActive { window?.level = .floating }
        })
        // Only the window the command was aimed at answers. The notification is
        // process-wide, so with two windows open both would put up their own
        // file panel — and the panel blocks, so they would queue up behind each
        // other (#33).
        .onReceive(NotificationCenter.default.publisher(for: .openFilePicker)) { note in
            guard !isProcessing else { return }
            if let target = note.object as? NSWindow {
                guard target === hostWindow.window else { return }
            } else {
                // No window was named: only the key one answers, so a second
                // window doesn't put up its own panel behind the first.
                guard hostWindow.window?.isKeyWindow == true else { return }
            }
            chooseFiles()
        }
        // .fileURL first: without it a Finder drag arrives as text and falls
        // through to the link parser instead of being taken as a file (#33).
        .onDrop(of: [.fileURL, .url, .text], isTargeted: $isDropTargeted, perform: handleDrop)
        .sheet(isPresented: $showAbout) { AboutView() }
        .sheet(isPresented: $showMessages) { IMessageSettingsSheet(watcher: iMessageWatcher) }
        .sheet(isPresented: $showMessagesOnboarding) {
            IMessageOnboardingFlow(watcher: iMessageWatcher)
                .onDisappear {
                    // The flow owns the watcher's callback while it runs its live
                    // test; hand it back so imports resume going to the pipeline.
                    iMessageWatcher.onURLsFound = { urls in
                        handleIncomingURLsFromMessages(urls)
                    }
                }
        }
        .onAppear {
            if let scene = ScreenshotMode.scene {
                applyScreenshotScene(scene)
                return
            }
            iMessageWatcher.onURLsFound = { [weak iMessageWatcher] urls in
                _ = iMessageWatcher
                handleIncomingURLsFromMessages(urls)
            }
            // onChange's initial run is first-appear only; a re-appear re-adds this
            // window's share in case a disappear dropped it.
            DockBadge.set(readyCount, for: windowID)
            refreshDependencyStatus()
            drainExternalRequests()
            queueExternalOpens()
        }
        // Not in screenshot mode: a catchmatch:// link or an opened file arriving
        // mid-capture would add rows to the fixed demo state.
        .onChange(of: externalRequests.pending) {
            guard !ScreenshotMode.isActive else { return }
            drainExternalRequests()
        }
        .onChange(of: isProcessing) { _, busy in
            if !busy { installStatus = nil }
            // Requests that arrived during the run were held back; take them now.
            if !busy, !ScreenshotMode.isActive { drainExternalRequests() }
        }
        // The Dock icon carries the ready count, so a queue is visible with the
        // window hidden or behind others (#159). Summed across windows, each
        // with its own queue; a closed window's queue is gone, so its share goes.
        .onChange(of: readyCount, initial: true) { _, count in
            guard !ScreenshotMode.isActive else { return }
            DockBadge.set(count, for: windowID)
        }
        .onDisappear { DockBadge.remove(windowID) }
        // Setting the chips by hand says what is wanted now, which beats the
        // learned prediction for the rest of the session (#166).
        .onChange(of: defaultDestination) { chipsChosenThisSession = true }
        // An emptied queue is a fresh start: predictions apply again.
        .onChange(of: items.isEmpty) { _, empty in
            if empty { chipsChosenThisSession = false }
        }
        .onChange(of: externalOpens.pendingPaths) {
            guard !ScreenshotMode.isActive else { return }
            queueExternalOpens()
        }
        // Re-check when the app regains focus — covers deps installed out of
        // band (Terminal, the onboarding window's brew-install fix) so the
        // main window's button flips to the installed state without a relaunch.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard !ScreenshotMode.isActive else { return }
            refreshDependencyStatus()
        }
        // The onboarding window installs too, and moving from it back to this
        // window never deactivates the app, so the check above never ran and
        // "Required components are missing" outlived the install (#80).
        .onReceive(ToolManager.shared.$progress) { progress in
            guard !ScreenshotMode.isActive, progress == .done else { return }
            refreshDependencyStatus()
        }
        // A *different* yt-dlp is a different answer to "is it being blocked?".
        // Guarded on the old value so the first probe after launch — nil to the
        // installed version — can't wipe a detection made before it returned.
        .onChange(of: ytDlpVersion) { previous, current in
            if previous != nil, previous != current {
                solverFailureSeen = false
                format18FallbackSeen = false
            }
            // The probe is often what turns an observation into a verdict.
            announceBlockedIfNeeded()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            if let appIcon = NSApplication.shared.applicationIconImage {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 44, height: 44)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(Constants.appName)
                    .font(.title3).bold()
                Text("Add any video you have the right to use to Apple Music, Apple TV, or your Downloads folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // .plain rather than .borderless: the borderless style imposes its
            // own label color, which would swallow the watcher-status tint.
            Button {
                // A first-timer gets the guided sequence; anyone who has already
                // set this up gets the control panel they expect.
                if iMessageOnboardingDone || !iMessageChatGUID.isEmpty {
                    showMessages = true
                } else {
                    showMessagesOnboarding = true
                }
            } label: {
                Image(systemName: iMessageWatcherIcon)
                    .imageScale(.large)
                    .foregroundStyle(iMessageWatcherTint)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(iMessageWatcherHelp)
            .accessibilityLabel("Messages")
            .accessibilityIdentifier("messagesButton")

            Button { showAbout = true } label: {
                Image(systemName: "info.circle")
                    .imageScale(.large)
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("About \(Constants.appName)")
            .accessibilityLabel("About")
        }
    }

    private var iMessageWatcherIcon: String {
        switch iMessageWatcher.status {
        case .running: return "bubble.left.and.bubble.right.fill"
        case .noPermission, .error: return "exclamationmark.bubble"
        case .stopped: return "bubble.left.and.bubble.right"
        }
    }

    private var iMessageWatcherTint: Color {
        switch iMessageWatcher.status {
        case .running: return .green
        case .noPermission, .error: return .orange
        case .stopped: return .secondary
        }
    }

    private var iMessageWatcherHelp: String {
        switch iMessageWatcher.status {
        case .running(let label): return "Watching iMessage chat: \(label)"
        case .noPermission: return "iMessage watcher needs Full Disk Access"
        case .error(let m): return "iMessage watcher error: \(m)"
        case .stopped: return "Configure iMessage chat watching"
        }
    }

    // MARK: - Source

    /// The input area: a link field on top, then either the drop-zone prompt
    /// (nothing queued yet) or the queue itself. Entries are added by drop, by
    /// the file panel, or by committing the link field — never by free-typing
    /// into the list, so a queued path can't be corrupted after the fact.
    private var sourceCard: some View {
        VStack(spacing: 0) {
            linkField

            Divider()

            if items.isEmpty {
                dropPrompt
            } else {
                itemList

                Divider()

                HStack(spacing: 8) {
                    Text(inputSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Add Files…", action: chooseFiles)
                        .controlSize(.small)
                        .disabled(isProcessing)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
            }
        }
        // Stretch first, decorate second: the background and dashed border have to
        // wrap the *filled* frame, otherwise the card paints at its natural height
        // and just floats in the middle of the window's slack.
        .frame(maxWidth: .infinity, maxHeight: showLogDetails ? nil : .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                    style: StrokeStyle(
                        lineWidth: isDropTargeted ? 2 : 1,
                        dash: items.isEmpty && !isDropTargeted ? [6, 4] : []
                    )
                )
        )
        .animation(.easeInOut(duration: 0.15), value: isDropTargeted)
    }

    private var linkField: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: "link")
                    .foregroundStyle(.secondary)
                TextField("Paste or type a link, then press Return", text: $linkDraft)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .disabled(isProcessing)
                    .onSubmit(commitLinkDraft)
                    .onChange(of: linkDraft) { addError = nil }
                if !linkDraft.isEmpty {
                    Button("Add", action: commitLinkDraft)
                        .controlSize(.small)
                        .disabled(isProcessing)
                }
            }
            if let addError {
                Label(addError, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var itemList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach($items) { $item in
                    HStack(spacing: 8) {
                        statusIndicator(for: item)
                            .frame(width: 16)
                            .help(item.statusHelp)
                        Text(item.display)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(item.hasDestination ? .primary : .secondary)
                            .help(item.raw)
                        Spacer(minLength: 8)

                        if let kind = item.predictedFrom {
                            Image(systemName: "wand.and.stars.inverse")
                                .foregroundStyle(.secondary)
                                .help("Destinations picked from what you usually choose for \(kind.phrase). Change them here if not.")
                                .accessibilityLabel("Destinations predicted")
                        }

                        if item.isCleaning {
                            ProgressView().controlSize(.small).scaleEffect(0.6)
                        } else if AITitleCleaner.availability.isAvailable {
                            Button {
                                cleanTitle(for: item.id)
                            } label: {
                                Image(systemName: item.cleanedTitle == nil ? "sparkles" : "sparkles.rectangle.stack")
                                    .foregroundStyle(item.cleanedTitle == nil ? .secondary : Color.accentColor)
                            }
                            .buttonStyle(.plain)
                            .disabled(isProcessing)
                            .help(item.cleanedTitle == nil
                                  ? "Work out the artist and title from this name, on device"
                                  : "Cleaned. Click to try again.")
                        }

                        if item.isCompilation {
                            Image(systemName: "square.stack.3d.down.right")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .help("This looks like a mix or full album — one file holding many tracks, which will import as a single item.")
                        }

                        if item.isLongForm, item.toMusicAudio || item.toMusicVideo {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .help("\(item.durationText ?? "Long") — too long for the Music library. Its audio would import as one very long \"song\" that iTunes Match uploads rather than matches. Apple TV is usually what you want; the import skips Music for it either way.")
                        }

                        DestinationChip(title: "Apple Music", shortTitle: "Song",
                                        symbol: "music.note",
                                        isOn: $item.toMusicAudio, compact: true,
                                        identifier: "item.song")
                            .disabled(isProcessing)
                        DestinationChip(title: "Music Video", shortTitle: "Video",
                                        symbol: "music.note.tv",
                                        isOn: $item.toMusicVideo, compact: true,
                                        identifier: "item.musicVideo")
                            .disabled(isProcessing)
                        DestinationChip(title: "Apple TV", shortTitle: "TV", symbol: "tv",
                                        isOn: $item.toTV, compact: true,
                                        identifier: "item.appleTV")
                            .disabled(isProcessing)
                        DestinationChip(title: "Video to Downloads", shortTitle: "Video",
                                        symbol: "arrow.down.circle",
                                        isOn: $item.toDownloads, compact: true,
                                        identifier: "item.downloads")
                            .disabled(isProcessing)
                        DestinationChip(title: "Audio to Downloads", shortTitle: "Audio",
                                        symbol: "arrow.down.circle",
                                        isOn: $item.toDownloadsAudio, compact: true,
                                        identifier: "item.downloadsAudio")
                            .disabled(isProcessing)

                        if item.status == .done || item.status == .failed, !item.downloadedURLs.isEmpty {
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting(item.downloadedURLs)
                            } label: {
                                Image(systemName: "magnifyingglass.circle.fill")
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .help("Show in Finder")
                            .accessibilityLabel("Show \(item.display) in Finder")
                        }

                        Button {
                            items.removeAll { $0.id == item.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove from the queue")
                        .accessibilityLabel("Remove \(item.display)")
                        .disabled(isProcessing)
                    }
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    // Sending an already-imported item somewhere new is a reason
                    // to run it again.
                    .onChange(of: item.destination) { destinationsEdited(item.id) }

                    if item.id != items.last?.id {
                        Divider().padding(.leading, 34)
                    }
                }
            }
        }
        .frame(minHeight: 92, maxHeight: .infinity)
    }

    @ViewBuilder
    private func statusIndicator(for item: InputItem) -> some View {
        switch item.status {
        case .queued:
            Image(systemName: item.symbol)
                .foregroundStyle(item.hasDestination ? .secondary : .tertiary)
        case .running:
            ProgressView().controlSize(.small).scaleEffect(0.6)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .skipped:
            Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }

    private var dropPrompt: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(isDropTargeted ? Color.accentColor : .secondary)
            Text("Drop videos here")
                .font(.headline)
            Text(dropHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            HStack(spacing: 8) {
                Button("Choose Files…", action: chooseFiles)
                    .disabled(isProcessing)
                Button("Paste Links", action: pasteFromClipboard)
                    .disabled(isProcessing)
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 18)
        .padding(.horizontal, 16)
    }

    /// Queued items still to import, failures excluded: the "N items ready"
    /// count, also shown as the Dock badge (#159).
    private var readyCount: Int {
        items.filter { $0.isPending && $0.status != .failed }.count
    }

    /// One-line description of what "Convert & Import" would act on.
    private var inputSummary: String {
        let done = items.filter { $0.status == .done }.count
        let failed = items.filter { $0.status == .failed }.count
        let ready = readyCount
        let noDestination = items.filter { !$0.hasDestination }.count

        var parts: [String] = []
        if done > 0 { parts.append("\(done) imported") }
        if failed > 0 { parts.append("\(failed) failed") }
        if ready > 0 || parts.isEmpty {
            parts.append("\(ready) item\(ready == 1 ? "" : "s") ready")
        }
        if noDestination > 0 { parts.append("\(noDestination) without a destination") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Destinations

    private var destinationRow: some View {
        HStack(spacing: 8) {
            DestinationChip(title: "Apple Music", shortTitle: "Song", symbol: "music.note",
                            isOn: $importMusicAudio, identifier: "destination.song")
                .help("The song (.m4a) — default for items you add next; each queued item can override it")
            DestinationChip(title: "Music Video", shortTitle: "Video", symbol: "music.note.tv",
                            isOn: $importMusicVideo, identifier: "destination.musicVideo")
                .help("The music video (.mp4) into the Music library — default for items you add next")
            DestinationChip(title: "Apple TV", symbol: "tv", isOn: $importToTV,
                            identifier: "destination.appleTV")
                .help("Default destination for items you add next — each queued item can override it")
            DestinationChip(title: "Video to Downloads", shortTitle: "Video",
                            symbol: "arrow.down.circle", isOn: $importToDownloads,
                            identifier: "destination.downloads")
                .help("The video (.mp4) into ~/Downloads — no library needed")
            DestinationChip(title: "Audio to Downloads", shortTitle: "Audio",
                            symbol: "arrow.down.circle", isOn: $importToDownloadsAudio,
                            identifier: "destination.downloadsAudio")
                .help("The song (.m4a) into ~/Downloads — no library needed")
            Spacer()
            Toggle("Clean titles", isOn: $cleanMetadata)
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Strip “(Official Video)”, channel suffixes, etc. and split Artist / Title.")
        }
    }

    // MARK: - Actions

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button(action: { processURLs() }) {
                Text(actionTitle)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(isProcessing || !canStart)
            .help(blockedReason ?? "Convert and import the items above")

            Button("Stop", action: stopProcessing)
                .controlSize(.large)
                .disabled(!isProcessing)

            Button("Clear", action: clearAll)
                .controlSize(.large)
                .disabled(isProcessing)
                .help("Clear the input and log")
        }
    }

    /// Names what the button will act on, so the count doesn't live only in the
    /// card's footer.
    private var actionTitle: String {
        if isProcessing { return "Processing…" }
        let pending = items.filter(\.isPending).count
        guard pending > 0 else { return "Convert & Import" }
        return "Convert & Import \(pending) item\(pending == 1 ? "" : "s")"
    }

    // MARK: - Status

    private var statusStrip: some View {
        HStack(spacing: 8) {
            if isProcessing {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 14, height: 14)
            } else if blockedReason != nil {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .frame(width: 14, height: 14)
            } else {
                Image(systemName: "circle.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14, height: 14)
            }
            Text(blockedReason ?? statusLine)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showLogDetails.toggle() }
            } label: {
                HStack(spacing: 3) {
                    Text(showLogDetails ? "Hide Details" : "Show Details")
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .rotationEffect(.degrees(showLogDetails ? 90 : 0))
                }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Show the raw conversion output")
        }
    }

    /// Why "Convert & Import" is unavailable, or nil when it can run. A greyed-out
    /// button with no explanation is the single easiest thing to get stuck on here,
    /// so the status strip says what is missing instead of just "Ready".
    private var blockedReason: String? {
        guard !isProcessing else { return nil }
        if items.isEmpty {
            return defaultDestination.isEmpty
                ? "Turn on a destination — Song, Video and/or Apple TV — then add a link or a file."
                : nil
        }
        if !items.contains(where: \.isPending) {
            return items.contains { $0.status == .done }
                ? "Everything in the queue has been imported — clear it, or add something new."
                : "Give at least one item a destination — Apple Music and/or Apple TV."
        }
        return nil
    }

    /// Most recent meaningful log line — the one-line summary shown when the
    /// detail log is collapsed.
    private var statusLine: String {
        ContentView.statusText(installStatus: installStatus, entries: logEntries)
    }

    /// The one-line status under the button: the latest log line that doesn't
    /// name a tool. The pipeline announces "Using yt-dlp…" and "Using ffmpeg…"
    /// on every import, and an install narrates in Homebrew's own voice
    /// ("==> Updating Homebrew..."); the window otherwise never names them
    /// (#80, #113). Those lines stay in Details and the log file. During an
    /// install the status is a fixed message.
    static func statusText(installStatus: String?, entries: [String]) -> String {
        if let installStatus { return installStatus }
        let last = entries.last { entry in
            let text = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            return !text.isEmpty && !namesATool(text)
        }
        return last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Ready"
    }

    private static let toolNames = try! NSRegularExpression(
        pattern: #"\b(yt-dlp|ffmpeg|ffprobe|homebrew|brew)\b"#, options: [.caseInsensitive])

    static func namesATool(_ text: String) -> Bool {
        toolNames.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private var logPane: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Details")
                    .font(.caption).bold()
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: copyLogToClipboard) {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Copy log to clipboard")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)

            Divider()

            ScrollViewReader { scrollView in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(logEntries.indices, id: \.self) { index in
                            Text(logEntries[index])
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .frame(minHeight: 150)
                // The pane is built fresh every time "Show Details" is opened,
                // so scroll to the newest line on appear as well — otherwise a
                // run's errors sit below the fold at the top of the log.
                .onAppear { scrollToLatest(scrollView) }
                .onChange(of: logEntries.count) {
                    withAnimation { scrollToLatest(scrollView) }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.25))
        )
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        guard !logEntries.isEmpty else { return }
        proxy.scrollTo(logEntries.count - 1, anchor: .bottom)
    }

    // MARK: - Dependencies

    /// Days since the installed yt-dlp was released, or nil if it couldn't be read.
    private var ytDlpAgeInDays: Int? {
        guard let version = ytDlpVersion else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy.MM.dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        guard let released = formatter.date(from: String(version.prefix(10))) else { return nil }
        return Calendar.current.dateComponents([.day], from: released, to: Date()).day
    }

    /// yt-dlp warns about itself past 90 days, and that is roughly when YouTube
    /// starts answering its requests with HTTP 403 — which surfaces here as an
    /// item that simply fails with no obvious cause.
    private var ytDlpIsStale: Bool { (ytDlpAgeInDays ?? 0) > 90 }

    /// A solver failure says so outright. A 360p fallback only counts when the
    /// installed yt-dlp is old enough to be the likely cause — some genuinely
    /// old uploads have no better format.
    private var ytDlpBlocked: Bool {
        solverFailureSeen || (format18FallbackSeen && ytDlpIsStale)
    }

    private var dependencyFooter: some View {
        HStack(spacing: 6) {
            if dependenciesReady, ytDlpBlocked {
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                Text("A component needs updating — downloads are limited to 360p")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Button("Update", action: updateYtDlp)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isProcessing)
                    .help("Updates the component that fetches and converts media")
            } else if dependenciesReady, ytDlpIsStale, let age = ytDlpAgeInDays {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text("A component is \(age) days old — downloads may start failing")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Button("Update", action: updateYtDlp)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isProcessing)
                    .help("Updates the component that fetches and converts media")
            } else if dependenciesReady {
                Image(systemName: "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                Text("All components installed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Re-check", action: refreshDependencyStatus)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            } else if checkingDependencies {
                // After an install the check takes a few seconds — a freshly
                // installed tool is slow to start the first time — and the old
                // "missing" verdict, with an Install button, sat under a status
                // line already saying "Components ready." (#80).
                ProgressView()
                    .controlSize(.mini)
                Text("Checking components…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text("Required components are missing")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                // Everything is fetched directly now, so there's one button
                // whatever is missing, and no Homebrew path behind it (#80).
                Button("Install", action: installDependencies)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isProcessing)
                    .help("Fetches the missing components and verifies them — no Terminal needed")
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - iMessage intake

    private func handleIncomingURLsFromMessages(_ urls: [String]) {
        guard !urls.isEmpty else { return }
        appendLog("[iMessage] received \(urls.count) URL(s)")
        // Don't fold incoming URLs into the queue — that would cause every
        // subsequent iMessage URL to re-import whatever the user left queued from
        // a previous session. Route the new URLs directly to the pipeline.
        guard !defaultDestination.isEmpty else {
            appendLog("[iMessage] no destination enabled; dropping")
            return
        }
        let originatingChatGUID = iMessageWatcher.selectedChatGUID
        if isProcessing {
            if let guid = originatingChatGUID {
                // Snapshot the destinations as they were when the URL arrived —
                // draining later with whatever the chips say by then would import
                // somewhere the sender never asked for.
                pendingFromMessages.append((urls: urls, chatGUID: guid,
                                            destination: defaultDestination))
            }
            appendLog("[iMessage] queued; will run after current job")
        } else {
            beginBlockedDetection()
            runPipeline(with: urls, destination: defaultDestination,
                        tracksQueue: false, replyToChatGUID: originatingChatGUID)
        }
    }

    /// The chips above the queue: what a newly added item inherits, and what the
    /// iMessage watcher imports with.
    private var defaultDestination: Destination {
        Destination(musicAudio: importMusicAudio, musicVideo: importMusicVideo,
                    tv: importToTV, downloads: importToDownloads,
                    downloadsAudio: importToDownloadsAudio)
    }

    private var canStart: Bool {
        items.contains(where: \.isPending)
    }

    /// Normalizes one input into something the pipeline accepts, or nil if
    /// it's neither a web URL nor an existing local file. Web URLs pass through
    /// unchanged; `file://` URLs and bare paths (drag-dropped or pasted) are
    /// resolved to a plain filesystem path the script can test with `-f`.
    private func normalizedInput(_ s: String) -> String? {
        guard !s.isEmpty else { return nil }
        if let scheme = URL(string: s)?.scheme?.lowercased(), scheme.hasPrefix("http") { return s }
        let path: String
        if s.hasPrefix("file://"), let filePath = URL(string: s)?.path {
            path = filePath
        } else {
            path = (s as NSString).expandingTildeInPath
        }
        // Must be an existing file, not a directory — the script's `[[ -f ]]`
        // would reject a folder and then mistakenly treat it as a URL.
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        if exists && !isDir.boolValue { return path }

        // A host typed by hand ("youtube.com/watch?v=…") is a link the user
        // meant; give it a scheme rather than rejecting it. Everything else is a
        // mistyped path, and guessing a scheme for it would only send garbage to
        // yt-dlp: reject anything already carrying a scheme we didn't accept
        // above (file://, ftp://), anything shaped like a media filename, and
        // anything whose leading component isn't domain-like.
        guard !s.contains("://"), !s.contains(" "),
              !s.hasPrefix("/"), !s.hasPrefix("~"), !s.hasPrefix(".") else { return nil }

        // Query strings carry their own dots and extensions, so judge the shape
        // on the part before "?" only ("clip.mp4?x=1" is still a filename).
        let beforeQuery = s.split(separator: "?", maxSplits: 1).first.map(String.init) ?? s
        let mediaExtensions: Set<String> = [
            "mp4", "mkv", "webm", "mov", "m4v", "avi", "flv", "mpeg", "mpg",
            "wmv", "ts", "m2ts", "ogv", "3gp", "m4a", "mp3", "aac", "flac", "wav"
        ]
        guard !mediaExtensions.contains((beforeQuery as NSString).pathExtension.lowercased()) else {
            return nil
        }

        let host = beforeQuery.split(separator: "/", maxSplits: 1).first.map(String.init) ?? beforeQuery
        let domainish = #"^[A-Za-z0-9][A-Za-z0-9.\-]*\.[A-Za-z]{2,}$"#
        guard host.range(of: domainish, options: .regularExpression) != nil else { return nil }
        return "https://" + s
    }

    /// Queues anything that arrived through the catchmatch:// scheme.
    private func drainExternalRequests() {
        // Same rule as every other way of changing the queue: not while a run is
        // in flight. Requests wait in the router instead of being dropped, and
        // drain when the run ends — sending pages from Safari back to back is
        // the normal case now that a send starts the import (#84).
        guard !isProcessing else { return }
        let requests = externalRequests.drain()
        guard !requests.isEmpty else { return }
        var autoStartIDs = Set<UUID>()
        for request in requests {
            guard addInput(request.url), let normalized = normalizedInput(request.url) else {
                appendLog("Ignored a request for something that isn't a link: \(request.url)")
                continue
            }
            // Find the row this request is actually about. Taking the last item
            // would be wrong whenever the URL was already queued — addInput
            // dedupes and appends nothing, and the override would land on some
            // unrelated row instead.
            guard let index = items.lastIndex(where: { $0.raw == normalized }) else { continue }
            if request.autoStart { autoStartIDs.insert(items[index].id) }
            // A request that names destinations overrides the chips for its own
            // item only; one that doesn't inherits them like anything else.
            // "music" means Apple Music as a whole, like the script's --music:
            // both the song and the music video (#85).
            // Named destinations aren't a prediction; on a row appended just now
            // onChange never sees the change, so the hint is cleared here (#166).
            if request.music != nil || request.tv != nil
                || request.downloads != nil || request.downloadsAudio != nil {
                items[index].predictedFrom = nil
            }
            if let music = request.music {
                items[index].toMusicAudio = music
                items[index].toMusicVideo = music
            }
            if let tv = request.tv { items[index].toTV = tv }
            if let downloads = request.downloads { items[index].toDownloads = downloads }
            if let audio = request.downloadsAudio { items[index].toDownloadsAudio = audio }
        }
        // A request fills the queue and a person starts it — unless it came from
        // our own Safari extension, where pressing Send was that person starting
        // it. See ExternalRequestRouter.accept and ExtensionSender.
        if !autoStartIDs.isEmpty {
            appendLog("Starting the import sent from Safari…")
            processURLs(only: autoStartIDs)
        }
    }

    /// Asks the on-device model to work out the artist and title for one item.
    /// Only accepted above the cleaner's confidence floor — a guess presented as
    /// an answer is worse than the raw name, which is at least honestly messy.
    private func cleanTitle(for id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items[index]
        items[index].isCleaning = true

        Task {
            let result = await AITitleCleaner.clean(rawTitle: item.cleanableName, uploader: nil)
            guard let position = items.firstIndex(where: { $0.id == id }) else { return }
            items[position].isCleaning = false

            guard let result else {
                appendLog("Couldn't work out a name for \(item.cleanableName).")
                return
            }
            guard result.confidence >= AITitleCleaner.minimumConfidence else {
                appendLog("Not confident enough about \(item.cleanableName) — leaving it as it is.")
                return
            }
            items[position].cleanedArtist = result.artist.isEmpty ? nil : result.artist
            items[position].cleanedTitle = result.title
            items[position].isCompilation = result.isCompilation
            appendLog("Cleaned: \(result.artist.isEmpty ? result.title : "\(result.artist) — \(result.title)")")
        }
    }

    /// Reads a local file's duration in the background so the row can warn
    /// before the run does. Only for files: a link's length isn't knowable
    /// without fetching it, which is the run's job.
    private func probeDurationIfLocal(_ raw: String) {
        guard !raw.lowercased().hasPrefix("http") else { return }
        DispatchQueue.global(qos: .utility).async {
            let seconds = mediaDurationSeconds(path: raw)
            guard let seconds else { return }
            DispatchQueue.main.async {
                guard let index = items.firstIndex(where: { $0.raw == raw }) else { return }
                items[index].durationSeconds = seconds
            }
        }
    }

    /// Brings this window forward. A file arriving by drop or from the Dock is a
    /// direct request, so taking focus is what was asked for.
    private func surface() {
        NSApp.activate(ignoringOtherApps: true)
        hostWindow.window?.makeKeyAndOrderFront(nil)
    }

    /// Takes anything opened from outside the window (Dock drop, Open With) into
    /// the queue.
    private func queueExternalOpens() {
        let paths = externalOpens.drain()
        guard !paths.isEmpty else { return }
        for path in paths { appendURL(path) }
        surface()
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        // Every other way of changing the queue is disabled mid-run; the
        // window-level drop target has to be too, or rows land in a queue that
        // can't be edited or cleared until the run finishes.
        guard !isProcessing else { return false }
        var handled = false
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    DispatchQueue.main.async {
                        if let s = url?.absoluteString { appendURL(s) }
                    }
                }
                handled = true
            } else if provider.canLoadObject(ofClass: NSString.self) {
                _ = provider.loadObject(ofClass: NSString.self) { obj, _ in
                    DispatchQueue.main.async {
                        if let s = obj as? String { appendURL(s) }
                    }
                }
                handled = true
            }
        }
        // A drop can land while the app is behind something else; without this
        // the queue silently grows out of sight.
        if handled { surface() }
        return handled
    }

    /// Validates one input and appends it to the queue. Returns false when it is
    /// neither a link nor an existing file, so callers can report it.
    @discardableResult
    private func addInput(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let normalized = normalizedInput(trimmed) else { return false }
        guard !items.contains(where: { $0.raw == normalized }) else { return true }
        // What this kind of input usually gets, unless the chips were set by
        // hand this session (#166).
        let kind = DestinationPredictor.InputKind(raw: normalized)
        var destination = defaultDestination
        var predictedFrom: DestinationPredictor.InputKind?
        if !chipsChosenThisSession, !ScreenshotMode.isActive,
           let predicted = destinationPredictor.prediction(for: kind, tieBreaker: destination),
           predicted != destination {
            destination = predicted
            predictedFrom = kind
        }
        items.append(InputItem(raw: normalized,
                               toMusicAudio: destination.musicAudio,
                               toMusicVideo: destination.musicVideo,
                               toTV: destination.tv,
                               toDownloads: destination.downloads,
                               toDownloadsAudio: destination.downloadsAudio,
                               predictedFrom: predictedFrom))
        probeDurationIfLocal(normalized)
        return true
    }

    /// Queues a dropped payload. A text drop can carry several newline-separated
    /// URLs, so it is split the same way a paste is.
    private func appendURL(_ s: String) {
        let lines = s.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return }
        let added = lines.filter { addInput($0) }.count
        if added == 0 {
            addError = "Couldn't add that — it isn't a link or a video file."
        } else if added == lines.count {
            addError = nil
        } else {
            addError = "Added \(added) of \(lines.count) — the rest weren't links or video files."
        }
    }

    /// Commits the link field. Handles a multi-line paste too: a ⌘V of several
    /// URLs lands as one string, and each line becomes its own queue entry.
    private func commitLinkDraft() {
        let lines = linkDraft
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return }
        let added = lines.filter { addInput($0) }.count
        if added == lines.count {
            linkDraft = ""
            addError = nil
        } else {
            addError = added == 0
                ? "Not a link or a file that exists."
                : "Added \(added) of \(lines.count) — the rest weren't links or existing files."
            if added > 0 { linkDraft = "" }
        }
    }

    /// Reliable, focus-independent way to add local video files. Queues each
    /// chosen file (the pipeline validates it has a video stream). Type filtering
    /// is intentionally left open so container formats like .mkv — which don't
    /// map cleanly to a system UTType — aren't excluded.
    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { addInput(url.path) }
        addError = nil
    }

    /// Queues everything on the clipboard, one entry per line.
    private func pasteFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        let added = lines.filter { addInput($0) }.count
        if added == 0 {
            addError = "Nothing on the clipboard looked like a link or a file."
        } else {
            addError = nil
        }
    }

    /// Splits the queue into one batch per destination combination and starts the
    /// first; the rest drain as each run finishes.
    /// `only` limits the run to those rows — a Safari send starts what it sent,
    /// not whatever else, perhaps queued by a web page, is waiting (#84).
    private func processURLs(only: Set<UUID>? = nil) {
        let pending = items.filter { $0.isPending && (only?.contains($0.id) ?? true) }

        // The script takes one title override per run, so an item carrying an
        // accepted name goes in a batch of its own; the rest are grouped by
        // whichever destination combinations are actually present.
        let named = pending.filter { $0.cleanedTitle != nil && !$0.destination.isEmpty }
        var batches: [QueuedBatch] = named.map {
            QueuedBatch(urls: [$0.raw], destination: $0.destination,
                        titleOverride: $0.cleanedTitle, artistOverride: $0.cleanedArtist)
        }
        var grouped: [Destination: [String]] = [:]
        for item in pending where item.cleanedTitle == nil && !item.destination.isEmpty {
            grouped[item.destination, default: []].append(item.raw)
        }
        // Deterministic order, so a run's batches don't shuffle between presses.
        batches += grouped
            .sorted { $0.key.scriptFlags.joined() < $1.key.scriptFlags.joined() }
            .map { QueuedBatch(urls: $0.value, destination: $0.key) }

        guard let first = batches.first else {
            appendLog(items.contains { $0.status == .done }
                ? "Everything in the queue has already been imported."
                : "No item has a destination.")
            return
        }

        let alreadyDone = items.filter { $0.status == .done }.count
        if alreadyDone > 0 {
            appendLog("Skipping \(alreadyDone) already-imported item\(alreadyDone == 1 ? "" : "s").")
        }
        let noDestination = items.filter { !$0.hasDestination }.count
        if noDestination > 0 {
            appendLog("Skipping \(noDestination) item\(noDestination == 1 ? "" : "s") with no destination.")
        }
        // Reset the previous outcome on everything taking part, mark items with
        // no destination as skipped, and leave already-imported rows alone.
        let running = Set(pending.map(\.id))
        for index in items.indices {
            if !items[index].hasDestination {
                items[index].status = .skipped
            } else if items[index].status != .done, running.contains(items[index].id) {
                items[index].status = .queued
            }
        }
        pendingBatches = Array(batches.dropFirst())
        beginBlockedDetection()
        runPipeline(with: first.urls, destination: first.destination,
                    titleOverride: first.titleOverride, artistOverride: first.artistOverride,
                    replyToChatGUID: nil)
    }

    /// Runs the pipeline for an explicit list of URLs. Used by both the manual
    /// "Convert & Import" button (which passes the queue) and the iMessage
    /// watcher (which passes only the freshly received URLs to avoid re-importing
    /// whatever the user left queued from a previous session).
    /// When `replyToChatGUID` is non-nil, a confirmation message is sent back to
    /// that chat once the pipeline completes.
    /// - Parameter tracksQueue: whether this run's output should drive the
    ///   queue's per-row status. False for iMessage-triggered runs: their URLs
    ///   are not queue rows, and a row that happens to hold the same URL must not
    ///   be marked imported by an import it never took part in.
    private func runPipeline(with urls: [String], destination: Destination,
                             titleOverride: String? = nil, artistOverride: String? = nil,
                             tracksQueue: Bool = true, replyToChatGUID: String?) {
        guard !urls.isEmpty else {
            appendLog("No valid URLs to process.")
            return
        }
        guard !destination.isEmpty else {
            appendLog("Select at least one destination (Apple Music and/or Apple TV).")
            return
        }

        isProcessing = true
        appendLog("\nStarting (\(urls.count) URL\(urls.count == 1 ? "" : "s"))…")

        // Capture imported track names from script output so we can build a reply.
        let collectedLines = LineCollector()

        DispatchQueue.global(qos: .userInitiated).async {
            guard let scriptPath = getScriptPath() else {
                DispatchQueue.main.async {
                    isProcessing = false
                    appendLog("Error: part of CatchMatch is missing from the app. Reinstalling CatchMatch should fix this.")
                    drainQueue()
                }
                return
            }

            var args = [scriptPath]
            args.append(contentsOf: destination.scriptFlags)
            if !cleanMetadata { args.append("--no-clean-metadata") }
            if let titleOverride {
                args.append(contentsOf: ["--item-title", titleOverride])
                if let artistOverride {
                    args.append(contentsOf: ["--item-artist", artistOverride])
                }
            }
            args.append(contentsOf: urls)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = args
            // The script's test seams pick the tools it runs and the folders it
            // copies into. A shipped app inherits whatever environment launched
            // it, so they are stripped here rather than trusted (#109).
            var environment = ProcessInfo.processInfo.environment
            for key in ["CM_TOOL_PATH", "CM_MUSIC_IMPORT", "CM_TV_IMPORT"] {
                environment.removeValue(forKey: key)
            }
            process.environment = environment

            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = outputPipe

            // A pipe read is a chunk of bytes, not a tidy set of lines: a banner
            // or a "→ …" record can be split across two reads, which would break
            // both the status parsing and the iMessage reply's title parsing.
            let lineBuffer = LineBuffer()
            let emit: ([String]) -> Void = { lines in
                guard !lines.isEmpty else { return }
                for line in lines {
                    scriptLog.log("\(line, privacy: .public)")
                    AppLog.shared.log(line)
                }
                collectedLines.append(lines)
                DispatchQueue.main.async {
                    logEntries.append(contentsOf: lines)
                    for line in lines {
                        // Runs on every run, not just queue-driven ones: an
                        // iMessage import hits the same wall.
                        scanForBlockedExtractor(line)
                        if tracksQueue { trackItemProgress(line) }
                    }
                }
            }

            DispatchQueue.main.async { runningProcess = process }

            do {
                try process.run()

                // Read the pipe to EOF on this thread rather than through a
                // readabilityHandler. One reader means the buffer is never touched
                // concurrently, and EOF — the child's write end closing — is a hard
                // guarantee that every line has been emitted before the completion
                // block is queued, so a batch's output can't reattribute itself to
                // the next batch. Draining as we go also keeps the child from
                // blocking on a full pipe.
                //
                // Known limitation: Stop terminates bash, and in practice the
                // signal reaches yt-dlp/ffmpeg too (they report "Terminated: 15").
                // A grandchild that survived it would inherit this write end and
                // hold EOF open, leaving the window stuck in its processing state.
                // Fixing that properly means putting the child in its own process
                // group and signalling the group.
                let handle = outputPipe.fileHandleForReading
                while true {
                    let data = handle.availableData
                    if data.isEmpty { break }
                    emit(lineBuffer.take(data))
                }
                emit(lineBuffer.flush())

                process.waitUntilExit()
                let status = process.terminationStatus
                let reason = process.terminationReason
                DispatchQueue.main.async {
                    isProcessing = false
                    runningProcess = nil
                    if reason == .uncaughtSignal {
                        // Stopped mid-item: it didn't fail, it never finished.
                        if tracksQueue, let raw = currentItemRaw { setStatus(.queued, for: raw) }
                        currentItemRaw = nil
                        currentItemProducedOutput = false
                        currentItemHadError = false
                    } else if tracksQueue {
                        finishCurrentItem(succeeded: currentItemSucceeded)
                    }
                    let msg = reason == .uncaughtSignal
                        ? "Stopped."
                        : (status == 0 ? "Done." : "Finished with errors (status \(status)).")
                    appendLog(msg)
                    scriptLog.log("\(msg, privacy: .public)")

                    // A tracked run counts itself as each row finishes; an
                    // iMessage run has no rows, so count what the script says it
                    // imported.
                    if !tracksQueue, reason != .uncaughtSignal {
                        let imported = ContentView.importedItemCount(lines: collectedLines.snapshot())
                        for _ in 0..<imported {
                            UsageAnalytics.shared.send(.importCompleted, params: ["source": "imessage"])
                        }
                        // No rows to settle, so a run with errors counts once as
                        // a failure rather than per item (#157).
                        if status != 0 {
                            UsageAnalytics.shared.send(.importFailed, params: ["source": "imessage"])
                        }
                    }

                    if let chatGUID = replyToChatGUID, reason != .uncaughtSignal {
                        let summary = ContentView.buildReplySummary(
                            urls: urls,
                            status: status,
                            lines: collectedLines.snapshot()
                        )
                        ContentView.sendReply(text: summary, chatGUID: chatGUID, logEntries: $logEntries)
                    }

                    if reason == .uncaughtSignal {
                        // User pressed Stop. Don't auto-start the next queued batch —
                        // that would feel like the Stop button silently didn't work.
                        // Clear any pending iMessage URLs too; if they want them, they
                        // can re-send.
                        if !pendingBatches.isEmpty {
                            appendLog("Stop pressed — discarded \(pendingBatches.count) remaining destination group(s)")
                            pendingBatches.removeAll()
                        }
                        if !pendingFromMessages.isEmpty {
                            appendLog("[iMessage] Stop pressed — discarded \(pendingFromMessages.count) queued batch(es)")
                            pendingFromMessages.removeAll()
                        }
                    } else {
                        drainQueue()
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    isProcessing = false
                    runningProcess = nil
                    if tracksQueue { finishCurrentItem(succeeded: false) }
                    appendLog("Failed to run script: \(error.localizedDescription)")
                    if let chatGUID = replyToChatGUID {
                        ContentView.sendReply(
                            text: "❌ \(Constants.appName) couldn't start: \(error.localizedDescription)",
                            chatGUID: chatGUID,
                            logEntries: $logEntries
                        )
                    }
                    drainQueue()
                }
            }
        }
    }

    /// Continues the current run's remaining destination groups, then falls
    /// through to anything the iMessage watcher queued while it was busy.
    /// Maps one line of script output onto the queue. The script announces each
    /// input with "=== Processing: X ===" and reports a finished copy with a
    /// "→ Music …" / "→ TV: …" line, which is enough to tell rows apart without
    /// changing the script's protocol.
    /// ICU wants `\x{...}` for a codepoint; `\u{...}` is Swift syntax and means
    /// nothing inside a raw-string pattern, where it would silently match nothing.
    private static let ansiEscape = #"\x{1B}\[[0-9;]*[A-Za-z]"#

    /// Watches for the signs that yt-dlp can no longer unlock YouTube's good
    /// formats: the signature / nsig solvers failing, or the giveaway that it
    /// fell back to format 18 — the 360p, 96 kbps stream YouTube hands out when
    /// nothing better could be decrypted.
    private func scanForBlockedExtractor(_ line: String) {
        let lowered = line
            .replacingOccurrences(of: Self.ansiEscape, with: "", options: .regularExpression)
            .lowercased()
            .trimmingCharacters(in: .whitespaces)

        // A solver failure is unambiguous: yt-dlp says outright that it couldn't
        // work the challenge out. (These strings are YouTube's; another
        // extractor emitting something similar would still be told to update
        // yt-dlp, which is the right advice either way.)
        let solverFailed = [
            "signature solving failed",
            "signature extraction failed",
            "n challenge solving failed",
            "nsig extraction failed"
        ].contains { lowered.contains($0) }

        // Format 18 on its own is *not* proof. It's the 360p combined stream
        // yt-dlp falls back to when it can't decrypt anything better — but it's
        // also the only format some genuinely old uploads have. Anchor it to the
        // end of the line so "18" can't match "18+140" or "180", and only treat
        // it as evidence when the installed yt-dlp is old enough to be the
        // likely cause.
        let fellBackTo360p = lowered.hasSuffix("downloading 1 format(s): 18")

        guard solverFailed || fellBackTo360p else { return }
        if solverFailed { solverFailureSeen = true }
        if fellBackTo360p { format18FallbackSeen = true }

        // The 360p tell may arrive before the version probe does, in which case
        // it isn't yet a verdict — the probe landing is what settles it, and
        // that path announces too.
        announceBlockedIfNeeded()
    }

    /// Starts a fresh round of detection for one logical import. The evidence is
    /// per-run: if yt-dlp is still blocked the very next run re-detects it, and
    /// if it isn't, the warning clears itself instead of standing until the
    /// version changes.
    private func beginBlockedDetection() {
        solverFailureSeen = false
        format18FallbackSeen = false
        ytDlpBlockedAnnounced = false
    }

    /// Says it once, wherever the verdict happens to be reached: at scan time
    /// for a solver failure, or later when the version probe confirms a 360p
    /// fallback came from a stale yt-dlp.
    private func announceBlockedIfNeeded() {
        guard ytDlpBlocked, !ytDlpBlockedAnnounced else { return }
        ytDlpBlockedAnnounced = true
        appendLog("→ A component is out of date, so only low-quality formats were available — this downloads at 360p. Update it below, then run it again.")
    }

    private func trackItemProgress(_ line: String) {
        let banner = "=== Processing: "
        if let range = line.range(of: banner), line.hasSuffix(" ===") {
            let raw = String(line[range.upperBound...].dropLast(4))
            finishCurrentItem(succeeded: currentItemSucceeded)
            currentItemRaw = raw
            currentItemProducedOutput = false
            currentItemHadError = false
            setStatus(.running, for: raw)
            // A re-run makes fresh copies; the older ones aren't this run's.
            if let index = items.firstIndex(where: { $0.raw == raw }) {
                items[index].downloadedFiles = []
            }
            return
        }
        if line.hasPrefix("→ ") {
            currentItemProducedOutput = true
            // Remember the copy, so the row can show it in Finder (#162).
            let prefix = "→ Downloads: "
            if line.hasPrefix(prefix), let raw = currentItemRaw,
               let index = items.firstIndex(where: { $0.raw == raw }) {
                items[index].downloadedFiles.append(String(line.dropFirst(prefix.count)))
            }
            return
        }
        // The script keeps going after a per-video failure, so an item that
        // produced *some* output can still be missing part of a playlist. These
        // markers mean an output file was not produced.
        //
        // The *audio* pass failing is deliberately not one of them: the script
        // says so and falls back to extracting audio from the downloaded video,
        // which is a normal, successful path.
        for marker in ["ffmpeg failed on", "ffmpeg audio extraction failed",
                       "ffmpeg audio tagging failed", "video pass reported errors for"]
        where line.contains(marker) {
            currentItemHadError = true
            return
        }
        if let range = line.range(of: "No media for: ") {
            let raw = String(line[range.upperBound...])
            setStatus(.failed, for: raw)
            UsageAnalytics.shared.send(.importFailed, params: ["source": "queue"])
            if currentItemRaw == raw {
                currentItemRaw = nil
                currentItemProducedOutput = false
            }
        }
    }

    /// A row's destinations changed, by hand or by a request naming them: no
    /// longer a prediction, and a reason to run a finished item again.
    private func destinationsEdited(_ id: UUID) {
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].predictedFrom = nil
        }
        requeueIfFinished(id)
    }

    private func requeueIfFinished(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if items[index].status == .done || items[index].status == .skipped {
            items[index].status = .queued
        }
    }

    private func setStatus(_ status: ItemStatus, for raw: String) {
        guard let index = items.firstIndex(where: { $0.raw == raw }) else { return }
        items[index].status = status
    }

    /// Settles the item the script was last working on. Called when the next
    /// item's banner arrives and again when the run ends.
    private func finishCurrentItem(succeeded: Bool) {
        guard let raw = currentItemRaw else { return }
        setStatus(succeeded ? .done : .failed, for: raw)
        if succeeded, !ScreenshotMode.isActive,
           let item = items.first(where: { $0.raw == raw }) {
            destinationPredictor.record(item.destination, for: DestinationPredictor.InputKind(raw: raw))
        }
        UsageAnalytics.shared.send(succeeded ? .importCompleted : .importFailed,
                                   params: ["source": "queue"])
        currentItemRaw = nil
        currentItemProducedOutput = false
        currentItemHadError = false
    }

    /// Continues the current run's remaining destination groups, then falls
    /// through to anything the iMessage watcher queued while it was busy.
    private func drainQueue() {
        if !pendingBatches.isEmpty {
            let next = pendingBatches.removeFirst()
            appendLog("Next destination group (\(next.urls.count) item\(next.urls.count == 1 ? "" : "s"))…")
            runPipeline(with: next.urls, destination: next.destination,
                        titleOverride: next.titleOverride, artistOverride: next.artistOverride,
                        replyToChatGUID: nil)
            return
        }
        drainPendingMessages()
    }

    private func drainPendingMessages() {
        // Pop the oldest batch first; if more arrived since, they'll drain on the
        // next completion. Use the batch's stored chatGUID so the reply goes to the
        // chat the URL came from, even if the watcher has since been reconfigured,
        // and its stored destinations rather than the current chips.
        //
        // Skip past any batch that can no longer run instead of returning: a
        // single unrunnable batch used to strand every batch behind it.
        while !pendingFromMessages.isEmpty {
            let next = pendingFromMessages.removeFirst()
            guard !next.destination.isEmpty else {
                appendLog("[iMessage] dropped \(next.urls.count) queued URL(s): no destination")
                continue
            }
            appendLog("[iMessage] draining \(next.urls.count) queued URL(s)")
            beginBlockedDetection()
            runPipeline(with: next.urls, destination: next.destination,
                        tracksQueue: false, replyToChatGUID: next.chatGUID)
            return
        }
    }

    /// How many inputs the script reported importing. Counts one per item, not
    /// per copied file: a Music import writes both a `→ Music (audio):` and a
    /// `→ Music (video):` line for the same item.
    private static func importedItemCount(lines: [String]) -> Int {
        // An iMessage run sends every item to the same destinations, so each
        // imported item prints one line per destination it went to. The largest
        // count is the number of items; counting only audio + TV missed
        // video-only runs, which then never used up the trial (#85).
        let audio = lines.filter { $0.hasPrefix("→ Music (audio): ") }.count
        let video = lines.filter { $0.hasPrefix("→ Music (video): ") }.count
        let tv = lines.filter { $0.hasPrefix("→ TV: ") }.count
        // Downloads can take both the song and the video of one item (#164), so
        // each kind is its own count.
        let downloads = lines.filter { $0.hasPrefix("→ Downloads: ") }
        let downloadsAudio = downloads.filter { $0.hasSuffix(".m4a") }.count
        let downloadsVideo = downloads.count - downloadsAudio
        return [audio, video, tv, downloadsAudio, downloadsVideo].max() ?? 0
    }

    /// Parses the script output to extract track names from `→ Music (audio): X.m4a` lines
    /// and assembles a short status message for the reply.
    /// Shows a line in the window's log and writes it to the log file, at the
    /// point it happens. Logging used to be done by watching `logEntries`, which
    /// missed lines when SwiftUI coalesced a clear and an append, and missed whole
    /// runs when the window was closed and the view was not being evaluated
    /// (#134). Screenshot mode is demo text and never reaches the file.
    private func appendLog(_ entry: String) {
        appendLog(contentsOf: [entry])
    }

    private func appendLog(contentsOf entries: [String]) {
        if !ScreenshotMode.isActive {
            for entry in entries { AppLog.shared.log(entry) }
        }
        logEntries.append(contentsOf: entries)
    }

    static func buildReplySummary(urls: [String], status: Int32, lines: [String]) -> String {
        let musicPrefix = "→ Music (audio): "
        let musicVideoPrefix = "→ Music (video): "
        let tvPrefix = "→ TV: "
        let downloadsPrefix = "→ Downloads: "
        var musicTitles: [String] = []
        var musicVideoTitles: [String] = []
        var tvTitles: [String] = []
        var downloadTitles: [String] = []
        var downloadAudioTitles: [String] = []
        for line in lines {
            if let r = line.range(of: musicPrefix) {
                var t = String(line[r.upperBound...])
                if t.hasSuffix(".m4a") { t.removeLast(4) }
                musicTitles.append(t)
            } else if let r = line.range(of: musicVideoPrefix) {
                var t = String(line[r.upperBound...])
                if t.hasSuffix(".mp4") { t.removeLast(4) }
                musicVideoTitles.append(t)
            } else if let r = line.range(of: tvPrefix) {
                var t = String(line[r.upperBound...])
                if t.hasSuffix(".mp4") { t.removeLast(4) }
                tvTitles.append(t)
            } else if let r = line.range(of: downloadsPrefix) {
                var t = String(line[r.upperBound...])
                // The song and the video of one item are one title, not two (#164).
                if t.hasSuffix(".m4a") {
                    t.removeLast(4)
                    downloadAudioTitles.append(t)
                } else {
                    if t.hasSuffix(".mp4") { t.removeLast(4) }
                    downloadTitles.append(t)
                }
            }
        }
        // Prefer Music titles for the reply summary, then TV, then the music
        // video, and finally Downloads — which is all a Downloads-only run has,
        // and saying "no titles parsed" for a run that worked is just wrong (#111).
        let titles = !musicTitles.isEmpty ? musicTitles
            : (!tvTitles.isEmpty ? tvTitles
               : (!musicVideoTitles.isEmpty ? musicVideoTitles
                  : (!downloadTitles.isEmpty ? downloadTitles : downloadAudioTitles)))

        let ok = status == 0
        let head: String
        if titles.isEmpty {
            head = ok
                ? "✅ \(Constants.appName) finished (\(urls.count) URL\(urls.count == 1 ? "" : "s"), no titles parsed)"
                : "⚠️ \(Constants.appName) finished with errors (status \(status))"
        } else if titles.count == 1 {
            head = ok
                ? "✅ Imported: \(titles[0])"
                : "⚠️ Imported \(titles.count) (status \(status)): \(titles[0])"
        } else {
            head = ok
                ? "✅ Imported \(titles.count) tracks:"
                : "⚠️ Imported \(titles.count) (status \(status)):"
        }

        if titles.count > 1 {
            let list = titles.prefix(5).map { "• \($0)" }.joined(separator: "\n")
            let more = titles.count > 5 ? "\n…and \(titles.count - 5) more" : ""
            return head + "\n" + list + more
        }
        return head
    }

    private static func sendReply(text: String, chatGUID: String, logEntries: Binding<[String]>) {
        // Tag every outgoing reply so the recipient instantly knows where it came from.
        // App name is sourced from Constants so a rebrand changes the prefix in one place.
        let tagged = "[\(Constants.appName)] - \(text)"
        DispatchQueue.global(qos: .utility).async {
            let result = IMessageSender.send(text: tagged, toChatGUID: chatGUID)
            DispatchQueue.main.async {
                switch result {
                case .success:
                    AppLog.shared.log("[iMessage] reply sent")
                    logEntries.wrappedValue.append("[iMessage] reply sent")
                case .failure(let err):
                    AppLog.shared.log("[iMessage] reply failed: \(err)", level: .error)
                    logEntries.wrappedValue.append("[iMessage] reply failed: \(err)")
                }
            }
        }
    }

    private func stopProcessing() {
        guard let p = runningProcess, p.isRunning else { return }
        appendLog("Stopping…")
        // terminate() signals only bash. A child it started — yt-dlp, ffmpeg,
        // brew — would survive it and keep the output pipe open, so the reader
        // never reaches the end and the window stays busy until that child
        // finishes on its own. Stop the whole tree, deepest first.
        for child in ContentView.descendants(of: p.processIdentifier) {
            kill(child, SIGTERM)
        }
        p.terminate()
    }

    /// Every process below `pid`, deepest first. `pgrep -P` lists only direct
    /// children, and yt-dlp starts its own ffmpeg, so the tree is walked.
    static func descendants(of pid: pid_t) -> [pid_t] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-P", String(pid)]
        let out = Pipe()
        task.standardOutput = out
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let children = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0) }
        return children.flatMap { descendants(of: $0) + [$0] }
    }

    private func getScriptPath() -> String? {
        let candidates = [
            Bundle.main.path(forResource: "dlp2music", ofType: "sh"),
            FileManager.default.currentDirectoryPath + "/dlp2music.sh",
            "/usr/local/bin/dlp2music.sh"
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0) }
    }

    private func copyLogToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(logEntries.joined(separator: "\n"), forType: .string)
    }

    /// Resets the UI to a clean state: empties the queue and the log. Disabled
    /// while a run is in flight.
    private func clearAll() {
        items = []
        pendingBatches = []
        currentItemRaw = nil
        currentItemProducedOutput = false
        linkDraft = ""
        addError = nil
        logEntries = ["Ready"]
    }

    /// Detects whether the tools the pipeline needs (yt-dlp for URL fetch,
    /// ffmpeg for transcode) are on PATH, and drives the main-window install
    /// button's installed/not-installed state. Mirrors the onboarding check's
    /// invocation so both surfaces agree.
    private func refreshDependencyStatus() {
        depCheckSeq += 1
        let seq = depCheckSeq
        checkingDependencies = true
        DispatchQueue.global(qos: .utility).async {
            let hasYtDlp = toolExists("yt-dlp")
            // The pipeline runs both, so one without the other is not ready.
            let hasFfmpeg = toolExists("ffmpeg") && toolExists("ffprobe")
            let ready = hasYtDlp && hasFfmpeg
            let version = hasYtDlp ? installedYtDlpVersion() : nil
            DispatchQueue.main.async {
                // Ignore a slower, stale probe that finished after a newer one
                // was kicked off (onAppear / didBecomeActive / Re-check overlap).
                guard seq == depCheckSeq else { return }
                checkingDependencies = false
                dependenciesReady = ready
                ffmpegReady = hasFfmpeg
                ytDlpReady = hasYtDlp
                ytDlpVersion = version
            }
        }
    }

    /// Re-downloads the managed yt-dlp — how Update refreshes a copy the app
    /// installed itself.
    private func installYtDlp() {
        Task {
            isProcessing = true
            installStatus = "Updating components…"
            appendLog("\nUpdating the media fetcher…")
            _ = await runInstall("The media fetcher") { await ToolManager.shared.installYtDlp() }
            isProcessing = false
            refreshDependencyStatus()
            drainPendingMessages()
        }
    }

    /// Installs whichever components are missing, straight from where they are
    /// published: ffmpeg and ffprobe are our LGPL build from the product site,
    /// yt-dlp comes from its own releases. No Homebrew, no Terminal, no admin
    /// password — setup used to send anyone without Homebrew to Terminal to
    /// paste a bootstrap command (#80).
    private func installDependencies() {
        // Set before the Task starts, so a quick second click finds the button
        // already disabled.
        isProcessing = true
        Task {
            installStatus = "Installing components — this can take a few minutes…"
            appendLog("\nInstalling the missing components…")
            if !ffmpegReady {
                _ = await runInstall("The media converter") { await ToolManager.shared.installFfmpeg() }
            }
            if !ytDlpReady {
                _ = await runInstall("The media fetcher") { await ToolManager.shared.installYtDlp() }
            }
            isProcessing = false
            refreshDependencyStatus()
            drainPendingMessages()
        }
    }

    /// Runs one install and logs how it went. A failure's reason can name the
    /// tool — a download URL, a file name — so it stays in Details and the log,
    /// and the status line gets a line of its own.
    private func runInstall(_ what: String, _ install: () async -> Bool) async -> Bool {
        let ok = await install()
        if ok {
            appendLog("\(what) is installed.")
        } else {
            if case .failed(let message) = ToolManager.shared.progress {
                appendLog("Install failed: \(message)")
            }
            appendLog("\(what) could not be installed — see Details for why.")
        }
        return ok
    }

    /// Upgrades yt-dlp with whichever package manager installed it. A months-old
    /// yt-dlp is the usual reason a YouTube item fails with HTTP 403, and the
    /// failure gives no hint that the tool is the problem.
    private func updateYtDlp() {
        // A managed copy updates by re-downloading and re-verifying; only a
        // Homebrew/pipx install needs the shell path.
        if ToolManager.hasManagedYtDlp {
            installYtDlp()
            return
        }
        installStatus = "Updating components…"
        runMaintenanceScript(
            """
            set -e
            export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
            if command -v brew >/dev/null 2>&1 && brew list --versions yt-dlp >/dev/null 2>&1; then
                echo "Updating yt-dlp with Homebrew…"
                brew update || true
                brew upgrade yt-dlp
            elif command -v pipx >/dev/null 2>&1 && pipx list 2>/dev/null | grep -q yt-dlp; then
                echo "Updating yt-dlp with pipx…"
                pipx upgrade yt-dlp
            elif command -v yt-dlp >/dev/null 2>&1 && yt-dlp -U 2>/dev/null; then
                echo "Updated yt-dlp in place."
            else
                echo "Couldn't work out how yt-dlp was installed."
                echo "Update it the way you installed it, for example:"
                echo "  python3 -m pip install -U yt-dlp"
                exit 1
            fi
            yt-dlp --version
            """,
            startMessage: "\nUpdating the component…",
            note: nil,
            successMessage: "Component updated.",
            failureMessage: "Update incomplete (see details).",
            launchFailurePrefix: "Failed to launch the update"
        )
    }

    /// Shared plumbing for the footer's two long-running shell tasks: streams
    /// output into the log, keeps the window in its processing state, and
    /// re-probes the dependencies when it's done.
    private func runMaintenanceScript(
        _ script: String,
        startMessage: String,
        note: String?,
        successMessage: String,
        failureMessage: String,
        launchFailurePrefix: String
    ) {
        isProcessing = true
        appendLog(startMessage)
        if let note { appendLog(note) }

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", script]

            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = outputPipe

            DispatchQueue.main.async { runningProcess = process }

            do {
                try process.run()
                // Read to the end, then flush, as the import pipeline does. A
                // readability handler removed after exit could drop the last
                // output, and decoding each raw chunk split lines — and
                // multi-byte characters — that straddled two reads (#134).
                let lineBuffer = LineBuffer()
                // Set once this task stops waiting for its output. Anything read
                // after that is labelled, so it can't pass for output of whatever
                // runs next.
                let abandoned = OSAllocatedUnfairLock(initialState: false)
                let emit: ([String]) -> Void = { lines in
                    guard !lines.isEmpty else { return }
                    let late = abandoned.withLock { $0 }
                    let shown = late ? lines.map { "[from the stopped task] \($0)" } : lines
                    for line in shown {
                        scriptLog.log("\(line, privacy: .public)")
                        AppLog.shared.log(line)
                    }
                    DispatchQueue.main.async { logEntries.append(contentsOf: shown) }
                }
                let handle = outputPipe.fileHandleForReading
                let drained = DispatchSemaphore(value: 0)
                DispatchQueue.global(qos: .utility).async {
                    while true {
                        let data = handle.availableData
                        if data.isEmpty { break }
                        emit(lineBuffer.take(data))
                    }
                    emit(lineBuffer.flush())
                    drained.signal()
                }

                process.waitUntilExit()
                // A normal exit reaches the end of the output at once. If Stop
                // left a child that ignored the signal holding the pipe open,
                // don't keep the window busy on its account: its remaining
                // output still reaches the log when it does finish.
                if drained.wait(timeout: .now() + 2) == .timedOut {
                    abandoned.withLock { $0 = true }
                }
                let status = process.terminationStatus
                DispatchQueue.main.async {
                    isProcessing = false
                    runningProcess = nil
                    let msg = status == 0 ? successMessage : failureMessage
                    appendLog(msg)
                    scriptLog.log("\(msg, privacy: .public)")
                    refreshDependencyStatus()
                    // Any iMessage URLs that arrived while this ran were queued
                    // because `isProcessing` was true; drain them now.
                    drainPendingMessages()
                }
            } catch {
                DispatchQueue.main.async {
                    isProcessing = false
                    runningProcess = nil
                    appendLog("\(launchFailurePrefix): \(error.localizedDescription)")
                    drainPendingMessages()
                }
            }
        }
    }
}

/// The installed yt-dlp's release string ("2026.03.17"), or nil if it can't be
/// read. Drains the pipe before waiting so a chatty login shell can't deadlock
/// the probe.
private func installedYtDlpVersion() -> String? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/bash")
    task.arguments = ["-lc", "PATH=\"\(pipelinePath)\" yt-dlp --version"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    do { try task.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    guard task.terminationStatus == 0,
          let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
          !text.isEmpty
    else { return nil }
    return text.split(whereSeparator: \.isNewline).last.map(String.init)
}

/// Reassembles whole lines from pipe reads, which arrive as arbitrary byte
/// chunks. Touched only from the single thread that reads the pipe to EOF, so it
/// needs no synchronisation of its own.
private final class LineBuffer {
    /// Emit a fragment as a line rather than buffer past this, so output that
    /// never sends a newline can't grow without bound.
    private static let maxLineBytes = 1 << 20

    private var partial = Data()

    /// Complete lines contained in `data`; a trailing fragment is held back
    /// until the read that completes it.
    ///
    /// Splits on bytes, not on a decoded string: a multibyte character can
    /// straddle two reads, and decoding each chunk on its own would throw the
    /// whole chunk away. A line boundary can never fall inside a character,
    /// because no UTF-8 continuation byte is CR or LF.
    func take(_ data: Data) -> [String] {
        partial.append(data)
        var lines: [String] = []
        var lineStart = partial.startIndex
        var index = partial.startIndex
        while index < partial.endIndex {
            let byte = partial[index]
            // yt-dlp redraws its progress with CR, so treat either terminator as
            // an end of line and drop the empty piece a CRLF pair leaves behind.
            if byte == 0x0A || byte == 0x0D {
                if index > lineStart, let line = String(data: partial[lineStart..<index], encoding: .utf8) {
                    lines.append(line)
                }
                lineStart = partial.index(after: index)
            }
            index = partial.index(after: index)
        }
        partial = Data(partial[lineStart...])
        if partial.count > Self.maxLineBytes {
            if let line = String(data: partial, encoding: .utf8) { lines.append(line) }
            partial = Data()
        }
        return lines
    }

    /// Whatever is left once the process has exited without a final newline.
    func flush() -> [String] {
        defer { partial = Data() }
        guard !partial.isEmpty, let line = String(data: partial, encoding: .utf8) else { return [] }
        return [line]
    }
}

/// A media file's duration in whole seconds, or nil if ffprobe isn't available
/// or can't read it — in which case nothing is claimed and the run decides.
private func mediaDurationSeconds(path: String) -> Int? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/bash")
    let quoted = path.replacingOccurrences(of: "'", with: "'\\''")
    // Quoted: "Application Support" has a space, and unquoted the shell ran
    // "Support/CatchMatch/bin:…" as a command, so this always came back nil and
    // the long-video check never worked for a local file (#80).
    task.arguments = ["-lc", "PATH=\"\(pipelinePath)\" ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 '\(quoted)'"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    do { try task.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    guard task.terminationStatus == 0,
          let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
          let seconds = Double(text), seconds.isFinite, seconds > 0
    else { return nil }
    return Int(seconds)
}

/// The PATH the pipeline and every probe use. A downloaded copy comes first, so
/// it wins when present; Homebrew stays behind it, untouched, for anyone who
/// already had the tools that way.
private var pipelinePath: String {
    ToolManager.managedBinDirectory.path
        + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
}

/// True when `tool` is resolvable on the pipeline's PATH. Mirrors the
/// onboarding check's invocation (login shell + explicit Homebrew PATH) so the
/// main window and the setup window can't disagree about whether a tool exists.
private func toolExists(_ tool: String) -> Bool {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/bash")
    task.arguments = ["-lc", "PATH=\"\(pipelinePath)\" command -v \(tool)"]
    // Discard output to /dev/null rather than a Pipe: waitUntilExit() without
    // draining a pipe can deadlock if a noisy login dotfile fills the buffer.
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    do {
        try task.run()
        task.waitUntilExit()
    } catch { return false }
    return task.terminationStatus == 0
}

/// Hands back the `NSWindow` hosting this view; SwiftUI has no first-class way
/// to ask, and "which window took the file" has to be answerable.
private final class WeakWindow {
    weak var window: NSWindow?
}

extension Notification.Name {
    /// Posted by File ▸ Open File… (⌘O), carrying the key window so only that
    /// window opens a panel. #33
    static let openFilePicker = Notification.Name("catchmatch.openFilePicker")
}

private struct WindowReader: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(nsView.window) }
    }
}

// MARK: - Screenshot mode (#105)

extension ContentView {
    /// Puts the window into one of the fixed marketing states. Only reachable
    /// with `-SCREENSHOT_MODE`; nothing here touches the network or the disk.
    fileprivate func applyScreenshotScene(_ scene: String) {
        // Frontmost, or the window renders inactive — grey title buttons and a
        // washed-out accent — which is not what a marketing shot should show.
        NSApp.activate(ignoringOtherApps: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy.MM.dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        func version(daysOld: Int) -> String {
            formatter.string(from: Date().addingTimeInterval(TimeInterval(-daysOld) * 86_400))
        }
        switch ScreenshotMode.dependencyState {
        case "missing":
            dependenciesReady = false
            ffmpegReady = true
        case "stale":
            dependenciesReady = true
            ytDlpVersion = version(daysOld: 120)   // past the staleness threshold
        case "blocked":
            dependenciesReady = true
            ytDlpVersion = version(daysOld: 7)
            // ytDlpBlocked is derived; this is the input it derives from.
            solverFailureSeen = true
        default:
            dependenciesReady = true
            // A week old whenever the capture runs, so the staleness warning
            // never ends up in a marketing shot.
            ytDlpVersion = version(daysOld: 7)
        }
        // Deliberately no writes to the @AppStorage-backed destination defaults:
        // those persist, and a capture run would rewrite the real user's
        // settings. ScreenshotTests passes them as launch arguments instead,
        // which live in the argument domain for that launch only.
        let inputs = ScreenshotMode.demoInputs
        func item(_ i: Int, _ status: ItemStatus,
                  audio: Bool = true, video: Bool = false, tv: Bool = false) -> InputItem {
            var it = InputItem(raw: inputs[i], toMusicAudio: audio, toMusicVideo: video, toTV: tv)
            it.status = status
            return it
        }
        switch scene {
        case "empty":
            items = []
            logEntries = ["Ready"]
        case "imported":
            items = [
                item(0, .done), item(1, .done, video: true, tv: true),
                item(2, .done), item(3, .done),
            ]
            logEntries = [
                "=== Processing: \(inputs[0]) ===",
                "[download] Destination: Village Hall Sessions 1974.m4a",
                "[ExtractAudio] Keeping the original AAC stream (no re-encode)",
                "→ Music (audio): Village Hall Sessions 1974.m4a",
                "=== Processing: Garden Gig — June 2026.mov ===",
                "→ Music (video): Garden Gig — June 2026.mp4",
                "→ TV: Garden Gig — June 2026.mp4",
                "=== Processing: \(inputs[3]) ===",
                "→ Music (audio): Winter Rehearsals.m4a",
                "Done: 4 items imported",
            ]
        default: // "queue": mid-run
            items = [
                item(0, .done), item(1, .done, video: true, tv: true),
                item(2, .running), item(3, .queued, audio: false, video: true, tv: true),
            ]
            isProcessing = true
            currentItemRaw = inputs[2]
            logEntries = ["Importing 3 of 4: Listening to Rooms (lecture)"]
        }
    }
}

/// One queued input: a web URL or a local file path, already normalized by
/// `normalizedInput`. Modelled as a row instead of a line of editable text so
/// the queue always holds something the pipeline can actually take.
/// How far one queued item got in the last run.
enum ItemStatus: Equatable {
    case queued, running, done, failed, skipped
}

struct InputItem: Identifiable, Equatable {
    let id = UUID()
    let raw: String
    var status: ItemStatus = .queued
    /// Where this specific item goes. Seeded from the row of chips above the
    /// queue (which act as the default for anything newly added) and then
    /// overridable per item — a movie and a music video usually don't belong in
    /// the same library.
    var toMusicAudio: Bool
    var toMusicVideo: Bool
    var toTV: Bool
    /// The video to ~/Downloads.
    var toDownloads: Bool = false
    /// The song to ~/Downloads (#164).
    var toDownloadsAudio: Bool = false
    /// Set when the destinations came from what this kind of input usually
    /// gets rather than from the chips; cleared once they are edited (#166).
    var predictedFrom: DestinationPredictor.InputKind? = nil
    /// Set once someone has accepted an AI-cleaned name for this item. Carried
    /// through to the run so the file is tagged and named with it.
    var cleanedArtist: String?
    var cleanedTitle: String?
    var isCompilation: Bool = false
    var isCleaning: Bool = false
    /// Filled in asynchronously for local files by an ffprobe read. nil while
    /// unknown, and for links — a URL's length isn't knowable without fetching.
    var durationSeconds: Int?
    /// File names of this item's copies in ~/Downloads, from the script's
    /// "→ Downloads:" lines.
    var downloadedFiles: [String] = []

    /// The copies still in ~/Downloads, for the row's Show in Finder button.
    var downloadedURLs: [URL] {
        guard let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        else { return [] }
        return downloadedFiles.map { folder.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    var isFile: Bool { !raw.lowercased().hasPrefix("http") }
    var display: String {
        if let cleanedTitle {
            return cleanedArtist.map { "\($0) — \(cleanedTitle)" } ?? cleanedTitle
        }
        return isFile ? (raw as NSString).lastPathComponent : raw
    }

    /// What the cleaner is given: the filename for a local file, the URL
    /// otherwise — all the app knows before the run fetches anything.
    var cleanableName: String {
        isFile ? ((raw as NSString).lastPathComponent as NSString).deletingPathExtension : raw
    }
    var symbol: String { isFile ? "film" : "link" }
    var hasDestination: Bool { toMusicAudio || toMusicVideo || toTV || toDownloads || toDownloadsAudio }
    var destination: Destination {
        Destination(musicAudio: toMusicAudio, musicVideo: toMusicVideo, tv: toTV,
                    downloads: toDownloads, downloadsAudio: toDownloadsAudio)
    }

    /// Long enough that its audio track is a film, not a song. The script keeps
    /// anything past this out of the Music library; the row says so first.
    var isLongForm: Bool { (durationSeconds ?? 0) > 20 * 60 }

    var durationText: String? {
        guard let durationSeconds else { return nil }
        return "\(durationSeconds / 60) min"
    }
    /// Still to do on the next run. An imported item stays in the queue as a
    /// record of what happened, but re-importing it would just duplicate it.
    var isPending: Bool { hasDestination && status != .done }

    var statusHelp: String {
        switch status {
        case .queued: return hasDestination ? "Waiting to be imported" : "No destination — will be skipped"
        case .running: return "Importing…"
        case .done: return "Imported — will be skipped on the next run"
        case .failed: return "Failed — open Show Details for the reason"
        case .skipped: return "Skipped: no destination was selected"
        }
    }
}

/// One combination of destinations. The script takes a single set per run, so a
/// queue with mixed destinations is grouped by this and run in turn.
struct Destination: Hashable {
    let musicAudio: Bool
    let musicVideo: Bool
    let tv: Bool
    /// ~/Downloads: the processed file, for people who don't keep a Music
    /// library — or who just want the file to hand somewhere else (#111).
    /// `downloads` is the video, `downloadsAudio` the song (#164).
    var downloads: Bool = false
    var downloadsAudio: Bool = false

    var isEmpty: Bool { !musicAudio && !musicVideo && !tv && !downloads && !downloadsAudio }

    /// Flags for `dlp2music.sh`. `--music` still means both halves, so it's used
    /// when both are wanted and the split flags otherwise.
    var scriptFlags: [String] {
        var flags: [String] = []
        if musicAudio && musicVideo {
            flags.append("--music")
        } else {
            if musicAudio { flags.append("--music-audio") }
            if musicVideo { flags.append("--music-video") }
        }
        if tv { flags.append("--tv") }
        if downloadsAudio { flags.append("--downloads-audio") }
        if downloads { flags.append("--downloads-video") }
        return flags
    }
}

private struct QueuedBatch {
    let urls: [String]
    let destination: Destination
    var titleOverride: String? = nil
    var artistOverride: String? = nil
}

/// A destination toggle rendered as a tinted capsule instead of a bare
/// checkbox — the two destinations are the primary choice in the window, so
/// they get more visual weight than a checkbox row gives them.
private struct DestinationChip: View {
    let title: String
    /// Shown instead of `title` in the compact row variant, where two chips
    /// reading "Apple Music" side by side would be ambiguous.
    var shortTitle: String? = nil
    let symbol: String
    @Binding var isOn: Bool
    var compact: Bool = false
    /// Distinguishes the window's default chips from a row's own, which carry
    /// the same labels and would otherwise be indistinguishable to VoiceOver
    /// and to the UI tests (#109).
    var identifier: String? = nil

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(compact ? (shortTitle ?? title) : title)
            }
            .font(compact ? .caption : .callout)
            .padding(.horizontal, compact ? 8 : 12)
            .padding(.vertical, compact ? 3 : 6)
            .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
            .background(
                Capsule().fill(isOn ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08))
            )
            .overlay(
                Capsule().strokeBorder(isOn ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.25))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier ?? title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
        .help(isOn ? "Importing to \(title)" : "Not importing to \(title)")
    }
}

/// Public home of the legal documents: the repo is private, so customers
/// can't read legal/*.md on GitHub. The pages on michelstorms.com are rendered
/// from those files. `page` is terms, privacy or refunds.
private func legalURL(_ page: String) -> URL {
    URL(string: "https://michelstorms.com/catchmatch/\(page)/")!
}

private struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("About \(Constants.appName)")
                .font(.title2).bold()
            // The store it's sold from; a store name, not the seller — the legal
            // documents still name Michel Storms (#146).
            // Not in a Setapp copy: it would send a subscriber to a store that
            // sells them what they already have (#107).
            if Constants.isSetappBuild {
                Color.clear.frame(height: 14)
            } else {
                HStack(spacing: 4) {
                    Text("An Orchard Outlaws app ·")
                    Link("orchardoutlaws.com", destination: URL(string: "https://orchardoutlaws.com")!)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
                .padding(.bottom, 14)
            }

            // The body has to scroll: in a fixed-height sheet SwiftUI compresses
            // these paragraphs to a single truncated line each rather than
            // letting them wrap.
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Group {
                        Text("Credits & Licenses").font(.headline)
                        Text("\(Constants.appName) converts and imports; the heavy lifting is done by two open-source tools:")
                        Text("• yt-dlp — downloads media. Licensed under the Unlicense / public domain.\n   https://github.com/yt-dlp/yt-dlp")
                        Text("• FFmpeg — transcodes media. \(Constants.appName) installs its own build of FFmpeg 9.0.2 with dav1d, licensed under the LGPL-2.1 (dav1d: BSD-2-Clause) and built without any GPL or non-free parts. Its source code and build details:\n   https://michelstorms.com/catchmatch/tools/catchmatch-ffmpeg-9.0.2-macos-universal-source.zip\n   https://ffmpeg.org/legal.html")
                        Text("Both tools are downloaded to ~/Library/Application Support/CatchMatch when you click Install, not bundled with this app. FFmpeg's licence texts are kept beside it in CatchMatch/licenses/ffmpeg.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    Divider()

                    Group {
                        Text("Legal").font(.headline)
                        Text("This app is intended for personal use. You are solely responsible for ensuring you have the right to convert any content you process with it. Processing material you have no right to may infringe copyright or breach a source site's terms of service, and is not what this app is for. The developer assumes no liability.")
                            .font(.callout)
                        HStack(spacing: 14) {
                            // Free and open source since #169: no EULA or refunds.
                            Link("MIT License", destination: URL(string: "https://github.com/stormychel/CatchMatch/blob/main/LICENSE")!)
                            Link("Privacy", destination: legalURL("privacy"))
                            Link("Buy me a coffee", destination: Constants.buyMeACoffeeURL)
                        }
                        .font(.caption)
                    }

                    Divider()

                    Group {
                        Text("Playback without Apple Music / iTunes Match").font(.headline)
                        Text("If you don\u{2019}t use Apple Music or iTunes Match, VLC is a free, open-source player that handles every format \(Constants.appName) produces. https://www.videolan.org/vlc/")
                            .font(.callout)
                    }

                    Divider()

                    Group {
                        Text("Privacy — iMessage chat watcher").font(.headline)
                        Text("If you enable the optional iMessage drop-chat feature, \(Constants.appName) reads the Messages database in read-only mode and only queries the single chat you select. Nothing about your conversations leaves your Mac. The feature requires Full Disk Access, which you grant explicitly in System Settings.")
                            .font(.callout)
                    }
                }
                // Let every paragraph take the height it needs instead of being
                // squeezed onto one line.
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 6)
            }

            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.top, 14)
        }
        .padding(20)
        .frame(width: 560, height: 520)
    }
}

#Preview {
    ContentView(iMessageWatcher: IMessageWatcher())
}

/// The Dock badge: the ready count of every open window's queue, added up.
@MainActor
enum DockBadge {
    private static var counts: [UUID: Int] = [:]

    static func set(_ count: Int, for window: UUID) {
        counts[window] = count
        update()
    }

    static func remove(_ window: UUID) {
        counts[window] = nil
        update()
    }

    private static func update() {
        let total = counts.values.reduce(0, +)
        NSApp.dockTile.badgeLabel = total > 0 ? "\(total)" : nil
    }
}
