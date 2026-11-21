//
//  UsageAnalytics.swift
//  dlp2music
//
//  Created by Michel Storms on 15/10/2026.
//

import Foundation

/// Usage counts in GA4 through the Measurement Protocol (#157): launch,
/// onboarding, imports. Names and coarse states only, never links, titles or
/// file names.
///
/// Plain HTTPS rather than the Firebase SDK: Firebase Analytics is beta on macOS,
/// and a handful of events doesn't need a closed-source SDK in the binary.
///
/// Inert until `measurementID` and `apiSecret` are set: with either empty, or in
/// a Debug build, nothing is sent. Emptying them again is the kill switch.
/// Settings → General → Privacy lets the user turn it off.
@MainActor
final class UsageAnalytics {
    /// From GA4: Admin → Data streams → the CatchMatch stream. Not a secret in any
    /// useful sense, since it ships in the binary; the worst anyone can do with it
    /// is send fake events.
    nonisolated static let shippedMeasurementID = ""
    nonisolated static let shippedAPISecret = ""

    static let shared: UsageAnalytics = {
        #if DEBUG
        // Debug runs would pollute the funnel they are meant to measure.
        return UsageAnalytics(measurementID: "", apiSecret: "")
        #else
        return UsageAnalytics()
        #endif
    }()

    enum Event: String {
        /// The first launch of a fresh install, before onboarding is done.
        case firstOpen = "first_launch"
        case appLaunch = "app_launch"
        case onboardingCompleted = "onboarding_completed"
        case importCompleted = "import_completed"
        case importFailed = "import_failed"
    }

    private enum Key {
        static let enabled = "analytics.enabled"
        static let clientID = "analytics.clientID"
        static let firstOpenSent = "analytics.firstOpenSent"
    }

    private let defaults: UserDefaults
    private let session: URLSession
    private let measurementID: String
    private let apiSecret: String
    /// GA4 needs a session to count an event's user as active; one per launch.
    private let sessionID = String(Int(Date().timeIntervalSince1970))

    init(defaults: UserDefaults = .standard,
         session: URLSession = .shared,
         measurementID: String = UsageAnalytics.shippedMeasurementID,
         apiSecret: String = UsageAnalytics.shippedAPISecret) {
        self.defaults = defaults
        self.session = session
        self.measurementID = measurementID
        self.apiSecret = apiSecret
    }

    /// Whether this build has somewhere to send to. Settings hides the toggle
    /// when it doesn't, since it would do nothing.
    var isConfigured: Bool { !measurementID.isEmpty && !apiSecret.isEmpty }

    /// On unless the user turned it off.
    var isEnabled: Bool {
        get { defaults.object(forKey: Key.enabled) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Key.enabled)
            // Turning it off forgets the install's identifier, so turning it back
            // on starts as a new, unconnected one.
            if !newValue { defaults.removeObject(forKey: Key.clientID) }
        }
    }

    /// A random identifier for this install, made on first use. Not derived from
    /// the Mac, the user or the licence.
    private var clientID: String {
        if let id = defaults.string(forKey: Key.clientID) { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: Key.clientID)
        return id
    }

    /// Called once per launch. `freshInstall` is true until onboarding has been
    /// completed; the first such launch is also counted as `first_launch`.
    func appLaunched(freshInstall: Bool) {
        if freshInstall, !defaults.bool(forKey: Key.firstOpenSent) {
            if send(.firstOpen) { defaults.set(true, forKey: Key.firstOpenSent) }
        }
        send(.appLaunch)
    }

    /// `params` are short fixed labels, never anything the user typed or imported.
    @discardableResult
    func send(_ event: Event, params: [String: String] = [:]) -> Bool {
        guard isConfigured, isEnabled, !ScreenshotMode.isActive else { return false }
        guard let request = makeRequest(event, params: params) else { return false }
        Task {
            do {
                _ = try await session.data(for: request)
            } catch {
                // Counts are not worth retrying, queueing or bothering anyone over.
                AppLog.shared.log("Usage count \(event.rawValue) not sent: \(error.localizedDescription)", level: .info)
            }
        }
        return true
    }

    func makeRequest(_ event: Event, params: [String: String]) -> URLRequest? {
        var components = URLComponents(string: "https://www.google-analytics.com/mp/collect")!
        components.queryItems = [
            URLQueryItem(name: "measurement_id", value: measurementID),
            URLQueryItem(name: "api_secret", value: apiSecret)
        ]
        guard let url = components.url else { return nil }

        var eventParams: [String: Any] = params
        eventParams["session_id"] = sessionID
        eventParams["engagement_time_msec"] = 1
        eventParams["app_version"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"

        let payload: [String: Any] = [
            "client_id": clientID,
            "non_personalized_ads": true,
            "events": [["name": event.rawValue, "params": eventParams]]
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 15
        return request
    }
}
