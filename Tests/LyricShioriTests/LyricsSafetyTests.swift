import AppKit
import CoreText
import Foundation
import XCTest
@testable import LyricShiori

final class LyricsSafetyTests: XCTestCase {
    func testMenuBarPopoverDismissesOnlyForOutsideClicks() {
        let popoverFrame = NSRect(x: 100, y: 100, width: 240, height: 300)
        let anchorFrame = NSRect(x: 260, y: 400, width: 30, height: 24)

        XCTAssertFalse(MenuBarPopoverDismissalPolicy.shouldDismiss(
            clickLocation: NSPoint(x: 150, y: 150),
            popoverFrame: popoverFrame,
            anchorFrame: anchorFrame
        ))
        XCTAssertFalse(MenuBarPopoverDismissalPolicy.shouldDismiss(
            clickLocation: NSPoint(x: 275, y: 410),
            popoverFrame: popoverFrame,
            anchorFrame: anchorFrame
        ))
        XCTAssertTrue(MenuBarPopoverDismissalPolicy.shouldDismiss(
            clickLocation: NSPoint(x: 20, y: 20),
            popoverFrame: popoverFrame,
            anchorFrame: anchorFrame
        ))
        XCTAssertTrue(MenuBarPopoverDismissalPolicy.shouldDismiss(
            clickLocation: NSPoint(x: 20, y: 20),
            popoverFrame: nil,
            anchorFrame: nil
        ))
    }

    func testDesktopLyricsHideOnHoverAlsoEnablesClickThrough() {
        XCTAssertFalse(DesktopLyricsMousePolicy.ignoresMouseEvents(
            mousePassthrough: false,
            draggable: false,
            hideWhenPointerPasses: true,
            pointerIsInside: false
        ))
        XCTAssertTrue(DesktopLyricsMousePolicy.ignoresMouseEvents(
            mousePassthrough: false,
            draggable: false,
            hideWhenPointerPasses: true,
            pointerIsInside: true
        ))
        XCTAssertTrue(DesktopLyricsMousePolicy.ignoresMouseEvents(
            mousePassthrough: true,
            draggable: false,
            hideWhenPointerPasses: false,
            pointerIsInside: false
        ))
        XCTAssertTrue(DesktopLyricsMousePolicy.ignoresMouseEvents(
            mousePassthrough: false,
            draggable: false,
            hideWhenPointerPasses: false,
            pointerIsInside: false
        ))
        XCTAssertFalse(DesktopLyricsMousePolicy.ignoresMouseEvents(
            mousePassthrough: false,
            draggable: true,
            hideWhenPointerPasses: false,
            pointerIsInside: true
        ))
    }

    func testChineseConversionAndCandidateMatchingAreSimplifiedTraditionalCompatible() {
        let conversion = FoundationChineseConversionService()
        XCTAssertEqual(
            conversion.convert("後臺裏著乾淨頭髮", mode: .simplified),
            "后台里着干净头发"
        )
        XCTAssertEqual(
            conversion.convert("后台里着干净头发", mode: .traditional),
            "後台里著乾淨頭髮"
        )

        let request = ShioriLyricsSearchRequest(
            title: conversion.convert("後來", mode: .simplified),
            artist: conversion.convert("陳奕迅", mode: .simplified),
            album: nil,
            duration: nil,
            limit: 8
        )
        let result = LyricsSearchResult(
            provider: .netease,
            title: "後來",
            artist: "陳奕迅",
            duration: nil,
            document: makeDocument(),
            quality: 0,
            isMatched: false
        )
        let matched = LyricsCandidateMatcher(
            request: request,
            mode: .strictAutomatic
        ).evaluate(result)

        XCTAssertEqual(request.title, "后来")
        XCTAssertEqual(request.artist, "陈奕迅")
        XCTAssertEqual(matched?.isMatched, true)
    }

    func testSearchDraftPrefillsLatePlaybackAndResetsForEachOpening() {
        let first = makeTrack(id: "spotify:track:first")
        var draft = SearchLyricsDraft(track: nil)

        XCTAssertEqual(draft.title, "")
        XCTAssertEqual(draft.artist, "")
        draft.prefill(from: first)
        XCTAssertEqual(draft.title, first.title)
        XCTAssertEqual(draft.artist, first.artist)

        draft.title = "Manual title"
        var second = makeTrack(id: "spotify:track:second")
        second.title = "Second song"
        second.artist = "Second artist"
        draft.prefill(from: second)
        XCTAssertEqual(draft.title, "Manual title")
        XCTAssertEqual(draft.artist, second.artist)

        let reopenedDraft = SearchLyricsDraft(track: second)
        XCTAssertEqual(reopenedDraft.title, second.title)
        XCTAssertEqual(reopenedDraft.artist, second.artist)
    }

