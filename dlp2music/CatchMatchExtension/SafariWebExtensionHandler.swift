//
//  SafariWebExtensionHandler.swift
//  CatchMatch
//
//  Created by Michel Storms on 22/09/2026.
//

import AppKit
import SafariServices
import os.log

/// Hands a page from the Safari extension to the app.
///
/// Safari won't let an extension's script open a custom scheme itself: the popup's
/// catchmatch:// link went nowhere, without a prompt or an error (#84). So the
/// popup sends the page here by native messaging, and this opens the same
/// catchmatch://add link the app already handles.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey] as? [String: Any]
        let sent = message.flatMap(Self.catchMatchURL(for:)).map { NSWorkspace.shared.open($0) } ?? false
        if !sent { os_log(.error, "CatchMatch extension: couldn't hand over %@", String(describing: message)) }
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: ["ok": sent]]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }

    /// `catchmatch://add?url=…` plus any destinations the popup chose. Only
    /// http(s) pages are passed on; the app checks that again on its side.
    static func catchMatchURL(for message: [String: Any]) -> URL? {
        guard let page = message["url"] as? String,
              let scheme = URL(string: page)?.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        var components = URLComponents()
        components.scheme = "catchmatch"
        components.host = "add"
        var query = [URLQueryItem(name: "url", value: page)]
        for key in ["music", "tv", "downloads", "downloadsAudio"] {
            if let on = message[key] as? Bool { query.append(URLQueryItem(name: key, value: on ? "1" : "0")) }
        }
        components.queryItems = query
        return components.url
    }
}
