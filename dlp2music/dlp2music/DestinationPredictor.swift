//
//  DestinationPredictor.swift
//  dlp2music
//
//  Created by Michel Storms on 02/11/2026.
//

import Foundation

/// Learns which destinations each kind of input usually goes to, so a new item
/// starts on that instead of on whatever the chips were last left at (#166).
///
/// Counts are per kind because the habits differ: YouTube links tend to be
/// music, other sites tend to be clips for Downloads or TV, local files tend to
/// be films. Only finished imports are counted, so a combination tried and then
/// changed before the run doesn't teach anything.
struct DestinationPredictor {
    enum InputKind: String, CaseIterable {
        case youtube, web, file

        init(raw: String) {
            let lower = raw.lowercased()
            guard lower.hasPrefix("http") else { self = .file; return }
            let host = URL(string: raw)?.host?.lowercased() ?? ""
            let youtubeHosts = ["youtube.com", "youtu.be", "youtube-nocookie.com"]
            self = youtubeHosts.contains { host == $0 || host.hasSuffix("." + $0) } ? .youtube : .web
        }

        /// For the row's hint: "what you usually choose for …".
        var phrase: String {
            switch self {
            case .youtube: return "YouTube links"
            case .web: return "links from other sites"
            case .file: return "files"
            }
        }
    }

    /// Imports of a kind needed before a prediction is made. One or two could
    /// just as well be a one-off.
    static let minimumImports = 3

    static let defaultsKey = "destinationUsageCounts"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// kind → combination key → imports.
    private var counts: [String: [String: Int]] {
        // Entry by entry, so one unreadable value can't make the whole history
        // look empty and be overwritten by the next record.
        get {
            let stored = defaults.dictionary(forKey: Self.defaultsKey) ?? [:]
            return stored.compactMapValues { ($0 as? [String: Any])?.compactMapValues { $0 as? Int } }
        }
        nonmutating set { defaults.set(newValue, forKey: Self.defaultsKey) }
    }

    func record(_ destination: Destination, for kind: InputKind) {
        guard !destination.isEmpty else { return }
        var all = counts
        all[kind.rawValue, default: [:]][Self.key(for: destination), default: 0] += 1
        counts = all
    }

    /// The most-used combination for `kind`, or nil while there is too little
    /// to go on. A tie goes to `tieBreaker` when it is one of the leaders, so
    /// the chips the person is looking at win an even split.
    func prediction(for kind: InputKind, tieBreaker: Destination? = nil) -> Destination? {
        guard let byCombo = counts[kind.rawValue],
              byCombo.values.reduce(0, +) >= Self.minimumImports,
              let top = byCombo.values.max() else { return nil }
        let leaders = byCombo.filter { $0.value == top }.map(\.key).sorted()
        if let tieBreaker, leaders.contains(Self.key(for: tieBreaker)) { return tieBreaker }
        return leaders.first.flatMap(Self.destination(for:))
    }

    /// Five flags in a fixed order: song, music video, TV, video to Downloads,
    /// audio to Downloads.
    static func key(for d: Destination) -> String {
        [d.musicAudio, d.musicVideo, d.tv, d.downloads, d.downloadsAudio]
            .map { $0 ? "1" : "0" }.joined()
    }

    static func destination(for key: String) -> Destination? {
        let flags = key.map { $0 == "1" }
        guard flags.count == 5 else { return nil }
        return Destination(musicAudio: flags[0], musicVideo: flags[1], tv: flags[2],
                           downloads: flags[3], downloadsAudio: flags[4])
    }
}
