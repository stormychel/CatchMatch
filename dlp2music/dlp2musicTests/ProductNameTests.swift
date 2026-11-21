//
//  ProductNameTests.swift
//  dlp2musicTests
//
//  Created by Michel Storms on 21/09/2026.
//

import Testing
import Foundation
@testable import dlp2music

/// The module is called dlp2music; the product is called CatchMatch. Anything a
/// customer reads, or pastes into a support email, must use the product name.
/// #135
struct ProductNameTests {

    /// Copy Diagnostics is what a customer sends when something goes wrong, so
    /// its first line is the first thing support reads. Built against a
    /// throwaway directory: the shared log is the real user's.
    @Test func diagnosticsNameTheProduct() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("catchmatch.tests.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = AppLog(directory: dir).diagnosticsBundle()
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first
            .map(String.init)
        #expect(first == "CatchMatch diagnostics")
    }
}
