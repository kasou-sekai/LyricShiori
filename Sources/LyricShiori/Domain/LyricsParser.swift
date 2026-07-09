import Foundation

enum LyricsParserError: LocalizedError {
    case invalidLyrics

    var errorDescription: String? {
        switch self {
        case .invalidLyrics:
            "Invalid lyric file"
        }
    }
}

struct LyricsParser {
    private static let timestampPattern = #"\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#
    private static let metadataPattern = #"^\[([a-zA-Z]+):(.*)\]$"#

    func parse(_ content: String, sourceName: String? = nil, localURL: URL? = nil) throws -> LyricsDocument {
        var metadata = LyricsMetadata(title: nil, artist: nil, album: nil, languageCode: nil, translationLanguages: [], request: nil)
        var offset = 0
        var lines: [LyricsLine] = []
        let timestampRegex = try NSRegularExpression(pattern: Self.timestampPattern)
        let metadataRegex = try NSRegularExpression(pattern: Self.metadataPattern)

        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
            let timestampMatches = timestampRegex.matches(in: line, range: nsRange)

            if timestampMatches.isEmpty {
                parseMetadataLine(line, regex: metadataRegex, metadata: &metadata, offset: &offset)
                continue
            }

            let lyricStart = timestampMatches.last?.range.location.advanced(by: timestampMatches.last?.range.length ?? 0) ?? 0
            let contentStart = String.Index(utf16Offset: lyricStart, in: line)
            let lyricContent = String(line[contentStart...])
            for match in timestampMatches {
                if let position = parseTimestamp(match, in: line) {
                    lines.append(.init(position: position, content: lyricContent, translations: [:], wordTimings: parseWordTimings(in: lyricContent, base: position)))
                }
            }
        }

        let sorted = lines
            .filter { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.position < $1.position }

        guard !sorted.isEmpty else {
            throw LyricsParserError.invalidLyrics
        }

        var document = LyricsDocument(
            metadata: metadata,
            lines: sorted,
            offsetMilliseconds: offset,
            sourceName: sourceName,
            localURL: localURL,
            needsPersist: false
        )
        document.metadata.languageCode = LyricsLanguageRecognizer.recognize(in: document.lines.map(\.content).joined(separator: "\n"))
        return document
    }

    private func parseMetadataLine(_ line: String, regex: NSRegularExpression, metadata: inout LyricsMetadata, offset: inout Int) {
        let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: nsRange),
              let keyRange = Range(match.range(at: 1), in: line),
              let valueRange = Range(match.range(at: 2), in: line) else {
            return
        }

        let key = String(line[keyRange]).lowercased()
        let value = String(line[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        switch key {
        case "ti", "title":
            metadata.title = value
        case "ar", "artist":
            metadata.artist = value
        case "al", "album":
            metadata.album = value
        case "offset":
            offset = Int(value) ?? 0
        case "lang", "language":
            metadata.languageCode = value
        default:
            break
        }
    }

    private func parseTimestamp(_ match: NSTextCheckingResult, in line: String) -> TimeInterval? {
        guard let minutesRange = Range(match.range(at: 1), in: line),
              let secondsRange = Range(match.range(at: 2), in: line),
              let minutes = Double(line[minutesRange]),
              let seconds = Double(line[secondsRange]) else {
            return nil
        }

        var fraction = 0.0
        if match.range(at: 3).location != NSNotFound,
           let fractionRange = Range(match.range(at: 3), in: line) {
            let text = String(line[fractionRange])
            let denominator = pow(10.0, Double(text.count))
            fraction = (Double(text) ?? 0) / denominator
        }

        return minutes * 60 + seconds + fraction
    }

    private func parseWordTimings(in content: String, base: TimeInterval) -> [WordTiming] {
        guard content.contains("<") else { return [] }
        let pattern = #"<(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?>([^<]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(content.startIndex..<content.endIndex, in: content)
        return regex.matches(in: content, range: nsRange).compactMap { match in
            guard let timing = parseTimestamp(match, in: content),
                  let textRange = Range(match.range(at: 4), in: content) else {
                return nil
            }
            return WordTiming(start: max(base, timing), duration: nil, text: String(content[textRange]))
        }
    }
}

enum LyricsLanguageRecognizer {
    static func recognize(in text: String) -> String? {
        if text.range(of: #"\p{Han}"#, options: .regularExpression) != nil {
            return "zh"
        }
        if text.range(of: #"\p{Hiragana}|\p{Katakana}"#, options: .regularExpression) != nil {
            return "ja"
        }
        if text.range(of: #"\p{Hangul}"#, options: .regularExpression) != nil {
            return "ko"
        }
        return Locale.current.language.languageCode?.identifier
    }
}

