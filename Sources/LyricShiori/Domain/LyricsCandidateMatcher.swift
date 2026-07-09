import Foundation

struct LyricsCandidateMatcher {
    private let request: ShioriLyricsSearchRequest
    private let durationTolerance: TimeInterval = 12

    init(request: ShioriLyricsSearchRequest) {
        self.request = request
    }

    func evaluate(_ result: LyricsSearchResult) -> LyricsSearchResult? {
        guard isBaseTitleMatch(result.title, request.title) else { return nil }
        guard isDurationMatch(result.duration, request.duration) else { return nil }
        guard isArtistOrAlbumMatch(result) else { return nil }
        guard firstMeaningfulLine(in: result.document) != nil else { return nil }

        var copy = result
        copy.quality = quality(for: result)
        copy.isMatched = true
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
        text.precomposedStringWithCompatibilityMapping
            .lowercased()
            .replacingOccurrences(of: #"\[[^\]]+\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[\s　'’"“”.,!?，。！？、:：;；~～\-—_/\\]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
