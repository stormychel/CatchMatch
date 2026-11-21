//
//  ExternalRequest.swift
//  dlp2music
//
//  Created by Michel Storms on 30/08/2026.
//

import Foundation
import AppKit
import Security

/// One `catchmatch://` request, waiting for the window to pick it up.
///
/// The scheme is the app's front door for anything outside it — a Safari
/// extension, a Shortcut, a script. It is a holding pen rather than a
/// notification for the same reason a dropped file is: the request can arrive
/// *as* the app launches, before any view exists to hear it.
@MainActor
final class ExternalRequestRouter: ObservableObject {
    static let shared = ExternalRequestRouter()

    struct Request: Equatable {
        /// Always an http(s) URL. See `accept(_:)` for why it can't be anything else.
        let url: String
        /// nil means "whatever the window's chips currently say".
        let music: Bool?
        let tv: Bool?
        /// The video to Downloads; `downloadsAudio` is the song (#164).
        var downloads: Bool? = nil
        var downloadsAudio: Bool? = nil
        /// Sent by our own Safari extension, so the person already chose to import
        /// it; see `ExtensionSender`.
        var autoStart = false
    }

    @Published private(set) var pending: [Request] = []

    private init() {}

    /// `catchmatch://add?url=…&music=1&tv=0&downloads=0&downloadsAudio=1`
    ///
    /// Anything else is ignored rather than guessed at. This is a **public**
    /// entry point — any web page can navigate to a custom scheme — so it is
    /// deliberately narrow:
    ///
    /// - **http(s) only.** Without this, a page could hand over a `file://` URL
    ///   or a bare path and have the app read something off the disk that the
    ///   user never chose.
    /// - **Queues, never starts.** An earlier draft honoured a `start=1`
    ///   parameter, which would have let any page begin an import unattended.
    ///   A request can fill the queue; a person presses the button.
    ///
    /// The one exception to "queues, never starts" is `autoStart`, set only when
    /// macOS vouches that our own signed extension sent the link (#84).
    @discardableResult
    func accept(_ incoming: URL, autoStart: Bool = false) -> Bool {
        guard incoming.scheme?.lowercased() == "catchmatch",
              incoming.host?.lowercased() == "add",
              let components = URLComponents(url: incoming, resolvingAgainstBaseURL: false),
              let target = components.queryItems?.first(where: { $0.name == "url" })?.value?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !target.isEmpty,
              let scheme = URL(string: target)?.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return false }

        func flag(_ name: String) -> Bool? {
            guard let raw = components.queryItems?.first(where: { $0.name == name })?.value else { return nil }
            return raw == "1" || raw.lowercased() == "true"
        }

        pending.append(Request(url: target, music: flag("music"), tv: flag("tv"), downloads: flag("downloads"),
                               downloadsAudio: flag("downloadsAudio"), autoStart: autoStart))
        return true
    }

    func drain() -> [Request] {
        defer { pending.removeAll() }
        return pending
    }
}

/// Whether the `catchmatch://` link being handled came from CatchMatch's own
/// Safari extension.
///
/// Any web page can open a catchmatch:// link, so a link alone never starts an
/// import. The Apple Event that delivers it carries the sender's audit token,
/// though, and macOS can check that sender's code signature: only an extension
/// signed by this team with this identifier passes. A page, or Safari itself,
/// doesn't, and its link is queued as before (#84).
enum ExtensionSender {
    private static let requirement =
        "identifier \"com.michelstorms.dlp2music.Extension\" and anchor apple generic"
        + " and certificate leaf[subject.OU] = \"4VYV5C3L3Y\""

    /// Whether `url` arrived in the Apple Event being handled right now, sent by
    /// our extension. SwiftUI calls `onOpenURL` from inside that `GURL` event,
    /// but the check is tied to it rather than trusting that: unless the current
    /// event is a GURL carrying this very link, the answer is no and the link
    /// is only queued. Failing closed costs an auto-start, never a safeguard.
    @MainActor
    static func sentByOurExtension(_ url: URL) -> Bool {
        let senderAuditToken = AEKeyword(0x746F_6B6E) // 'tokn', keySenderAuditTokenAttr
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == AEEventClass(kInternetEventClass),
              event.eventID == AEEventID(kAEGetURL),
              event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue == url.absoluteString,
              let token = event.attributeDescriptor(forKeyword: senderAuditToken)?.data,
              !token.isEmpty else { return false }
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit: token] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code else { return false }
        var req: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess,
              let req else { return false }
        return SecCodeCheckValidity(code, [], req) == errSecSuccess
    }
}
