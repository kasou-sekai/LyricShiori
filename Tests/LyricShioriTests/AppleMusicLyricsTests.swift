import AppKit
import CoreText
import Foundation
import XCTest
@testable import LyricShiori

final class AppleMusicLyricsTests: XCTestCase {
    // Synthetic duet fixture, no copyrighted song text. The vocal arrangement
    // exercises the overlap/background structure needed by 珊瑚海.
    private let duet = """
    <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" xmlns:itunes="http://music.apple.com/lyric-ttml-internal" xmlns:tts="http://www.w3.org/ns/ttml#styling" xml:lang="zh-Hant">
      <head><metadata><ttm:agent xml:id="v1" type="person"/><ttm:agent xml:id="v2" type="person"/>
        <iTunesMetadata><translations><translation xml:lang="en"><text for="L1">Ocean</text></translation></translations></iTunesMetadata>
      </metadata><styling><style xml:id="right" tts:textAlign="right"/></styling></head>
      <body dur="4:00.500"><div>
        <p begin="10" end="15" itunes:key="L1" ttm:agent="v1"><span begin="10" end="13"><span begin="10" end="11">海</span><span begin="11.5" end="13">洋</span></span><span ttm:role="x-bg" begin="12" end="14"><span begin="12" end="14">和声</span></span></p>
        <p begin="11" end="16" itunes:key="L2" ttm:agent="v2" style="right"><span begin="11" end="16">对唱</span></p>
        <p begin="18" end="20" itunes:key="L3"><span tts:ruby="container"><span tts:ruby="base">海</span><span tts:ruby="text">うみ</span></span></p>
      </div></body>
    </tt>
    """

    func testDuetPreservesOverlapsAlignmentBackgroundNestedTimingAndRuby() throws {
        let document = try AppleMusicTTMLParser().parse(duet, catalogID: "123", storefront: "tw")
        XCTAssertEqual(document.lines.map(\.content), ["海洋", "对唱", "和声", "海"])
        XCTAssertEqual(document.lines[0].translations["en"], "Ocean")
        XCTAssertEqual(document.metadata.translationLanguages, ["en"])
        XCTAssertEqual(document.lines[0].wordTimings.map(\.start), [10, 11.5])
        XCTAssertEqual(document.lines[0].wordTimings.map(\.duration), [1, 1.5])
        XCTAssertEqual(document.lines[1].presentation?.alignment, .right)
        XCTAssertEqual(document.lines[1].presentation?.agent, "v2")
        XCTAssertEqual(document.lines[2].presentation?.isBackground, true)
        XCTAssertEqual(document.lines[2].presentation?.parentKey, "L1")
        XCTAssertEqual(document.lines[0].presentation?.end, 15)
        XCTAssertTrue(document.lines[3].presentation!.element.content.contains("うみ"))
        XCTAssertEqual(document.activeLineIndices(at: 12.5), [0, 1, 2])
        XCTAssertEqual(document.activeLineIndices(at: 14), [0, 1])
        XCTAssertEqual(document.activeLineIndices(at: 16), [])
        XCTAssertEqual(document.appleMusic?.ttml, duet)
        let filtered = LyricsFilter(enabled: true, smartFilterEnabled: true, blockedPatterns: ["和声"]).apply(to: document)
        XCTAssertEqual(filtered.lines, document.lines)
    }

    func testLRCSRoundTripPreservesAllRichDataAndOldFilesStillLoad() throws {
        let document = try AppleMusicTTMLParser().parse(duet)
        let encoded = try LyricsCacheFile.encode(document: document, track: nil)
        let decoded = try LyricsCacheFile.decode(encoded, sourceName: nil, localURL: nil, track: nil)
        XCTAssertEqual(decoded.appleMusic, document.appleMusic)
        XCTAssertEqual(decoded.lines.map(\.presentation), document.lines.map(\.presentation))
        XCTAssertEqual(decoded.lines.map(\.content), document.lines.map(\.content))
        let old = try LyricsParser().parse("[00:01.00]legacy")
        let legacy = try LyricsCacheFile.decode(LyricsCacheFile.encode(document: old, track: nil), sourceName: nil, localURL: nil, track: nil)
        XCTAssertNil(legacy.appleMusic)
        XCTAssertNil(legacy.lines[0].presentation)
    }

