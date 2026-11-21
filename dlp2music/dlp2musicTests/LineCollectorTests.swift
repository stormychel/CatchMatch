//
//  LineCollectorTests.swift
//  dlp2musicTests
//
//  Created by Michel Storms on 21/09/2026.
//

import Testing
import Foundation
@testable import dlp2music

/// The pipe's readabilityHandler fires on an arbitrary queue, so the collector
/// has to survive appends from several at once without losing or tearing a line. #109
struct LineCollectorTests {

    @Test func keepsOrderWithinOneAppend() {
        let c = LineCollector()
        c.append(["first", "second", "third"])
        #expect(c.snapshot() == ["first", "second", "third"])
    }

    @Test func startsEmpty() {
        #expect(LineCollector().snapshot().isEmpty)
    }

    @Test func snapshotDoesNotConsume() {
        let c = LineCollector()
        c.append(["only"])
        #expect(c.snapshot() == ["only"])
        #expect(c.snapshot() == ["only"])
    }

    @Test func concurrentAppendsLoseNothing() async {
        let c = LineCollector()
        await withTaskGroup(of: Void.self) { group in
            for batch in 0..<20 {
                group.addTask { c.append((0..<50).map { "batch\(batch)-line\($0)" }) }
            }
        }
        let lines = c.snapshot()
        #expect(lines.count == 1000)
        #expect(Set(lines).count == 1000)
    }
}
