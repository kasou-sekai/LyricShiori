import Foundation

struct LyricsCandidateMatcher {
    private static let chineseConversion = FoundationChineseConversionService()

    enum Mode: Equatable {
        /// Used when the app is about to pick a result without asking the user.
        case strictAutomatic
        /// Used by the manual picker: retain candidates and make their relevance visible.
        case rankedManual
    }

    private let request: ShioriLyricsSearchRequest
    private let referenceDocument: LyricsDocument?
    private let mode: Mode
    private let durationTolerance: TimeInterval = 12
    private let firstLineTimeTolerance: TimeInterval = 2.5

    init(
        request: ShioriLyricsSearchRequest,
        referenceDocument: LyricsDocument? = nil,
        mode: Mode = .strictAutomatic
    ) {
        self.request = request
        self.referenceDocument = referenceDocument
        self.mode = mode
    }

    func evaluate(_ result: LyricsSearchResult) -> LyricsSearchResult? {
        let hasMeaningfulLine = firstMeaningfulLine(in: result.document) != nil

        let titleMatches = isBaseTitleMatch(result.title, request.title)
        let durationMatches = isDurationMatch(result.duration, request.duration)
        let artistOrAlbumMatches = isArtistOrAlbumMatch(result)
        let firstLineMatches = isFirstLineMatch(result.document)
        let isStrictMatch = hasMeaningfulLine && titleMatches && durationMatches && artistOrAlbumMatches && firstLineMatches
        guard mode == .rankedManual || isStrictMatch else { return nil }

        var copy = result
        copy.quality = quality(for: result) + relevanceScore(
            titleMatches: titleMatches,
            artistOrAlbumMatches: artistOrAlbumMatches,
            durationMatches: durationMatches,
            firstLineMatches: firstLineMatches,
            result: result
        )
        copy.isMatched = isStrictMatch
        return copy
    }

    func sort(_ lhs: LyricsSearchResult, _ rhs: LyricsSearchResult) -> Bool {
        if lhs.quality != rhs.quality {
            return lhs.quality > rhs.quality
        }
        let lhsDurationDiff = durationDifference(lhs.duration, request.duration)
        let rhsDurationDiff = durationDifference(rhs.duration, request.duration)
        if lhsDurationDiff != rhsDurationDiff {
            return lhsDurationDiff < rhsDurationDiff
        }
        if lhs.provider != rhs.provider {
            return lhs.provider == .qqMusic
        }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }

    private func quality(for result: LyricsSearchResult) -> Double {
        let lines = result.document.lines
        let karaoke = lines.filter { !$0.wordTimings.isEmpty }.count
        let translation = lines.filter { $0.translations["default"]?.isEmpty == false }.count
        let romanization = lines.filter { $0.translations["romanization"]?.isEmpty == false }.count
        let furigana = lines.filter { $0.translations["furigana"]?.isEmpty == false }.count
        let durationScore = max(0, 12 - durationDifference(result.duration, request.duration))
        return Double(karaoke > 0 ? 1_000_000 : 0)
            + Double(furigana > 0 ? 100_000 : 0)
            + Double(translation > 0 ? 10_000 : 0)
            + Double(karaoke * 10)
            + Double(furigana * 5)
            + Double(translation * 3)
            + Double(romanization)
            + durationScore
    }

    private func relevanceScore(
        titleMatches: Bool,
        artistOrAlbumMatches: Bool,
        durationMatches: Bool,
        firstLineMatches: Bool,
        result: LyricsSearchResult
    ) -> Double {
        var score = 0.0
        if titleMatches {
            score += 4_000
        } else if isLooseTextMatch(result.title, request.title) {
            score += 1_500
        }
        if artistOrAlbumMatches { score += 800 }
        if durationMatches { score += 300 }
        if firstLineMatches { score += 200 }
        return score
    }

    private func isBaseTitleMatch(_ candidateTitle: String, _ trackTitle: String) -> Bool {
        let candidate = normalizeBaseTitle(candidateTitle)
        let current = normalizeBaseTitle(trackTitle)
        return !candidate.isEmpty && candidate == current
    }

    private func isDurationMatch(_ candidateDuration: TimeInterval?, _ trackDuration: TimeInterval?) -> Bool {
        guard let candidateDuration, candidateDuration > 0,
              let trackDuration, trackDuration > 0 else {
            return true
        }
        return abs(candidateDuration - trackDuration) <= durationTolerance
    }