    func testFutureFullscapeFieldsDecodeWithoutEnablingSharing() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = SharedLyricsCache(url: url)
        let track = TrackIdentity(id: "spotify:track:test", title: "珊瑚海", artist: "周杰伦", duration: 240)
        var document = try AppleMusicTTMLParser().parse(duet)
        document.selectionState = .manual()
        try cache.save(document, for: track)
        XCTAssertNil(try cache.entry(trackUri: track.id, kind: .enhanced))
        XCTAssertNil(try cache.encodedEntry(document, for: track, kind: .enhanced))
        XCTAssertNil(try cache.encodedBestPreferredEntry(document, for: track, kind: .enhanced))
        let json = """
        {"time":10000,"text":"a","presentation":\(String(data: try JSONEncoder().encode(document.lines[0].presentation!), encoding: .utf8)!)}
        """
        let line = try JSONDecoder().decode(SharedLyricsCache.Line.self, from: Data(json.utf8))
        XCTAssertEqual(line.presentation, document.lines[0].presentation)
    }

    func testUntimedSpacesPunctuationAndLegacyCacheKeepSyllableTimes() throws {
        let xml = "<tt><body><p begin='1' end='5'><span begin='1' end='2'>Hello</span> <span begin='2' end='3'>ocean</span>! <span begin='3' end='5'>Again</span></p></body></tt>"
        let document = try AppleMusicTTMLParser().parse(xml)
        let line = document.lines[0]
        XCTAssertEqual(line.wordTimings.map(\.text), ["Hello ", "ocean! ", "Again"])
        XCTAssertEqual(line.wordTimings.map(\.start), [1, 2, 3])
        XCTAssertEqual(line.wordTimings.map(\.duration), [1, 1, 2])
        var legacy = document
        for index in legacy.lines[0].wordTimings.indices {
            legacy.lines[0].wordTimings[index].text = ["Hello", "ocean", "Again"][index]
        }
        let data = try LyricsCacheFile.encode(document: legacy, track: nil)
        let loaded = try LyricsCacheFile.decode(data, sourceName: nil, localURL: nil, track: nil)
        XCTAssertEqual(loaded.lines[0].wordTimings.map(\.text).joined(), line.content)
        XCTAssertEqual(loaded.lines[0].wordTimings.map(\.start), [1, 2, 3])
        XCTAssertEqual(loaded.appleMusic?.ttml, xml)
    }

    func testLineTimingNeverBecomesSyntheticSyllablesAndLegacyCachesAreRepaired() throws {
        for attribute in ["", "itunes:timing='Line'"] {
            let xml = "<tt xmlns:itunes='http://music.apple.com/lyric-ttml-internal' \(attribute)><body><p begin='0' end='20'>Hello ocean</p><p begin='20' end='25'><span>Again</span></p></body></tt>"
            var document = try AppleMusicTTMLParser().parse(xml)
            XCTAssertTrue(document.lines.allSatisfy { $0.wordTimings.isEmpty })
            document.lines[0].wordTimings = [WordTiming(start: 0, duration: 20, text: "Hello ocean")]
            let data = try LyricsCacheFile.encode(document: document, track: nil)
            let repaired = try LyricsCacheFile.decode(data, sourceName: nil, localURL: nil, track: nil)
            XCTAssertTrue(repaired.lines.allSatisfy { $0.wordTimings.isEmpty })
            XCTAssertEqual(repaired.lines.map(\.position), [0,20])
            XCTAssertEqual(repaired.appleMusic?.ttml, xml)
        }
        let explicitLine = try AppleMusicTTMLParser().parse("<tt xmlns:itunes='x' itunes:timing='Line'><body><p begin='1' end='5'><span begin='1' end='5'>Whole sentence</span></p></body></tt>")
        XCTAssertTrue(explicitLine.lines[0].wordTimings.isEmpty)
    }

    func testTimeFormatsAndInvalidDocuments() throws {
        XCTAssertEqual(AppleMusicTTMLParser.time("1:02:03.25"), 3723.25)
        XCTAssertEqual(AppleMusicTTMLParser.time("00:10.500"), 10.5)
        XCTAssertEqual(AppleMusicTTMLParser.time("1200ms"), 1.2)
        XCTAssertEqual(AppleMusicTTMLParser.time("2m"), 120)
        for value in ["NaN", "inf", "-1", "1::2", "1:2:3:4"] { XCTAssertNil(AppleMusicTTMLParser.time(value)) }
        XCTAssertThrowsError(try AppleMusicTTMLParser().parse("<!DOCTYPE tt [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><tt><body><p>&x;</p></body></tt>"))
        XCTAssertThrowsError(try AppleMusicTTMLParser().parse("<tt><body><p begin='NaN'>a</p></body></tt>"))
        XCTAssertThrowsError(try AppleMusicTTMLParser().parse("<tt><body><p begin='10' end='9'>a</p></body></tt>"))
        XCTAssertThrowsError(try AppleMusicTTMLParser().parse("<tt><body>"))
    }

    func testUnicodeWhitespaceAndNamespacePrefixes() throws {
        let xml = """
        <t:tt xmlns:t="http://www.w3.org/ns/ttml"><t:body><t:div><t:p begin="1" end="3">
          <t:span begin="1" end="2">👨‍👩‍👧‍👦</t:span> <t:span begin="2" end="3">é</t:span>
        </t:p></t:div></t:body></t:tt>
        """
        let document = try AppleMusicTTMLParser().parse(xml)
        XCTAssertEqual(document.lines[0].content, "👨‍👩‍👧‍👦 é")
        XCTAssertEqual(document.lines[0].wordTimings.map(\.text), ["👨‍👩‍👧‍👦 ", "é"])
        XCTAssertEqual(document.lines[0].wordTimings.map(\.start), [1, 2])
    }
}

