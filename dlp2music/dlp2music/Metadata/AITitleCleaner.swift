//
//  AITitleCleaner.swift
//  dlp2music
//
//  Created by Michel Storms on 30/08/2026.
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Pulls an artist and a title out of a name that defeats the regex pass.
///
/// The pipeline's cleanup is a set of substitutions: strip "(Official Video)",
/// split on a dash, guess which side is the artist. That covers the common shape
/// and nothing else — a `Topic` channel where the uploader *is* the artist, a
/// reversed `Song - Artist`, a non-English or transliterated title, marketing
/// prose wrapped around the actual name, or a compilation that shouldn't be
/// imported as one track. Those need reading comprehension, not more regexes.
///
/// Runs entirely on-device through Apple's Foundation Models, so nothing about
/// what the user is importing leaves the machine. Unavailable on older systems
/// or where Apple Intelligence is off, in which case the caller keeps whatever
/// the regex pass produced.
enum AITitleCleaner {

    struct Result: Equatable {
        let artist: String
        let title: String
        let featuring: [String]
        /// The model's own estimate, 0–1. Below `minimumConfidence` the caller
        /// should keep what it had rather than trust this.
        let confidence: Double
        /// A mix or compilation, which is one file but many tracks — worth
        /// flagging rather than filing as a single song.
        let isCompilation: Bool
    }

    static let minimumConfidence = 0.6

    enum Availability: Equatable {
        case available
        case unsupportedOS
        case unavailable(String)

        var isAvailable: Bool { self == .available }
    }

    static var availability: Availability {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { return .unsupportedOS }
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(.deviceNotEligible):
            return .unavailable("This Mac doesn't support Apple Intelligence.")
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable("Turn on Apple Intelligence in System Settings to use this.")
        case .unavailable(.modelNotReady):
            return .unavailable("The on-device model is still downloading.")
        case .unavailable:
            return .unavailable("The on-device model isn't available right now.")
        }
        #else
        return .unsupportedOS
        #endif
    }

    /// - Parameters:
    ///   - rawTitle: the title as the source gave it, or a bare filename.
    ///   - uploader: channel or uploader, when known — often the artist itself.
    static func clean(rawTitle: String, uploader: String?) async -> Result? {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *), availability.isAvailable else { return nil }

        let instructions = """
        You extract music metadata from the messy names videos are published under.

        Return the performing artist and the track title, nothing else. Rules:
        - The uploader is often the artist itself, especially for "… - Topic" \
        channels; use it when the title alone doesn't name one.
        - The order around a dash is not reliable. Decide which side is the \
        artist from what the words actually are.
        - Drop marketing language, emoji, and tags like "FULL VERSION", "HD", \
        "Official Video", "Lyrics", "4K".
        - Keep the title in its original language and script. Do not translate \
        or transliterate.
        - Put featured performers in `featuring`, not in the title.
        - Set isCompilation for a mix, megamix, full album or DJ set — one file \
        holding many tracks.
        - confidence is your own estimate that this is right. Be honest: a name \
        you cannot really parse should score low.
        """

        do {
            let session = LanguageModelSession(instructions: instructions)
            let prompt = """
            Title: \(rawTitle)
            Uploader: \(uploader ?? "(unknown)")
            """
            let response = try await session.respond(to: prompt, generating: CleanedTitle.self)
            let value = response.content
            let artist = value.artist.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = value.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return Result(
                artist: artist,
                title: title,
                featuring: value.featuring ?? [],
                confidence: min(max(value.confidence, 0), 1),
                isCompilation: value.isCompilation
            )
        } catch {
            // A refusal, a timeout or an unparseable answer all mean the same
            // thing here: keep what the regex pass produced.
            return nil
        }
        #else
        return nil
        #endif
    }
}

#if canImport(FoundationModels)
@available(macOS 26, *)
@Generable
struct CleanedTitle {
    @Guide(description: "The performing artist, as it should appear in a music library.")
    var artist: String

    @Guide(description: "The track title alone, without the artist, and without marketing text or format tags.")
    var title: String

    @Guide(description: "Featured performers, if the name mentions any.")
    var featuring: [String]?

    @Guide(description: "How confident you are that this parse is correct, from 0 to 1.")
    var confidence: Double

    @Guide(description: "True when this is a mix, DJ set, megamix or full album rather than a single track.")
    var isCompilation: Bool
}
#endif
