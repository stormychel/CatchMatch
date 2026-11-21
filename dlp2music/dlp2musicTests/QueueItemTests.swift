//
//  QueueItemTests.swift
//  dlp2musicTests
//
//  Created by Michel Storms on 21/09/2026.
//

import Testing
import Foundation
@testable import dlp2music

/// The queue decides what each item is for and which flags the script is given.
/// Getting a flag wrong here means a file lands in the wrong library. #109
struct QueueItemTests {

    private func item(audio: Bool = false, video: Bool = false, tv: Bool = false,
                      downloads: Bool = false,
                      status: ItemStatus = .queued,
                      raw: String = "https://example.test/x") -> InputItem {
        var i = InputItem(raw: raw, toMusicAudio: audio, toMusicVideo: video,
                          toTV: tv, toDownloads: downloads)
        i.status = status
        return i
    }

    // MARK: - Script flags

    @Test func songOnly() {
        #expect(Destination(musicAudio: true, musicVideo: false, tv: false).scriptFlags == ["--music-audio"])
    }

    @Test func musicVideoOnly() {
        #expect(Destination(musicAudio: false, musicVideo: true, tv: false).scriptFlags == ["--music-video"])
    }

    @Test func appleTVOnly() {
        #expect(Destination(musicAudio: false, musicVideo: false, tv: true).scriptFlags == ["--tv"])
    }

    /// Both halves of Apple Music collapse to `--music`, which is what the
    /// script's own default means.
    @Test func bothMusicHalvesCollapseToOneFlag() {
        #expect(Destination(musicAudio: true, musicVideo: true, tv: false).scriptFlags == ["--music"])
    }

    @Test func everythingAtOnce() {
        #expect(Destination(musicAudio: true, musicVideo: true, tv: true).scriptFlags == ["--music", "--tv"])
    }

    @Test func songAndTV() {
        #expect(Destination(musicAudio: true, musicVideo: false, tv: true).scriptFlags == ["--music-audio", "--tv"])
    }

    @Test func musicVideoAndTV() {
        #expect(Destination(musicAudio: false, musicVideo: true, tv: true).scriptFlags == ["--music-video", "--tv"])
    }

    // MARK: - Downloads (#111)

    @Test func downloadsOnly() {
        let d = Destination(musicAudio: false, musicVideo: false, tv: false, downloads: true)
        #expect(d.scriptFlags == ["--downloads-video"])
        #expect(!d.isEmpty)
    }

    @Test func downloadsAlongsideASong() {
        let d = Destination(musicAudio: true, musicVideo: false, tv: false, downloads: true)
        #expect(d.scriptFlags == ["--music-audio", "--downloads-video"])
    }

    @Test func downloadsWithEverythingElse() {
        let d = Destination(musicAudio: true, musicVideo: true, tv: true, downloads: true)
        #expect(d.scriptFlags == ["--music", "--tv", "--downloads-video"])
    }

    /// The song can go to Downloads without going to Music (#164).
    @Test func audioToDownloadsAlone() {
        let d = Destination(musicAudio: false, musicVideo: false, tv: false, downloadsAudio: true)
        #expect(d.scriptFlags == ["--downloads-audio"])
        #expect(!d.isEmpty)
    }

    @Test func bothToDownloads() {
        let d = Destination(musicAudio: false, musicVideo: false, tv: false,
                            downloads: true, downloadsAudio: true)
        #expect(d.scriptFlags == ["--downloads-audio", "--downloads-video"])
    }

    /// Downloads is a destination in its own right: an item with only Downloads
    /// on is something to import, not an item with nothing chosen.
    @Test func anItemForDownloadsAloneIsPending() {
        let i = item(downloads: true)
        #expect(i.hasDestination)
        #expect(i.isPending)
    }

    /// Two items differing only in Downloads must not be merged into one run,
    /// or one of them goes to the wrong place.
    @Test func downloadsSeparatesOtherwiseEqualDestinations() {
        let withDownloads = Destination(musicAudio: true, musicVideo: false, tv: false, downloads: true)
        let without = Destination(musicAudio: true, musicVideo: false, tv: false, downloads: false)
        #expect(withDownloads != without)
        #expect(Set([withDownloads, without]).count == 2)
    }