@MainActor
final class AppleMusicLyricsServiceTests: XCTestCase {
    private final class Transport: AppleMusicLyricsTransport {
        var authorized = true
        var paths: [String] = []
        var response: (String) throws -> Data = { _ in Data() }
        func isAuthorized() async -> Bool { authorized }
        func request(_ path: String) async throws -> Data {
            paths.append(path)
            return try response(path)
        }
    }

    func testSearchUsesLocalizedTTMLAndSkipsWrongDuration() async throws {
        let transport = Transport()
        transport.response = { path in
            if path == "/v1/me/storefront" { return Data(#"{"data":{"data":[{"id":"tw"}]}}"#.utf8) }
            if path.contains("/search?") {
                return Data(#"{"results":{"songs":{"data":[{"id":"123","attributes":{"name":"珊瑚海","artistName":"周杰倫 & Lara","durationInMillis":240000}},{"id":"456","attributes":{"name":"live","artistName":"cover","durationInMillis":180000}}]}}}"#.utf8)
            }
            return Data(#"{"data":[{"attributes":{"ttmlLocalizations":"<tt><body><p begin='1' end='2'><span begin='1' end='2'>test</span></p></body></tt>"}}]}"#.utf8)
        }
        let request = ShioriLyricsSearchRequest(title: "珊瑚海 & +", artist: "周杰伦", duration: 240, limit: 5)
        let results = try await AppleMusicLyricsService(session: transport).search(request)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].document.appleMusic?.catalogID, "123")
        XCTAssertEqual(results[0].document.appleMusic?.storefront, "tw")
        XCTAssertEqual(results[0].document.metadata.title, "珊瑚海")
        XCTAssertEqual(results[0].document.metadata.request, request)
        XCTAssertEqual(transport.paths.count, 3)
        let search = try XCTUnwrap(URLComponents(string: transport.paths[1]))
        XCTAssertEqual(search.queryItems?.first { $0.name == "term" }?.value, "珊瑚海 & + 周杰伦")
        XCTAssertTrue(transport.paths[1].contains("%2B"))
        XCTAssertTrue(transport.paths[2].contains("extend=ttmlLocalizations"))
    }

    func testUnauthorizedSourceDoesNotRequestCatalogOrLyrics() async throws {
        let transport = Transport()
        transport.authorized = false
        do {
            _ = try await AppleMusicLyricsService(session: transport).search(
                ShioriLyricsSearchRequest(title: "珊瑚海", artist: "周杰伦", limit: 5))
            XCTFail("An unauthorized session must not be negative-cached as missing lyrics")
        } catch AppleMusicLyricsAcquisitionError.unauthorized {}
        XCTAssertTrue(transport.paths.isEmpty)
    }
}

@MainActor
final class AppleMusicStyledTextTests: XCTestCase {
    func testRubyAndInlineSmallTextRenderToPixels() throws {
        let xml = """
        <tt xmlns:tts="http://www.w3.org/ns/ttml#styling"><body><p begin="1" end="4"><span tts:ruby="container"><span tts:ruby="base">海</span><span tts:ruby="text">うみ</span></span><span tts:fontSize="65%">洋</span></p></body></tt>
        """
        let document = try AppleMusicTTMLParser().parse(xml)
        let source = document.lines[0]
        let line = DesktopLyricsDisplayLine(id: "ruby", lineID: source.id, text: source.content,
            wordTimings: [], lineStart: 1, lineEnd: 4, playbackTime: 2,
            isPlaying: false, isActive: true, distanceFromActive: 0, progress: 0.5, presentation: source.presentation)
        let view = AppleMusicStyledTextView(frame: NSRect(x: 0, y: 0, width: 450, height: 80))
        view.line = line
        view.fontSize = 32
        let attributed = view.attributedText(for: line)
        XCTAssertEqual((attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 32)
        XCTAssertEqual((attributed.attribute(.font, at: 1, effectiveRange: nil) as? NSFont)?.pointSize ?? 0, 20.8, accuracy: 0.01)
        let rubyKey = NSAttributedString.Key(kCTRubyAnnotationAttributeName as String)
        XCTAssertNotNil(attributed.attribute(rubyKey, at: 0, effectiveRange: nil))
        XCTAssertNil(attributed.attribute(rubyKey, at: 1, effectiveRange: nil))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 450, pixelsHigh: 80,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        let painted = (0..<(bitmap.pixelsWide * bitmap.pixelsHigh)).filter { pixels[$0 * 4 + 3] > 0 }.count
        XCTAssertGreaterThan(painted, 100)
        if let path = ProcessInfo.processInfo.environment["LYRICSHIORI_RENDER_APPLE_MUSIC"],
           let png = bitmap.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: path))
        }
    }
}

