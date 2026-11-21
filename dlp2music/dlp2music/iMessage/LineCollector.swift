//
//  LineCollector.swift
//  dlp2music
//
//  Created by Michel Storms on 26/05/2026.
//

import Foundation

/// Thread-safe accumulator for script-output lines. The pipe's `readabilityHandler`
/// fires on an arbitrary queue, so appends must be serialized.
final class LineCollector {
    private let queue = DispatchQueue(label: "dlp2music.line-collector")
    private var lines: [String] = []

    func append(_ newLines: [String]) {
        queue.sync { lines.append(contentsOf: newLines) }
    }

    func snapshot() -> [String] {
        queue.sync { lines }
    }
}
