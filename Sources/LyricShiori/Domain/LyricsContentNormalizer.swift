import Foundation

enum LyricsContentNormalizer {
    private static let creditPattern = #"^(?:作?词|作?曲|编曲|制作人|监制|出品|录音|混音|母带|词版权|曲版权|录音作品|联合出品|人声|吉他|贝斯|鼓|弦乐|和声|OP|SP|纯音乐|instrumental)\s*[:：]?"#

    static func removingLeadingMetadata(from document: LyricsDocument, track: TrackIdentity? = nil) -> LyricsDocument {
        let identities = identityTexts(for: document, track: track)
        guard let firstLyricIndex = document.lines.firstIndex(where: {
            isMeaningfulLyric($0.content) && !matchesIdentity($0.content, identities: identities)
        }), firstLyricIndex > document.lines.startIndex else {
            return document
        }

        var copy = document
        copy.lines = Array(document.lines[firstLyricIndex...])
        copy.metadata.languageCode = LyricsLanguageRecognizer.recognize(in: copy.lines.map(\.content).joined(separator: "\n"))
        return copy
    }

    private static func identityTexts(for document: LyricsDocument, track: TrackIdentity?) -> Set<String> {
        let values = [
            document.metadata.title,
            document.metadata.artist,
            document.metadata.album,
            track?.title,
            track?.artist,
            track?.album,
        ]
        .compactMap { $0 }
        .map(normalizedText)
        .filter { !$0.isEmpty }

        var identities = Set(values)
        if let title = values.first, values.count > 1 {
            for artist in values.dropFirst() {
                identities.insert(title + artist)
                identities.insert(artist + title)
            }
        }
        return identities
    }

    private static func isMeaningfulLyric(_ text: String) -> Bool {
        let normalized = normalizedText(text)
        guard normalized.count >= 2 else { return false }
        return text.range(of: creditPattern, options: [.regularExpression, .caseInsensitive]) == nil
    }

    private static func matchesIdentity(_ text: String, identities: Set<String>) -> Bool {
        let normalized = normalizedText(text)
        return !normalized.isEmpty && identities.contains(normalized)
    }

    private static func normalizedText(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
            .lowercased()
            .replacingOccurrences(of: #"\[[^\]]+\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[\s　'’\"“”.,!?，。！？、:：;；~～\-—_/\\]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
