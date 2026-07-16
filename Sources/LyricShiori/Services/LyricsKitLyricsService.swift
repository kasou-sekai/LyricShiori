import Foundation
import LyricsKit

@MainActor
final class LyricsKitLyricsService: LyricsSearchService {
    let providerID: LyricsProviderID
    private let provider: LyricsProvider
    private let translationRecoveryCandidateLimit = 4

    init(providerID: LyricsProviderID) {
        self.providerID = providerID
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        let httpClient = URLSessionHTTPClient(session: URLSession(configuration: configuration))
        switch providerID {
        case .netease:
            self.provider = LyricsProviders.Service.netease.create(httpClient: httpClient)
        case .qqMusic:
            self.provider = LyricsProviders.Service.qq.create(httpClient: httpClient)
        case .local:
            fatalError("Local lyrics are loaded through LocalLyricsStorage.")
        }
    }

    func search(_ request: ShioriLyricsSearchRequest) async throws -> [LyricsSearchResult] {
        let kitRequest = LyricsKit.LyricsSearchRequest(
            searchTerm: .info(title: request.title, artist: request.artist),
            duration: request.duration ?? 0,
            limit: request.limit
        )
        var results: [LyricsSearchResult] = []
        var attemptedTranslationRecoveries = 0
        var qqMusicIDs: [String: String]?
        for try await lyrics in provider.lyrics(for: kitRequest) {
            guard var document = Self.convert(lyrics, providerID: providerID) else {
                continue
            }
            document = LyricsTimingNormalizer.normalized(
                document,
                expectedDuration: request.duration
            )
            if providerID == .qqMusic,
               needsTranslationRecovery(document),
               attemptedTranslationRecoveries < translationRecoveryCandidateLimit,
               let songMID = lyrics.metadata.serviceToken {
                if qqMusicIDs == nil {
                    qqMusicIDs = await QQMusicTranslationRecovery.songIDs(for: request)
                }
                let songIDs = qqMusicIDs ?? [:]
                if let songID = songIDs[songMID] {
                    attemptedTranslationRecoveries += 1
                    if let recoveredTranslations = await QQMusicTranslationRecovery.translations(for: songID) {
                        document = QQMusicTranslationRecovery.applying(
                            recoveredTranslations,
                            to: document
                        )
                    }
                }
            }
            results.append(
                LyricsSearchResult(
                    provider: providerID,
                    title: lyrics.idTags[.title] ?? request.title,
                    artist: lyrics.idTags[.artist] ?? request.artist,
                    duration: lyrics.length,
                    document: document,
                    quality: lyrics.quality,
                    isMatched: lyrics.isMatched()
                )
            )
        }
        return results
    }

    private func needsTranslationRecovery(_ document: LyricsDocument) -> Bool {
        let translatedLineCount = document.lines.count {
            !($0.translations["default"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
        return translatedLineCount > 0 && translatedLineCount < document.lines.count
    }

    nonisolated static func convert(_ lyrics: LyricsKit.Lyrics, providerID: LyricsProviderID) -> LyricsDocument? {
        guard !lyrics.lines.isEmpty else {
            return nil
        }

        let lines = lyrics.lines.map { line in
            var translations: [String: String] = [:]
            if let translation = line.attachments.translation() {
                translations["default"] = cleanTranslation(translation)
            }
            return LyricsLine(
                position: line.position,
                content: line.content,
                translations: translations,
                wordTimings: wordTimings(from: line)
            )
        }

        var document = LyricsDocument(
            metadata: LyricsMetadata(
                title: lyrics.idTags[.title],
                artist: lyrics.idTags[.artist],
                album: lyrics.idTags[.album],
                languageCode: nil,
                translationLanguages: lines.contains(where: { !$0.translations.isEmpty }) ? ["default"] : [],
                request: nil
            ),
            lines: lines,
            offsetMilliseconds: lyrics.offset,
            sourceName: providerID.rawValue,
            localURL: nil,
            needsPersist: false
        )
        document.metadata.languageCode = LyricsLanguageRecognizer.recognize(in: lines.map(\.content).joined(separator: "\n"))
        return LyricsContentNormalizer.removingLeadingMetadata(from: document)
    }

    private nonisolated static func cleanTranslation(_ value: String) -> String {
        // Some QQ responses contain an extra closing bracket immediately after
        // a timestamp (for example `[04:07.58]]translation`). The timestamp
        // parser has already consumed the first bracket, so do not surface the
        // remaining one as part of the translated lyric.
        var cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix("]") {
            cleaned.removeFirst()
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleaned
    }

    private nonisolated static func wordTimings(from line: LyricsKit.LyricsLine) -> [WordTiming] {
        guard let timeTag = line.attachments.timetag else {
            return []
        }
        return wordTimings(
            content: line.content,
            linePosition: line.position,
            tags: timeTag.tags.map { ($0.index, $0.time) },
            lineDuration: timeTag.duration
        )
    }

    nonisolated static func wordTimings(
        content: String,
        linePosition: TimeInterval,
        tags: [(index: Int, time: TimeInterval)],
        lineDuration: TimeInterval?
    ) -> [WordTiming] {
        let characterCount = content.count
        let boundaries = tags
            .filter { (0...characterCount).contains($0.index) && $0.time >= 0 }
            .sorted { lhs, rhs in
                lhs.index == rhs.index ? lhs.time < rhs.time : lhs.index < rhs.index
            }
        guard !boundaries.isEmpty else { return [] }

        return boundaries.indices.compactMap { index -> WordTiming? in
            let boundary = boundaries[index]
            let nextIndex = index + 1 < boundaries.count
                ? boundaries[index + 1].index
                : characterCount
            guard nextIndex > boundary.index else { return nil }
            let start = content.index(content.startIndex, offsetBy: boundary.index)
            let end = content.index(content.startIndex, offsetBy: nextIndex)
            let text = String(content[start..<end])
            guard !text.isEmpty else { return nil }

            let nextTime = index + 1 < boundaries.count
                ? boundaries[index + 1].time
                : lineDuration
            let duration = nextTime.flatMap { $0 > boundary.time ? $0 - boundary.time : nil }
            return WordTiming(
                start: linePosition + boundary.time,
                duration: duration,
                text: text
            )
        }
    }
}
