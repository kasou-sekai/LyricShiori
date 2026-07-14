import Foundation
import LyricsKit

@MainActor
final class LyricsKitLyricsService: LyricsSearchService {
    let providerID: LyricsProviderID
    private let provider: LyricsProvider
    private let translationRecoveryCandidateLimit = 4

    init(providerID: LyricsProviderID) {
        self.providerID = providerID
        switch providerID {
        case .netease:
            self.provider = LyricsProviders.Service.netease.create()
        case .qqMusic:
            self.provider = LyricsProviders.Service.qq.create()
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
        async let qqMusicIDs: [String: String] = providerID == .qqMusic
            ? QQMusicTranslationRecovery.songIDs(for: request)
            : [:]

        var results: [LyricsSearchResult] = []
        var attemptedTranslationRecoveries = 0
        for try await lyrics in provider.lyrics(for: kitRequest) {
            guard var document = Self.convert(lyrics, providerID: providerID) else {
                continue
            }
            if providerID == .qqMusic,
               needsTranslationRecovery(document),
               attemptedTranslationRecoveries < translationRecoveryCandidateLimit,
               let songMID = lyrics.metadata.serviceToken {
                let songIDs = await qqMusicIDs
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
        return timeTag.tags.map { tag in
            WordTiming(start: line.position + tag.time, duration: nil, text: "")
        }
    }
}
