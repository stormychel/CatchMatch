//
//  StopTests.swift
//  dlp2musicTests
//
//  Created by Michel Storms on 21/09/2026.
//

import Testing
import Foundation
@testable import dlp2music

/// Stop has to reach every process a run started. Signalling only bash left its
/// children holding the output pipe, and the window waited on them. #134
@MainActor
struct StopTests {

    /// yt-dlp starts its own ffmpeg, so a grandchild must be found as well as a
    /// child — which is exactly what `pgrep -P` alone would miss. The inner bash
    /// is given a second command: with only one, bash execs straight into
    /// `sleep` and there is no grandchild to find.
    @Test func findsGrandchildrenToo() throws {
        let root = Process()
        root.executableURL = URL(fileURLWithPath: "/bin/bash")
        root.arguments = ["-c", "bash -c 'sleep 30; true' & wait"]
        try root.run()
        defer {
            for pid in ContentView.descendants(of: root.processIdentifier) { kill(pid, SIGKILL) }
            root.terminate()
            root.waitUntilExit()
        }

        var tree: [pid_t] = []
        for _ in 0..<50 {                       // let the children start
            tree = ContentView.descendants(of: root.processIdentifier)
            if tree.count >= 2 { break }
            usleep(100_000)
        }
        #expect(tree.count == 2, "the inner bash and its sleep")
    }

    /// Deepest first: signalling a parent before its child can leave the child
    /// re-parented and out of reach.
    @Test func listsTheDeepestFirst() throws {
        let root = Process()
        root.executableURL = URL(fileURLWithPath: "/bin/bash")
        root.arguments = ["-c", "bash -c 'sleep 30; true' & wait"]
        try root.run()
        defer {
            for pid in ContentView.descendants(of: root.processIdentifier) { kill(pid, SIGKILL) }
            root.terminate()
            root.waitUntilExit()
        }

        var tree: [pid_t] = []
        for _ in 0..<50 {
            tree = ContentView.descendants(of: root.processIdentifier)
            if tree.count >= 2 { break }
            usleep(100_000)
        }
        try #require(tree.count == 2)
        // The child (inner bash) is listed after its own child (sleep).
        let innerBash = ContentView.descendants(of: root.processIdentifier).last
        #expect(ContentView.descendants(of: innerBash ?? 0).first == tree.first)
    }
}