final class LyricsSourceStorageTests: XCTestCase {
    private func withStorage(_ run: (LocalLyricsStorage, TrackIdentity) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try run(LocalLyricsStorage(baseDirectory: directory), TrackIdentity(id: "spotify:track:duet", title: "珊瑚海", artist: "周杰伦"))
    }
    private func appleDocument() throws -> LyricsDocument {
        try AppleMusicTTMLParser().parse("<tt><body><p begin='1' end='3'>duet</p></body></tt>")
    }
    private func standardDocument() throws -> LyricsDocument {
        try LyricsParser().parse("[00:01.00]standard", sourceName: "QQMusic")
    }

    func testLocalizedFilenameCannotHideManualOffsetForSameTrackAndFamily() throws {
        try withStorage { storage, native in
            var localized = native
            localized.title = "Localized title"
            localized.artist = "Localized artist"
            for family in LyricsStorageFamily.allCases {
                var automatic = try family == .appleMusic ? appleDocument() : standardDocument()
                automatic.selectionState = .automaticSearch(cachedWithoutPlugin: true)
                _ = try storage.saveCandidate(automatic, for: localized)
                var adjusted = automatic
                adjusted.offsetMilliseconds = 1250
                adjusted.selectionState = .manual()
                _ = try storage.save(adjusted, for: native)
                let read = try XCTUnwrap(storage.loadLyrics(for: localized, family: family))
                XCTAssertEqual(read.offsetMilliseconds, 1250)
                XCTAssertEqual(read.selectionState.cacheSource, .manual)
            }
        }
    }

