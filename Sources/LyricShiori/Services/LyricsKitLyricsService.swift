import Foundation
import LyricsKit

@MainActor
final class LyricsKitLyricsService: LyricsSearchService {
    let providerID: LyricsProviderID
    private let provider: LyricsProvider

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

        var results: [LyricsSearchResult] = []
        for try await lyrics in provider.lyrics(for: kitRequest) {
            guard let document = Self.convert(lyrics, providerID: providerID) else {
                continue
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

    private static func convert(_ lyrics: LyricsKit.Lyrics, providerID: LyricsProviderID) -> LyricsDocument? {
        guard !lyrics.lines.isEmpty else {
            return nil
        }

        let lines = lyrics.lines.map { line in
            var translations: [String: String] = [:]
            if let translation = line.attachments.translation() {
                translations["default"] = translation
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
        return document
    }

    private static func wordTimings(from line: LyricsKit.LyricsLine) -> [WordTiming] {
        guard let timeTag = line.attachments.timetag else {
            return []
        }
        return timeTag.tags.map { tag in
            WordTiming(start: line.position + tag.time, duration: nil, text: "")
        }
    }
}
