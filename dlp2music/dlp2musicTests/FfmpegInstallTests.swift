//
//  FfmpegInstallTests.swift
//  dlp2musicTests
//
//  Created by Michel Storms on 22/09/2026.
//

import Testing
import Foundation
import CryptoKit
@testable import dlp2music

/// The app installs its own ffmpeg instead of sending people to Homebrew. The
/// archive is checked against a pinned hash and installed both-or-neither. #80
struct FfmpegInstallTests {

    /// A throwaway bin/licences pair, so nothing touches Application Support.
    private struct Sandbox {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cm-ffmpeg-test-\(UUID().uuidString)", isDirectory: true)
        var bin: URL { root.appendingPathComponent("bin", isDirectory: true) }
        var licenses: URL { root.appendingPathComponent("licenses/ffmpeg", isDirectory: true) }
        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    /// Zips `files` flat, the way Scripts/build_ffmpeg.sh lays out its archive.
    private func archive(_ files: [String: String]) throws -> Data {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cm-ffmpeg-src-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let content = dir.appendingPathComponent("content", isDirectory: true)
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        for (name, text) in files {
            try Data(text.utf8).write(to: content.appendingPathComponent(name))
        }
        let zip = dir.appendingPathComponent("archive.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", content.path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()
        return try Data(contentsOf: zip)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private let complete = [
        "ffmpeg": "#!/bin/sh\necho ffmpeg\n",
        "ffprobe": "#!/bin/sh\necho ffprobe\n",
        "NOTICE.txt": "notice",
        "LICENSE-ffmpeg-LGPL-2.1.txt": "lgpl",
        "LICENSE-dav1d-BSD-2-Clause.txt": "bsd",
    ]

    @Test func installsBothBinariesAndTheirLicences() throws {
        let sandbox = Sandbox()
        defer { sandbox.cleanUp() }
        let zip = try archive(complete)

        try ToolManager.installFfmpegArchive(zip, expectedSHA256: sha256(zip),
                                             binDirectory: sandbox.bin, licensesDirectory: sandbox.licenses)

        for tool in ["ffmpeg", "ffprobe"] {
            #expect(FileManager.default.isExecutableFile(atPath: sandbox.bin.appendingPathComponent(tool).path))
        }
        let licences = try FileManager.default.contentsOfDirectory(atPath: sandbox.licenses.path).sorted()
        #expect(licences == ["LICENSE-dav1d-BSD-2-Clause.txt", "LICENSE-ffmpeg-LGPL-2.1.txt", "NOTICE.txt"])
    }

    /// A substituted download must never reach the bin directory.
    @Test func refusesAnArchiveThatDoesNotMatchThePinnedHash() throws {
        let sandbox = Sandbox()
        defer { sandbox.cleanUp() }
        let zip = try archive(complete)

        #expect(throws: (any Error).self) {
            try ToolManager.installFfmpegArchive(zip, expectedSHA256: String(repeating: "0", count: 64),
                                                 binDirectory: sandbox.bin, licensesDirectory: sandbox.licenses)
        }
        #expect(!FileManager.default.fileExists(atPath: sandbox.bin.appendingPathComponent("ffmpeg").path))
    }

    /// The pipeline runs ffprobe as well, so an ffmpeg on its own is not installed.
    @Test func installsNeitherWhenOneBinaryIsMissing() throws {
        let sandbox = Sandbox()
        defer { sandbox.cleanUp() }
        var partial = complete
        partial["ffprobe"] = nil
        let zip = try archive(partial)

        #expect(throws: (any Error).self) {
            try ToolManager.installFfmpegArchive(zip, expectedSHA256: sha256(zip),
                                                 binDirectory: sandbox.bin, licensesDirectory: sandbox.licenses)
        }
        #expect(!FileManager.default.fileExists(atPath: sandbox.bin.appendingPathComponent("ffmpeg").path))
    }

    /// The LGPL notices travel with the binaries, so an archive without them
    /// installs nothing.
    @Test func installsNothingWithoutTheLicences() throws {
        let sandbox = Sandbox()
        defer { sandbox.cleanUp() }
        let zip = try archive(complete.filter { !$0.key.hasPrefix("LICENSE-") })

        #expect(throws: (any Error).self) {
            try ToolManager.installFfmpegArchive(zip, expectedSHA256: sha256(zip),
                                                 binDirectory: sandbox.bin, licensesDirectory: sandbox.licenses)
        }
        #expect(!FileManager.default.fileExists(atPath: sandbox.bin.appendingPathComponent("ffmpeg").path))
    }

    /// A new build replaces the old one in place and leaves no staging or
    /// set-aside copies behind.
    @Test func replacesAnEarlierInstallCleanly() throws {
        let sandbox = Sandbox()
        defer { sandbox.cleanUp() }
        let old = try archive(complete)
        try ToolManager.installFfmpegArchive(old, expectedSHA256: sha256(old),
                                             binDirectory: sandbox.bin, licensesDirectory: sandbox.licenses)
        var newer = complete
        newer["ffmpeg"] = "#!/bin/sh\necho newer\n"
        let zip = try archive(newer)

        try ToolManager.installFfmpegArchive(zip, expectedSHA256: sha256(zip),
                                             binDirectory: sandbox.bin, licensesDirectory: sandbox.licenses)

        let installed = try String(contentsOf: sandbox.bin.appendingPathComponent("ffmpeg"), encoding: .utf8)
        #expect(installed.contains("newer"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: sandbox.bin.path).sorted() == ["ffmpeg", "ffprobe"])
        let licencesParent = sandbox.licenses.deletingLastPathComponent()
        #expect(try FileManager.default.contentsOfDirectory(atPath: licencesParent.path) == ["ffmpeg"])
    }
}