    func testTwoSourcesCoexistAndSelectedSourceSurvivesRestart() throws {
        try withStorage { storage, track in
            let standard = try standardDocument()
            let apple = try appleDocument()
            let ordinaryURL = try storage.save(standard, for: track)
            let appleURL = try storage.save(apple, for: track)
            XCTAssertNotEqual(ordinaryURL, appleURL)
            XCTAssertEqual(ordinaryURL.deletingLastPathComponent().path, storage.baseDirectory.path)
            XCTAssertEqual(appleURL.deletingLastPathComponent().lastPathComponent, "Apple Music")
            XCTAssertEqual(try storage.loadLyrics(for: track, family: .standard)?.lines.first?.content, "standard")
            XCTAssertEqual(try storage.loadLyrics(for: track, family: .appleMusic)?.appleMusic, apple.appleMusic)
            let restarted = LocalLyricsStorage(baseDirectory: storage.baseDirectory)
            XCTAssertNotNil(try restarted.loadLyrics(for: track)?.appleMusic)
            try restarted.select(.standard, for: track)
            XCTAssertNil(try storage.loadLyrics(for: track)?.appleMusic)
            XCTAssertNotNil(try storage.loadLyrics(for: track, family: .appleMusic))
            try storage.removeLyrics(for: track)
            XCTAssertNil(try storage.loadLyrics(for: track, family: .standard))
            XCTAssertNil(try storage.loadLyrics(for: track, family: .appleMusic))
            XCTAssertNil(try storage.loadLyrics(for: track))
        }
    }

    func testBackgroundDownloadsDoNotChangeChoiceOrOverwriteManualVariant() throws {
        try withStorage { storage, track in
            var apple = try appleDocument()
            apple.selectionState = .manual()
            _ = try storage.save(apple, for: track)
            _ = try storage.saveCandidate(standardDocument(), for: track)
            XCTAssertNotNil(try storage.loadLyrics(for: track)?.appleMusic)
            var alternate = apple
            alternate.lines[0].content = "another recording"
            _ = try storage.saveCandidate(alternate, for: track, preservingManualSelection: true)
            XCTAssertEqual(try storage.loadLyrics(for: track, family: .appleMusic)?.lines[0].content, "duet")
            try storage.select(.standard, for: track)
            _ = try storage.saveCandidate(apple, for: track)
            XCTAssertNil(try storage.loadLyrics(for: track)?.appleMusic)
        }
    }

    func testLegacyAppleFileMigratesBeforeStandardSaveWithoutLosingChoice() throws {
        try withStorage { storage, track in
            // Create the old root-level layout, with no source selection sidecar.
            let rootURL = try storage.save(standardDocument(), for: track)
            let selections = storage.baseDirectory.appendingPathComponent("Selections")
            try FileManager.default.removeItem(at: selections)
            let apple = try appleDocument()
            try LyricsCacheFile.encode(document: apple, track: track).write(to: rootURL, atomically: true, encoding: .utf8)
            XCTAssertNotNil(try storage.loadLyrics(for: track)?.appleMusic)
            _ = try storage.saveCandidate(standardDocument(), for: track)
            XCTAssertNotNil(try storage.loadLyrics(for: track)?.appleMusic)
            XCTAssertEqual(try storage.loadLyrics(for: track, family: .standard)?.lines[0].content, "standard")
            let migrated = try XCTUnwrap(storage.loadLyrics(for: track, family: .appleMusic))
            XCTAssertEqual(migrated.localURL?.deletingLastPathComponent().lastPathComponent, "Apple Music")
            XCTAssertEqual(migrated.appleMusic?.ttml, apple.appleMusic?.ttml)
        }
    }

    func testEachFamilySurvivesTrackMetadataChanges() throws {
        try withStorage { storage, track in
            _ = try storage.save(standardDocument(), for: track)
            _ = try storage.save(appleDocument(), for: track)
            var localized = track
            localized.title = "Coral Sea"
            localized.artist = "Jay Chou"
            XCTAssertNotNil(try storage.loadLyrics(for: localized, family: .standard))
            XCTAssertNotNil(try storage.loadLyrics(for: localized, family: .appleMusic))
            XCTAssertNotNil(try storage.loadLyrics(for: localized)?.appleMusic)
        }
    }
}
