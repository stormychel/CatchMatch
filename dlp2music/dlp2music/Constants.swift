//
//  Constants.swift
//  dlp2music
//
//  Created by Michel Storms on 26/05/2026.
//

import Foundation

/// Single source of truth for app-wide string constants. Edit here, propagate everywhere.
enum Constants {
    /// User-visible product name. Used in iMessage reply prefixes and anywhere else we
    /// want to identify outgoing messages or notifications as coming from this app.
    static let appName: String = "CatchMatch"

    /// Tip jar, shown in Settings → General → Support (#169).
    static let buyMeACoffeeURL = URL(string: "https://buymeacoffee.com/stormychel")!

    /// True in a copy built for Setapp (`SETAPP` compilation condition). The
    /// subscription pays for it and Setapp delivers its updates, so that copy
    /// has no trial, no license key, no paywall and no updater of its own. #107
    #if SETAPP
    static let isSetappBuild = true
    #else
    static let isSetappBuild = false
    #endif
}
