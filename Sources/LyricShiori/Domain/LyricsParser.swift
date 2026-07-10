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
    private static let metadataPattern = #"^\[([a-zA-Z][a-zA-Z-]*):(.*)\]$"#
    private static let attachmentPattern = #"^\[([^\]]+)\](.*)$"#
    private static let inlineTimeTagPattern = #"<(\d+),(\d+)(?:,(\d+))?>"#
    private static let anyInlineTagPattern = #"<[^>]+>"#

    func parse(_ content: String, sourceName: String? = nil, localURL: URL? = nil) throws -> LyricsDocument {
        var metadata = LyricsMetadata(title: nil, artist: nil, album: nil, languageCode: nil, translationLanguages: [], request: nil)
        var offset = 0
        var selectionState: LyricsSelectionState?
        var lines: [LyricsLine] = []
        var indexByPosition: [Int: Int] = [:]
        let timestampRegex = try NSRegularExpression(pattern: Self.timestampPattern)
        let metadataRegex = try NSRegularExpression(pattern: Self.metadataPattern)
        let attachmentRegex = try NSRegularExpression(pattern: Self.attachmentPattern)

        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
            let timestampMatches = timestampRegex.matches(in: line, range: nsRange)

            if timestampMatches.isEmpty {
                parseMetadataLine(line, regex: metadataRegex, metadata: &metadata, offset: &offset, selectionState: &selectionState)
                continue
            }

            let lyricStart = timestampMatches.last?.range.location.advanced(by: timestampMatches.last?.range.length ?? 0) ?? 0
            let contentStart = String.Index(utf16Offset: lyricStart, in: line)
            let lyricContent = String(line[contentStart...])
            let attachment = parseAttachment(lyricContent, regex: attachmentRegex)
            for match in timestampMatches {
                if let position = parseTimestamp(match, in: line) {
                    if let attachment {
                        attach(attachment, toLineAt: position, lines: &lines, indexByPosition: &indexByPosition)
                    } else {
                        let displayContent = stripInlineTags(from: lyricContent)
                        upsertLine(
                            .init(position: position, content: displayContent, translations: [:], wordTimings: parseWordTimings(in: lyricContent, base: position)),
                            lines: &lines,
                            indexByPosition: &indexByPosition
                        )
                    }
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
        if let selectionState {
            document.selectionState = selectionState
        }
        document.metadata.languageCode = LyricsLanguageRecognizer.recognize(in: document.lines.map(\.content).joined(separator: "\n"))
        return LyricsContentNormalizer.removingLeadingMetadata(from: document)
    }

    private func parseMetadataLine(
        _ line: String,
        regex: NSRegularExpression,
        metadata: inout LyricsMetadata,
        offset: inout Int,
        selectionState: inout LyricsSelectionState?
    ) {
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
        case "shiori-source":
            if let cacheSource = LyricsCacheSource(rawValue: value) {
                selectionState = .from(cacheSource: cacheSource)
            }
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

    private func parseAttachment(_ content: String, regex: NSRegularExpression) -> (tag: String, value: String)? {
        let nsRange = NSRange(content.startIndex..<content.endIndex, in: content)
        guard let match = regex.firstMatch(in: content, range: nsRange),
              let tagRange = Range(match.range(at: 1), in: content),
              let valueRange = Range(match.range(at: 2), in: content) else {
            return nil
        }
        return (String(content[tagRange]), String(content[valueRange]))
    }

    private func attach(
        _ attachment: (tag: String, value: String),
        toLineAt position: TimeInterval,
        lines: inout [LyricsLine],
        indexByPosition: inout [Int: Int]
    ) {
        let key = positionKey(position)
        let index: Int
        if let existingIndex = indexByPosition[key] {
            index = existingIndex
        } else {
            index = lines.endIndex
            indexByPosition[key] = index
            lines.append(.init(position: position, content: "", translations: [:], wordTimings: []))
        }

        if attachment.tag == "tt" {
            lines[index].wordTimings = parseInlineTimeTags(attachment.value, base: position)
        } else if attachment.tag == "tr" {
            lines[index].translations["default"] = attachment.value
        } else if attachment.tag.hasPrefix("tr:") {
            let language = String(attachment.tag.dropFirst(3))
            lines[index].translations[language.isEmpty ? "default" : language] = attachment.value
        }
    }

    private func upsertLine(_ line: LyricsLine, lines: inout [LyricsLine], indexByPosition: inout [Int: Int]) {
        let key = positionKey(line.position)
        if let index = indexByPosition[key] {
            lines[index].content = line.content
            if lines[index].wordTimings.isEmpty {
                lines[index].wordTimings = line.wordTimings
            }
        } else {
            indexByPosition[key] = lines.endIndex
            lines.append(line)
        }
    }

    private func positionKey(_ position: TimeInterval) -> Int {
        Int((position * 1000).rounded())
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

    private func parseInlineTimeTags(_ content: String, base: TimeInterval) -> [WordTiming] {
        guard let regex = try? NSRegularExpression(pattern: Self.inlineTimeTagPattern) else { return [] }
        let nsRange = NSRange(content.startIndex..<content.endIndex, in: content)
        let matches = regex.matches(in: content, range: nsRange)
        return matches.enumerated().compactMap { index, match in
            guard let millisecondsRange = Range(match.range(at: 1), in: content),
                  let milliseconds = Double(content[millisecondsRange]) else {
                return nil
            }
            let duration = match.range(at: 3).location == NSNotFound
                ? nil
                : Range(match.range(at: 3), in: content).flatMap { Double(content[$0]).map { $0 / 1000 } }
            let textStart = match.range.location + match.range.length
            let textEnd = index + 1 < matches.count
                ? matches[index + 1].range.location
                : content.utf16.count
            let textRange = NSRange(location: textStart, length: max(0, textEnd - textStart))
            let text = Range(textRange, in: content).map { decodeInlineWordText(String(content[$0])) } ?? ""
            return WordTiming(start: base + milliseconds / 1000, duration: duration, text: text)
        }
    }

    private func decodeInlineWordText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private func stripInlineTags(from content: String) -> String {
        content.replacingOccurrences(of: Self.anyInlineTagPattern, with: "", options: .regularExpression)
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
