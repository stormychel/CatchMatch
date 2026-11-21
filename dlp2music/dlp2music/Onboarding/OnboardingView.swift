//
//  OnboardingView.swift
//  dlp2music
//
//  Created by Michel Storms on 10/05/2026.
//

import SwiftUI
import AppKit

struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [OnboardingRow] = OnboardingChecks.all().map { OnboardingRow(check: $0) }
    @State private var isRunning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Welcome to CatchMatch").font(.title2).bold()
            Text("Quick setup check. You can re-run this any time from the Help menu.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach($rows) { $row in
                        OnboardingRowView(row: $row, isCurrent: row.id == currentRowID,
                                          showsGateControls: gateControlRowIDs.contains(row.id), onFixTapped: { rowID in
                            // Runs once the fix has finished (an install is
                            // awaited). A fix that opens System Settings returns
                            // at once, so give TCC ~1s to refresh before
                            // re-running just that check, and the row flips to
                            // green without clicking "Re-run checks".
                            Task { await rerunCheck(id: rowID, after: 1.0) }
                        }, onGateOpened: { key in
                            Task { await runGated(key: key) }
                        })
                    }
                }
            }

            Divider()

            HStack {
                Button(action: runAll) {
                    if isRunning {
                        ProgressView().controlSize(.small).padding(.trailing, 4)
                        Text("Checking…")
                    } else {
                        Text("Re-run checks")
                    }
                }
                .disabled(isRunning)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540, height: 540)
        .task { await runAllAsync() }
        // BlueSender-FE pattern: when the user grants a permission in System
        // Settings and cmd-tabs back, the app becomes active again — re-run
        // all checks so the row flips to green without requiring another
        // click. Cheap (each check is a quick filesystem probe) and covers
        // the common Full Disk Access and Music auto-add flows
        // in one place.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await runAllAsync() }
        }
    }

    /// The row to act on next: the one being checked, else the first that
    /// still needs something. Shown larger so it stands out in the list (#147).
    private var currentRowID: String? {
        if let running = rows.first(where: { $0.status == .running }) { return running.id }
        return rows.first(where: {
            switch $0.status {
            case .fail, .gated: return true
            default: return false
            }
        })?.id
    }

    /// One row per gate carries the explanation and the button; the others
    /// sharing it point up to that row instead of repeating it.
    private var gateControlRowIDs: Set<String> {
        var seen = Set<String>()
        var ids = Set<String>()
        for row in rows {
            guard case .gated = row.status, let key = row.check.gate?.key else { continue }
            if seen.insert(key).inserted { ids.insert(row.id) }
        }
        return ids
    }

    private func runAll() {
        Task { await runAllAsync() }
    }

    private func runAllAsync() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        for index in rows.indices {
            if let gate = rows[index].check.gate, !gate.isOpen {
                rows[index].status = .gated
                continue
            }
            rows[index].status = .running
            let result = await rows[index].check.runner()
            rows[index].status = result
        }
    }

    /// Runs every row behind the gate just opened. The first probe is what makes
    /// macOS show its prompt, now that the row has said why.
    private func runGated(key: String) async {
        for index in rows.indices where rows[index].check.gate?.key == key {
            rows[index].status = .running
            let result = await rows[index].check.runner()
            rows[index].status = result
        }
    }

    private func rerunCheck(id: String, after delay: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].status = .running
        let result = await rows[index].check.runner()
        rows[index].status = result
    }
}

private struct OnboardingRow: Identifiable {
    let check: OnboardingCheck
    var status: OnboardingStatus = .unknown
    var id: String { check.id }
}

private struct OnboardingRowView: View {
    @Binding var row: OnboardingRow
    let isCurrent: Bool
    let showsGateControls: Bool
    let onFixTapped: (String) -> Void
    let onGateOpened: (String) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            statusIcon
                .frame(width: 18, alignment: .center)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.check.title).font(isCurrent ? .title3.bold() : .headline)
                Text(row.check.detail).font(isCurrent ? .callout : .caption).foregroundStyle(.secondary)
                detailLine
                if case .gated = row.status, let gate = row.check.gate, !showsGateControls {
                    Text("Checked when you press \u{201C}\(gate.buttonLabel)\u{201D} above.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if case .gated = row.status, let gate = row.check.gate {
                    Text(gate.explanation)
                        .font(isCurrent ? .callout : .caption)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(gate.buttonLabel) {
                        gate.open()
                        onGateOpened(gate.key)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(.top, 2)
                }
                if case .fail = row.status, let fix = row.check.fix {
                    Button(fix.label) {
                        // Before the Task, so the button is gone by the next click.
                        row.status = .running
                        Task {
                            await fix.action()
                            onFixTapped(row.id)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 2)
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch row.status {
        case .unknown:
            Image(systemName: "circle").foregroundStyle(.secondary)
        case .running:
            ProgressView().controlSize(.small)
        case .pass:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .fail:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .gated:
            Image(systemName: "hand.raised.circle").foregroundStyle(.blue)
        }
    }

    @ViewBuilder
    private var detailLine: some View {
        switch row.status {
        case .pass(let info?):
            Text(info).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
        case .fail(let message):
            Text(message).font(isCurrent ? .callout : .caption).foregroundStyle(.primary)
        default:
            EmptyView()
        }
    }
}

#Preview {
    OnboardingView()
}
