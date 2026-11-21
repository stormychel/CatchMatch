//
//  DestinationPredictorTests.swift
//  dlp2musicTests
//
//  Created by Michel Storms on 02/11/2026.
//

import Testing
import Foundation
@testable import dlp2music

/// New items start on what their kind of input usually gets (#166).
final class DestinationPredictorTests {
    private let song = Destination(musicAudio: true, musicVideo: false, tv: false)
    private let downloadsVideo = Destination(musicAudio: false, musicVideo: false, tv: false, downloads: true)

    private let suite = "catchmatch.tests.\(UUID().uuidString)"

    /// Each test gets its own suite; leave nothing behind on disk.
    deinit { UserDefaults().removePersistentDomain(forName: suite) }

    private func predictor() -> DestinationPredictor {
        DestinationPredictor(defaults: UserDefaults(suiteName: suite)!)
    }

    @Test func kindsAreToldApart() {
        #expect(DestinationPredictor.InputKind(raw: "https://www.youtube.com/watch?v=x") == .youtube)
        #expect(DestinationPredictor.InputKind(raw: "https://youtu.be/x") == .youtube)
        #expect(DestinationPredictor.InputKind(raw: "https://music.youtube.com/watch?v=x") == .youtube)
        #expect(DestinationPredictor.InputKind(raw: "https://vimeo.com/1") == .web)
        #expect(DestinationPredictor.InputKind(raw: "https://notyoutube.com/x") == .web)
        #expect(DestinationPredictor.InputKind(raw: "/Users/me/Movies/film.mov") == .file)
    }

    @Test func noPredictionUntilThereIsEnoughToGoOn() {
        let p = predictor()
        for _ in 1..<DestinationPredictor.minimumImports { p.record(song, for: .youtube) }
        #expect(p.prediction(for: .youtube) == nil)
        p.record(song, for: .youtube)
        #expect(p.prediction(for: .youtube) == song)
    }

    @Test func theMostUsedCombinationWins() {
        let p = predictor()
        for _ in 0..<3 { p.record(song, for: .youtube) }
        p.record(downloadsVideo, for: .youtube)
        #expect(p.prediction(for: .youtube) == song)
    }

    @Test func kindsAreCountedSeparately() {
        let p = predictor()
        for _ in 0..<3 { p.record(song, for: .youtube) }
        for _ in 0..<3 { p.record(downloadsVideo, for: .web) }
        #expect(p.prediction(for: .youtube) == song)
        #expect(p.prediction(for: .web) == downloadsVideo)
        #expect(p.prediction(for: .file) == nil)
    }

    @Test func aTieGoesToTheChips() {
        let p = predictor()
        for _ in 0..<2 { p.record(song, for: .web); p.record(downloadsVideo, for: .web) }
        #expect(p.prediction(for: .web, tieBreaker: downloadsVideo) == downloadsVideo)
        #expect(p.prediction(for: .web, tieBreaker: song) == song)
    }

    /// One bad entry mustn't wipe the rest of the history.
    @Test func anUnreadableEntryIsSkipped() {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(["youtube": ["10000": 3, "junk": "x"], "web": "nonsense"],
                     forKey: DestinationPredictor.defaultsKey)
        #expect(DestinationPredictor(defaults: defaults).prediction(for: .youtube) == song)
    }

    @Test func everyCombinationRoundTrips() {
        let d = Destination(musicAudio: true, musicVideo: false, tv: true, downloads: false, downloadsAudio: true)
        #expect(DestinationPredictor.destination(for: DestinationPredictor.key(for: d)) == d)
    }
}
