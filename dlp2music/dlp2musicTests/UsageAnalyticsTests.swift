//
//  UsageAnalyticsTests.swift
//  dlp2musicTests
//
//  Created by Michel Storms on 15/10/2026.
//

import Testing
import Foundation
@testable import dlp2music

/// Usage counts go to a third party, so these pin when nothing is sent and what
/// a request carries when something is. #157
@MainActor
@Suite(.serialized)
struct UsageAnalyticsTests {

    /// Swallows every request, so no test reaches Google.
    final class FakeCollector: URLProtocol {
        nonisolated(unsafe) static var requestCount = 0
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.requestCount += 1
            let response = HTTPURLResponse(url: request.url!, statusCode: 204,
                                           httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func makeAnalytics(measurementID: String = "G-TEST",
                               apiSecret: String = "secret",
                               defaults: UserDefaults = UserDefaults(suiteName: "catchmatch.tests.\(UUID().uuidString)")!) -> UsageAnalytics {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeCollector.self]
        return UsageAnalytics(defaults: defaults, session: URLSession(configuration: config),
                              measurementID: measurementID, apiSecret: apiSecret)
    }

    private func payload(of request: URLRequest?) throws -> [String: Any] {
        let body = try #require(request?.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    @Test func anUnconfiguredBuildSendsNothing() {
        #expect(!makeAnalytics(measurementID: "").send(.appLaunch))
        #expect(!makeAnalytics(apiSecret: "").send(.appLaunch))
    }

    @Test func theShippedDebugInstanceSendsNothing() {
        // Tests run a Debug build, where the shared instance must stay inert.
        #expect(!UsageAnalytics.shared.isConfigured)
    }

    @Test func turningItOffStopsSendingAndForgetsTheInstall() throws {
        let defaults = UserDefaults(suiteName: "catchmatch.tests.\(UUID().uuidString)")!
        let a = makeAnalytics(defaults: defaults)
        let before = try payload(of: a.makeRequest(.appLaunch, params: [:]))["client_id"] as? String
        #expect(before != nil)

        a.isEnabled = false
        #expect(!a.send(.appLaunch))
        #expect(defaults.string(forKey: "analytics.clientID") == nil)

        a.isEnabled = true
        let after = try payload(of: a.makeRequest(.appLaunch, params: [:]))["client_id"] as? String
        #expect(after != nil && after != before)
    }

    @Test func itIsOnByDefault() {
        #expect(makeAnalytics().isEnabled)
    }

    @Test func aRequestCarriesTheEventAndNothingElse() throws {
        let a = makeAnalytics()
        let request = try #require(a.makeRequest(.importCompleted, params: ["source": "queue"]))
        let url = try #require(request.url?.absoluteString)
        #expect(url.hasPrefix("https://www.google-analytics.com/mp/collect?"))
        #expect(url.contains("measurement_id=G-TEST"))

        let body = try payload(of: request)
        #expect(Set(body.keys) == ["client_id", "non_personalized_ads", "events"])
        let events = try #require(body["events"] as? [[String: Any]])
        #expect(events.count == 1)
        #expect(events[0]["name"] as? String == "import_completed")
        let params = try #require(events[0]["params"] as? [String: Any])
        #expect(Set(params.keys) == ["source", "session_id", "engagement_time_msec", "app_version"])
        #expect(params["source"] as? String == "queue")
    }

    @Test func firstLaunchIsCountedOnce() {
        let defaults = UserDefaults(suiteName: "catchmatch.tests.\(UUID().uuidString)")!
        let a = makeAnalytics(defaults: defaults)
        #expect(!defaults.bool(forKey: "analytics.firstOpenSent"))
        a.appLaunched(freshInstall: true)
        #expect(defaults.bool(forKey: "analytics.firstOpenSent"))
    }

    @Test func anOptedOutFirstLaunchIsNotMarkedSent() {
        // Otherwise opting back in later could never count it, nor should it.
        let defaults = UserDefaults(suiteName: "catchmatch.tests.\(UUID().uuidString)")!
        let a = makeAnalytics(defaults: defaults)
        a.isEnabled = false
        a.appLaunched(freshInstall: true)
        #expect(!defaults.bool(forKey: "analytics.firstOpenSent"))
    }

    @Test func anUpgradeIsNotAFirstLaunch() {
        let defaults = UserDefaults(suiteName: "catchmatch.tests.\(UUID().uuidString)")!
        makeAnalytics(defaults: defaults).appLaunched(freshInstall: false)
        #expect(!defaults.bool(forKey: "analytics.firstOpenSent"))
    }
}
