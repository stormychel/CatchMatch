//
//  URLExtractor.swift
//  dlp2music
//
//  Created by Michel Storms on 26/05/2026.
//

import Foundation

/// Extracts http(s) URLs from iMessage `text` and `attributedBody`. The attributedBody
/// is a `typedstream` (NSArchiver) binary blob, but URLs are stored as plain UTF-8
/// substrings inside it, so a regex scan over the raw bytes recovers them without
/// having to parse the archive format.
enum URLExtractor {

    static let pattern = #"https?://[^\s"<>\p{Cc}]+"#

    private static let regex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: [])
    }()

    static func urls(in text: String) -> [String] {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        let matches = regex.matches(in: text, options: [], range: range)
        return matches.map { ns.substring(with: $0.range) }.map(trimTrailingPunctuation)
    }

    static func urls(inAttributedBodyBytes data: Data) -> [String] {
        // Decode bytes as UTF-8 best-effort; non-UTF-8 byte sequences in the archiver
        // wrapper become replacement chars which the regex skips over harmlessly.
        guard let s = String(data: data, encoding: .utf8) ??
                String(data: data, encoding: .isoLatin1) else { return [] }
        return urls(in: s)
    }

    /// URL chars often include trailing punctuation that's actually message punctuation
    /// (`https://x.com,`). Trim a small set of common offenders.
    private static func trimTrailingPunctuation(_ s: String) -> String {
        var out = s
        let trailing: Set<Character> = [",", ".", ";", ":", ")", "]", "}", "!", "?", "\"", "'"]
        while let last = out.last, trailing.contains(last) {
            out.removeLast()
        }
        return out
    }
}