    private func durationDifference(_ candidateDuration: TimeInterval?, _ trackDuration: TimeInterval?) -> TimeInterval {
        guard let candidateDuration, candidateDuration > 0,
              let trackDuration, trackDuration > 0 else {
            return 0
        }
        return abs(candidateDuration - trackDuration)
    }

    private func isArtistOrAlbumMatch(_ result: LyricsSearchResult) -> Bool {
        let hasArtist = !request.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasAlbum = !(request.album?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        guard hasArtist || hasAlbum else {
            // A title-only fallback has no artist metadata to validate against.
            // Duration and (when available) the Spotify lyric reference still
            // keep automatic matching appropriately constrained.
            return true
        }
        if isLooseTextMatch(result.artist, request.artist) {
            return true
        }
        let candidateAlbum = result.document.metadata.album ?? ""
        if let album = request.album, !album.isEmpty, isLooseTextMatch(candidateAlbum, album) {
            return true
        }
        return false
    }

    private func firstMeaningfulLine(in document: LyricsDocument) -> LyricsLine? {
        document.lines.first { isMeaningfulLyric($0.content) }
    }

    private func isFirstLineMatch(_ document: LyricsDocument) -> Bool {
        guard let referenceDocument, hasSyncedLyrics(referenceDocument) else {
            return true
        }
        guard let referenceFirst = firstReferenceLine(in: referenceDocument),
              let candidateFirst = firstMeaningfulLine(in: document) else {
            return false
        }
        guard abs(referenceFirst.position - candidateFirst.position) <= firstLineTimeTolerance else {
            return false
        }
        return isCompatibleText(referenceFirst.content, candidateFirst.content)
    }

    private func hasSyncedLyrics(_ document: LyricsDocument) -> Bool {
        document.lines.contains { $0.position > 0 }
    }

    private func firstReferenceLine(in document: LyricsDocument) -> LyricsLine? {
        document.lines.first {
            normalizeLyricText($0.content).count >= 2 && $0.position >= 0
        }
    }

    private func isMeaningfulLyric(_ text: String) -> Bool {
        let normalized = normalizeLyricText(text)
        guard normalized.count >= 2 else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let metadataPattern = #"^(?:作?词|作?曲|编曲|制作人|监制|出品|录音|混音|母带|词版权|曲版权|录音作品|联合出品|人声|吉他|贝斯|鼓|弦乐|和声|OP|SP|纯音乐|instrumental)\s*[:：]?"#
        return trimmed.range(of: metadataPattern, options: [.regularExpression, .caseInsensitive]) == nil
    }

    private func isLooseTextMatch(_ lhs: String, _ rhs: String) -> Bool {
        let first = normalizeLyricText(lhs)
        let second = normalizeLyricText(rhs)
        return !first.isEmpty && !second.isEmpty && (first.contains(second) || second.contains(first))
    }

    private func isCompatibleText(_ lhs: String, _ rhs: String) -> Bool {
        let first = normalizeLyricText(lhs)
        let second = normalizeLyricText(rhs)
        guard !first.isEmpty, !second.isEmpty else { return false }
        if first == second { return true }
        let minLength = min(first.count, second.count)
        guard minLength >= 3 else { return false }
        let longer = max(first.count, second.count)
        guard Double(minLength) >= Double(min(8, longer)) * 0.45 else { return false }
        return first.contains(second) || second.contains(first)
    }

    private func normalizeBaseTitle(_ text: String) -> String {
        normalizeLyricText(baseTrackTitle(text.precomposedStringWithCompatibilityMapping))
    }

    private func baseTrackTitle(_ title: String) -> String {
        title
            .replacingOccurrences(of: #"\s*[[(]?\s*(?:feat(?:uring)?|ft)\.?\s+.*$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s+[-–—]\s*.*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizeLyricText(_ text: String) -> String {
        Self.chineseConversion.convert(text, mode: .simplified)
            .precomposedStringWithCompatibilityMapping
            .lowercased()
            .replacingOccurrences(of: #"\[[^\]]+\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[\s　'’"“”.,!?，。！？、:：;；~～\-—_/\\]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