    func testWordVerticalTypesetterUsesEastAsianGlyphFormsAndSidewaysWesternRuns() {
        let line = DesktopLyricsDisplayLine(
            id: "vertical-test",
            lineID: UUID(),
            text: "中，don’t Word 2026（）《》！？……",
            wordTimings: [
                WordTiming(
                    start: 0,
                    duration: 5,
                    text: "中，don’t Word 2026（）《》！？……"
                ),
            ],
            lineStart: 0,
            lineEnd: 5,
            playbackTime: 0,
            isPlaying: false,
            isActive: true,
            distanceFromActive: 0,
            progress: 0
        )
        let attributedText = WordVerticalTypesetter.attributedString(
            for: line,
            playbackTime: 0,
            pendingColor: .gray,
            playedColor: .white,
            secondaryColor: .lightGray,
            fontSize: 32
        )
        let verticalFormsKey = NSAttributedString.Key(
            rawValue: kCTVerticalFormsAttributeName as String
        )

        XCTAssertEqual(verticalForm(in: attributedText, character: "中", key: verticalFormsKey), true)
        XCTAssertEqual(verticalForm(in: attributedText, character: "，", key: verticalFormsKey), true)
        XCTAssertEqual(verticalForm(in: attributedText, character: "（", key: verticalFormsKey), true)
        XCTAssertEqual(verticalForm(in: attributedText, character: "《", key: verticalFormsKey), true)
        XCTAssertEqual(verticalForm(in: attributedText, character: "…", key: verticalFormsKey), true)
        XCTAssertEqual(verticalForm(in: attributedText, character: "W", key: verticalFormsKey), false)
        XCTAssertEqual(verticalForm(in: attributedText, character: "2", key: verticalFormsKey), false)
        XCTAssertEqual(verticalForm(in: attributedText, character: "’", key: verticalFormsKey), false)
        let advance = WordVerticalTypesetter.advance(of: attributedText)
        XCTAssertGreaterThan(advance, 1)

        let framesetter = CTFramesetterCreateWithAttributedString(attributedText)
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: 0),
            CGPath(
                rect: CGRect(x: 0, y: 0, width: 32 * 1.58, height: advance),
                transform: nil
            ),
            [
                kCTFrameProgressionAttributeName: NSNumber(value: CTFrameProgression.rightToLeft.rawValue),
            ] as CFDictionary
        )
        XCTAssertEqual(CTFrameGetVisibleStringRange(frame).length, attributedText.length)

        let units = WordVerticalTypesetter.layoutUnits(for: line, fontSize: 32)
        XCTAssertFalse(units.isEmpty)
        XCTAssertTrue(units.filter { !$0.isWhitespace }.allSatisfy { $0.timing != nil })
        XCTAssertTrue(units.contains { $0.attributedText.string == "Word" })
        XCTAssertFalse(units.contains { $0.attributedText.string == "2026" })
        XCTAssertEqual(
            units.map(\.attributedText.string).filter { "2026".contains($0) },
            ["2", "0", "2", "6"]
        )
        for unit in units where !unit.isWhitespace {
            let unitFrame = CTFramesetterCreateFrame(
                CTFramesetterCreateWithAttributedString(unit.attributedText),
                CFRange(location: 0, length: 0),
                CGPath(
                    rect: CGRect(x: 0, y: 0, width: 32 * 1.58, height: unit.advance),
                    transform: nil
                ),
                [
                    kCTFrameProgressionAttributeName: NSNumber(value: CTFrameProgression.rightToLeft.rawValue),
                ] as CFDictionary
            )
            XCTAssertEqual(
                CTFrameGetVisibleStringRange(unitFrame).length,
                unit.attributedText.length
            )
        }

        let start = WordVerticalTypesetter.karaokeTransform(progress: 0, fontSize: 32)
        let peak = WordVerticalTypesetter.karaokeTransform(progress: 0.5, fontSize: 32)
        let end = WordVerticalTypesetter.karaokeTransform(progress: 1, fontSize: 32)
        XCTAssertEqual(start.scale, 1, accuracy: 0.0001)
        XCTAssertEqual(start.lift, 0, accuracy: 0.0001)
        XCTAssertEqual(peak.scale, 1.08, accuracy: 0.0001)
        XCTAssertEqual(peak.lift, 32 * 0.065, accuracy: 0.0001)
        XCTAssertEqual(end.scale, 1, accuracy: 0.0001)
        XCTAssertEqual(end.lift, 0, accuracy: 0.0001)
    }

    func testUpdateVersionComparisonAcceptsTagsAndUnevenComponents() {
        XCTAssertTrue(GitHubUpdateService.isVersion("v0.2.0", newerThan: "0.1.9"))
        XCTAssertTrue(GitHubUpdateService.isVersion("1.2.1", newerThan: "1.2"))
        XCTAssertFalse(GitHubUpdateService.isVersion("v1.2.0", newerThan: "1.2"))
        XCTAssertFalse(GitHubUpdateService.isVersion("v1.2.0-beta.1", newerThan: "1.2.0"))
    }

    func testTimingNormalizerRepairsQQCentisecondsExposedAsSeconds() {
        var document = makeDocument()
        document.lines = [
            LyricsLine(position: 381, content: "First", translations: [:], wordTimings: []),
            LyricsLine(position: 12_404, content: "Last", translations: [:], wordTimings: [
                WordTiming(start: 12_404, duration: 25, text: "Last"),
            ]),
        ]

        let normalized = LyricsTimingNormalizer.normalized(document, expectedDuration: 128)

        XCTAssertEqual(normalized.lines[0].position, 3.81, accuracy: 0.0001)
        XCTAssertEqual(normalized.lines[1].position, 124.04, accuracy: 0.0001)
        XCTAssertEqual(normalized.lines[1].wordTimings[0].start, 124.04, accuracy: 0.0001)
        XCTAssertEqual(normalized.lines[1].wordTimings[0].duration, 0.25)
    }

    func testTimingNormalizerLeavesPlausibleTimelineUntouched() {
        var document = makeDocument()
        document.lines = [
            LyricsLine(position: 3.81, content: "First", translations: [:], wordTimings: []),
            LyricsLine(position: 124.04, content: "Last", translations: [:], wordTimings: []),
        ]

        XCTAssertEqual(
            LyricsTimingNormalizer.normalized(document, expectedDuration: 128),
            document
        )
    }

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

    private func verticalForm(
        in text: NSAttributedString,
        character: String,
        key: NSAttributedString.Key
    ) -> Bool? {
        let range = (text.string as NSString).range(of: character)
        guard range.location != NSNotFound else { return nil }
        return (text.attribute(key, at: range.location, effectiveRange: nil) as? NSNumber)?.boolValue
    }
}
