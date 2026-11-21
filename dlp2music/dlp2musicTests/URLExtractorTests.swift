//
//  URLExtractorTests.swift
//  dlp2musicTests
//
//  Created by Michel Storms on 26/05/2026.
//

import Testing
import Foundation
@testable import dlp2music

struct URLExtractorTests {

    @Test func extractsBareYouTubeURL() {
        let urls = URLExtractor.urls(in: "https://www.youtube.com/watch?v=wpm9mUjNp5w")
        #expect(urls == ["https://www.youtube.com/watch?v=wpm9mUjNp5w"])
    }

    @Test func extractsYoutuBeShortener() {
        let urls = URLExtractor.urls(in: "check this: https://youtu.be/dQw4w9WgXcQ great")
        #expect(urls == ["https://youtu.be/dQw4w9WgXcQ"])
    }

    @Test func multipleURLsInOneMessage() {
        let text = "Two tracks: https://youtu.be/aaa and https://www.youtube.com/watch?v=bbb"
        let urls = URLExtractor.urls(in: text)
        #expect(urls == ["https://youtu.be/aaa", "https://www.youtube.com/watch?v=bbb"])
    }

    @Test func ignoresEmptyText() {
        #expect(URLExtractor.urls(in: "").isEmpty)
        #expect(URLExtractor.urls(in: "just some text without links").isEmpty)
    }

    @Test func trimsTrailingPunctuation() {
        let urls = URLExtractor.urls(in: "Wow, https://youtu.be/xyz!")
        #expect(urls == ["https://youtu.be/xyz"])
    }

    @Test func keepsQueryStringIntact() {
        let urls = URLExtractor.urls(in: "https://www.youtube.com/watch?v=abc&list=PL123")
        #expect(urls == ["https://www.youtube.com/watch?v=abc&list=PL123"])
    }

    @Test func handlesURLInsideAttributedBodyBytes() {
        // Simulates the NSArchiver/typedstream layout: framing bytes around the URL.
        // The URL is plain UTF-8 inside, which our byte scanner should recover.
        let preamble = Data([0x04, 0x0b, 0x73, 0x74, 0x72, 0x65, 0x61, 0x6d, 0x74, 0x79, 0x70, 0x65, 0x64, 0x81]) // "streamtyped" + framing
        let url = "https://www.youtube.com/watch?v=foo"
        let body = preamble + Data(url.utf8) + Data([0x86, 0x84, 0x01, 0x40])
        let urls = URLExtractor.urls(inAttributedBodyBytes: body)
        #expect(urls == [url])
    }

    @Test func ignoresPlainSubstringHttp() {
        let urls = URLExtractor.urls(in: "the word http but not a url")
        #expect(urls.isEmpty)
    }

    @Test func extractsArchiveOrgURL() {
        let urls = URLExtractor.urls(in: "https://archive.org/details/some-concert")
        #expect(urls == ["https://archive.org/details/some-concert"])
    }

    @Test func extractsHttpsAndHttp() {
        let urls = URLExtractor.urls(in: "old http://example.com new https://youtu.be/zzz")
        #expect(urls.contains("http://example.com"))
        #expect(urls.contains("https://youtu.be/zzz"))
    }
}