    @Test func noDestinationProducesNoFlags() {
        let none = Destination(musicAudio: false, musicVideo: false, tv: false, downloads: false)
        #expect(none.isEmpty)
        #expect(none.scriptFlags.isEmpty)
    }

    /// Two items wanting the same destinations must group into one run, so the
    /// combination has to compare and hash equal.
    @Test func equalDestinationsGroupTogether() {
        let a = Destination(musicAudio: true, musicVideo: false, tv: true)
        let b = Destination(musicAudio: true, musicVideo: false, tv: true)
        let c = Destination(musicAudio: true, musicVideo: true, tv: true)
        #expect(a == b)
        #expect(Set([a, b, c]).count == 2)
    }

    // MARK: - What an item is for

    @Test func anItemWithNoDestinationIsNotPending() {
        let i = item()
        #expect(!i.hasDestination)
        #expect(!i.isPending)
    }

    @Test func aQueuedItemWithADestinationIsPending() {
        #expect(item(audio: true).isPending)
    }

    /// An imported item stays in the queue as a record; re-running it would
    /// just duplicate the file.
    @Test func anImportedItemIsNotPendingAgain() {
        #expect(!item(audio: true, status: .done).isPending)
    }

    @Test func aFailedItemCanRunAgain() {
        #expect(item(audio: true, status: .failed).isPending)
    }

    // MARK: - Files versus links

    @Test func aLocalPathIsAFile() {
        let i = item(raw: "/Users/demo/Movies/Rehearsal.mov")
        #expect(i.isFile)
        #expect(i.display == "Rehearsal.mov")
        #expect(i.symbol == "film")
    }

    @Test func aLinkIsNotAFile() {
        let i = item(raw: "https://archive.org/details/x")
        #expect(!i.isFile)
        #expect(i.display == "https://archive.org/details/x")
        #expect(i.symbol == "link")
    }

    // MARK: - Long-form (#83)

    @Test func lengthIsUnknownUntilProbed() {
        var i = item(audio: true)
        #expect(!i.isLongForm)
        #expect(i.durationText == nil)
        i.durationSeconds = 25 * 60
        #expect(i.isLongForm)
        #expect(i.durationText == "25 min")
    }

    /// The script's threshold is twenty minutes, and the row has to agree with
    /// it or the warning appears on items that import fine.
    @Test func theThresholdMatchesTheScript() {
        var i = item(audio: true)
        i.durationSeconds = 20 * 60
        #expect(!i.isLongForm, "exactly twenty minutes is still a song")
        i.durationSeconds = 20 * 60 + 1
        #expect(i.isLongForm)
    }
}

/// The iMessage watcher replies with what it imported. A Downloads-only run has
/// only Downloads lines to go on, and saying "no titles parsed" for a run that
/// worked is just wrong (#111).
@MainActor
struct ReplySummaryTests {

    private func summary(_ lines: [String], status: Int32 = 0) -> String {
        ContentView.buildReplySummary(urls: ["https://example.test/x"], status: status, lines: lines)
    }

    @Test func namesTheSongForAMusicRun() {
        #expect(summary(["→ Music (audio): Village Hall Sessions.m4a"]).contains("Village Hall Sessions"))
    }

    /// The song and the video of one item in Downloads are one track (#164).
    @Test func countsAnItemOnceWhenBothKindsGoToDownloads() {
        let text = summary(["→ Downloads: The Song.m4a", "→ Downloads: The Song.mp4"])
        #expect(text.contains("Imported: The Song"))
    }

    @Test func namesTheFileForADownloadsOnlyRun() {
        let text = summary(["→ Downloads: Village Hall Sessions.mp4"])
        #expect(text.contains("Village Hall Sessions"))
        #expect(!text.contains("no titles parsed"))
    }

    @Test func namesTheSongForADownloadedSong() {
        #expect(summary(["→ Downloads: Winter Rehearsals.m4a"]).contains("Winter Rehearsals"))
    }

    /// Music still wins when a run went to both, so the reply doesn't change
    /// for everyone who already had one.
    @Test func musicStillWinsWhenBothHappened() {
        let text = summary(["→ Music (audio): The Song.m4a", "→ Downloads: The Song.mp4"])
        #expect(text.contains("The Song"))
    }

    @Test func aFailedRunSaysSo() {
        #expect(summary([], status: 1).contains("errors"))
    }
}
