import Foundation
import XCTest
@testable import LyricShiori

final class LyricsSafetyTests: XCTestCase {
    func testLocalLyricsUseLRCSAndTrackIdentityInFilename() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = LocalLyricsStorage(baseDirectory: directory)
        let track = makeTrack(id: "spotify:track:track-one")
        let url = try storage.save(makeDocument(), for: track)

        XCTAssertEqual(url.pathExtension, "lrcs")
        XCTAssertTrue(url.deletingPathExtension().lastPathComponent.contains("track-one"))
        XCTAssertNotNil(try storage.loadLyrics(for: track))
        XCTAssertNil(try storage.loadLyrics(for: makeTrack(id: "spotify:track:track-two")))
    }

    func testManualSearchKeepsWeaklyRelatedProviderResult() {
        let request = ShioriLyricsSearchRequest(
            title: "Expected Song",
            artist: "Expected Artist",
            album: nil,
            duration: 200,
            limit: 50
        )
        let result = LyricsSearchResult(
            provider: .netease,
            title: "Completely Different",
            artist: "Someone Else",
            duration: 400,
            document: makeDocument(),
            quality: 0,
            isMatched: false
        )

        XCTAssertNotNil(LyricsCandidateMatcher(request: request, mode: .rankedManual).evaluate(result))
        XCTAssertNil(LyricsCandidateMatcher(request: request, mode: .strictAutomatic).evaluate(result))
    }

    func testManualCacheEntryCannotBeOverwrittenByPluginResult() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SharedLyricsCache(url: directory.appendingPathComponent("cache.json"))
        let trackURI = "spotify:track:protected"
        let now = Int64((Date().timeIntervalSince1970 * 1_000).rounded())

        XCTAssertSaveResult(try cache.save(makeEntry(trackURI: trackURI, cachedAt: now, source: .plugin)), .saved)
        XCTAssertSaveResult(try cache.save(makeEntry(trackURI: trackURI, cachedAt: now + 1, source: .manual)), .saved)
        XCTAssertSaveResult(try cache.save(makeEntry(trackURI: trackURI, cachedAt: now + 2, source: .plugin)), .rejected)
        XCTAssertEqual(try cache.entry(trackUri: trackURI, kind: .enhanced)?.cacheSource, .manual)
    }

    func testCorruptSharedCacheIsQuarantinedAndRecovered() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("cache.json")
        try Data("not-json".utf8).write(to: url)
        let cache = SharedLyricsCache(url: url)

        XCTAssertNil(try cache.entry(trackUri: "spotify:track:missing", kind: .enhanced))
        let quarantined = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertTrue(quarantined.contains { $0.lastPathComponent.contains("corrupt-") })
    }

    private func makeTrack(id: String) -> TrackIdentity {
        TrackIdentity(
            id: id,
            title: "A / Song",
            artist: "An Artist",
            album: "Album",
            duration: 200,
            albumArtworkURL: nil,
            localFileURL: nil,
            embeddedLyrics: nil
        )
    }

    private func makeDocument() -> LyricsDocument {
        var document = LyricsDocument(
            metadata: LyricsMetadata(
                title: "A Song",
                artist: "An Artist",
                album: "Album",
                languageCode: "en",
                translationLanguages: [],
                request: nil
            ),
            lines: [LyricsLine(
                position: 1,
                content: "A meaningful lyric line",
                translations: [:],
                wordTimings: []
            )],
            offsetMilliseconds: 0,
            sourceName: "Test",
            localURL: nil,
            needsPersist: true
        )
        document.selectionState = LyricsSelectionState.manual(origin: .manualSelection)
        return document
    }

    private func makeEntry(
        trackURI: String,
        cachedAt: Int64,
        source: LyricsCacheSource
    ) -> SharedLyricsCache.Entry {
        SharedLyricsCache.Entry(
            kind: .enhanced,
            trackUri: trackURI,
            cachedAt: cachedAt,
            expiresAt: cachedAt + 60_000,
            lines: [.init(
                time: 1_000,
                text: "Line \(cachedAt)",
                translation: nil,
                romanization: nil,
                furigana: nil,
                words: nil,
                duration: nil
            )],
            metadata: .init(
                title: "Song",
                artist: "Artist",
                album: nil,
                languageCode: nil,
                translationLanguages: []
            ),
            cacheSource: source,
            source: source == .plugin ? .plugin : .lyricShiori,
            sourceName: "Test",
            isManualSelection: source == .manual,
            cachedWithoutPlugin: source == .withoutPlugin,
            offsetMilliseconds: 0,
            timingOffsetApplied: false,
            hidden: false,
            desktopLyricsColors: nil,
            debug: nil
        )
    }

    private func XCTAssertSaveResult(
        _ actual: SharedLyricsCache.SaveResult,
        _ expected: SharedLyricsCache.SaveResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch (actual, expected) {
        case (.saved, .saved), (.unchanged, .unchanged), (.rejected, .rejected):
            break
        default:
            XCTFail("Unexpected save result", file: file, line: line)
        }
    }
}
