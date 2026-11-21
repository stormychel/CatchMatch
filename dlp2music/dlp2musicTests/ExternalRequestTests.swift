//
//  ExternalRequestTests.swift
//  dlp2musicTests
//
//  Created by Michel Storms on 21/09/2026.
//

import Testing
import Foundation
@testable import dlp2music

/// `catchmatch://` is a public entry point — any web page can navigate to a
/// custom scheme — so these cover what it refuses as much as what it accepts. #109
@MainActor
struct ExternalRequestTests {

    /// The router is a singleton; start every case from an empty queue.
    private func router() -> ExternalRequestRouter {
        let r = ExternalRequestRouter.shared
        _ = r.drain()
        return r
    }

    private func accept(_ string: String) -> (accepted: Bool, pending: [ExternalRequestRouter.Request]) {
        let r = router()
        let accepted = r.accept(URL(string: string)!)
        return (accepted, r.drain())
    }

    // MARK: - Accepted

    @Test func queuesAnHTTPSLink() {
        let (accepted, pending) = accept("catchmatch://add?url=https://archive.org/details/x")
        #expect(accepted)
        #expect(pending.map(\.url) == ["https://archive.org/details/x"])
    }

    @Test func queuesAnHTTPLink() {
        #expect(accept("catchmatch://add?url=http://example.test/x").accepted)
    }

    @Test func destinationFlagsAreRead() {
        let (_, pending) = accept("catchmatch://add?url=https://example.test/x&music=1&tv=0")
        #expect(pending.first?.music == true)
        #expect(pending.first?.tv == false)
    }

    /// Downloads is a destination like the others, so the Safari popup can pick it.
    @Test func theDownloadsFlagIsRead() {
        let (_, pending) = accept("catchmatch://add?url=https://example.test/x&music=0&downloads=1")
        #expect(pending.first?.downloads == true)
        #expect(accept("catchmatch://add?url=https://example.test/y").pending.last?.downloads == nil)
    }

    @Test func theDownloadsAudioFlagIsRead() {
        let (_, pending) = accept("catchmatch://add?url=https://example.test/x&downloadsAudio=1")
        #expect(pending.first?.downloadsAudio == true)
        #expect(accept("catchmatch://add?url=https://example.test/y").pending.last?.downloadsAudio == nil)
    }

    @Test func trueIsAcceptedForAFlag() {
        let (_, pending) = accept("catchmatch://add?url=https://example.test/x&music=true")
        #expect(pending.first?.music == true)
    }

    /// nil means "whatever the window's chips currently say", which is not the
    /// same as an explicit off.
    @Test func absentFlagsStayUnset() {
        let (_, pending) = accept("catchmatch://add?url=https://example.test/x")
        #expect(pending.first?.music == nil)
        #expect(pending.first?.tv == nil)
    }

    // MARK: - Refused

    @Test func refusesAFileURL() {
        let (accepted, pending) = accept("catchmatch://add?url=file:///etc/passwd")
        #expect(!accepted)
        #expect(pending.isEmpty)
    }

    @Test func refusesABarePath() {
        #expect(!accept("catchmatch://add?url=/Users/someone/Movies/private.mov").accepted)
    }

    @Test func refusesAnotherScheme() {
        #expect(!accept("https://add?url=https://example.test/x").accepted)
    }

    @Test func refusesAnUnknownHost() {
        #expect(!accept("catchmatch://start?url=https://example.test/x").accepted)
    }

    @Test func refusesAMissingURL() {
        #expect(!accept("catchmatch://add").accepted)
    }

    @Test func refusesAnEmptyURL() {
        #expect(!accept("catchmatch://add?url=").accepted)
    }

    // MARK: - Behaviour

    /// A request fills the queue; a person presses the button. Nothing in the
    /// request can make the app start importing.
    @Test func aRequestOnlyQueues() {
        let r = router()
        #expect(r.accept(URL(string: "catchmatch://add?url=https://example.test/x&start=1")!))
        #expect(r.pending.count == 1)
    }

    @Test func drainEmptiesTheQueue() {
        let r = router()
        r.accept(URL(string: "catchmatch://add?url=https://example.test/a")!)
        r.accept(URL(string: "catchmatch://add?url=https://example.test/b")!)
        #expect(r.drain().count == 2)
        #expect(r.pending.isEmpty)
        #expect(r.drain().isEmpty)
    }
}
