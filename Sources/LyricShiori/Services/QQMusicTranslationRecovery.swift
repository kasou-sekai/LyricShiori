import Foundation

/// Recovers QQ Music translations that LyricsKit cannot merge when the two
/// lyric streams use timestamps that differ by a few milliseconds. QQ's QRC
/// lyrics frequently differ from its accompanying LRC translation by 25–50ms,
/// while LyricsKit's internal merge tolerance is 20ms.
enum QQMusicTranslationRecovery {
    struct TimestampedTranslation: Equatable {
        var position: TimeInterval
        var text: String
    }

    private static let recoveryTolerance: TimeInterval = 0.08

    static func songIDs(for request: ShioriLyricsSearchRequest) async -> [String: String] {
        var components = URLComponents(string: "https://c.y.qq.com/splcloud/fcgi-bin/smartbox_new.fcg")
        let searchTerm = [request.title, request.artist]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: " ")
        components?.queryItems = [URLQueryItem(name: "key", value: searchTerm)]
        guard let url = components?.url else {
            return [:]
        }
        var lookup = URLRequest(url: url)
        lookup.timeoutInterval = 2
        guard let (data, response) = try? await URLSession.shared.data(for: lookup),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(SearchResponse.self, from: data) else {
            return [:]
        }
        return decoded.data.song.itemlist.reduce(into: [:]) { ids, song in
            ids[song.mid] = song.id
        }
    }

    static func translations(for songID: String) async -> [TimestampedTranslation]? {
        guard let url = URL(string: "https://c.y.qq.com/qqmusic/fcgi-bin/lyric_download.fcg") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 2
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("https://c.y.qq.com/", forHTTPHeaderField: "Referer")
        request.httpBody = "musicid=\(songID)&version=15&miniversion=82&lrctype=4".data(using: .utf8)

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let body = String(data: data, encoding: .utf8),
              let content = translationContent(in: body) else {
            return nil
        }

        let parsed = parseTranslations(in: content)
        return parsed.isEmpty ? nil : parsed
    }

    static func applying(
        _ recoveredTranslations: [TimestampedTranslation],
        to document: LyricsDocument
    ) -> LyricsDocument {
        guard !recoveredTranslations.isEmpty else { return document }

        var copy = document
        var usedLineIndices = Set<Int>()
        for translation in recoveredTranslations {
            guard let index = closestUntranslatedLine(
                to: translation.position,
                in: copy.lines,
                excluding: usedLineIndices
            ) else {
                continue
            }
            copy.lines[index].translations["default"] = translation.text
            usedLineIndices.insert(index)
        }
        copy.metadata.translationLanguages = Array(
            Set(copy.lines.flatMap { $0.translations.keys })
        ).sorted()
        return copy
    }

    private static func closestUntranslatedLine(
        to position: TimeInterval,
        in lines: [LyricsLine],
        excluding excluded: Set<Int>
    ) -> Int? {
        lines.indices
            .filter { index in
                !excluded.contains(index)
                    && (lines[index].translations["default"]?.isEmpty ?? true)
            }
            .min { lhs, rhs in
                abs(lines[lhs].position - position) < abs(lines[rhs].position - position)
            }
            .flatMap { index in
                abs(lines[index].position - position) <= recoveryTolerance ? index : nil
            }
    }

    private static func translationContent(in response: String) -> String? {
        let pattern = #"<contentts\b[^>]*>\s*<!\[CDATA\[(.*?)\]\]>\s*</contentts>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(
                in: response,
                range: NSRange(response.startIndex..<response.endIndex, in: response)
              ),
              let range = Range(match.range(at: 1), in: response) else {
            return nil
        }
        return String(response[range])
    }

    private static func parseTranslations(in content: String) -> [TimestampedTranslation] {
        content.components(separatedBy: .newlines).flatMap { line -> [TimestampedTranslation] in
            let matches = timestampPattern.matches(
                in: line,
                range: NSRange(line.startIndex..<line.endIndex, in: line)
            )
            let timestamps = timestamps(from: matches, in: line)
            guard !timestamps.isEmpty,
                  let finalTimestamp = matches.last,
                  let textRange = Range(
                    NSRange(
                        location: finalTimestamp.range.location + finalTimestamp.range.length,
                        length: max(0, (line as NSString).length - finalTimestamp.range.location - finalTimestamp.range.length)
                    ),
                    in: line
                  ) else {
                return []
            }
            let text = cleanTranslation(String(line[textRange]))
            guard !text.isEmpty, text != "//" else { return [] }
            return timestamps.map { TimestampedTranslation(position: $0, text: text) }
        }
    }

    private static func timestamps(
        from matches: [NSTextCheckingResult],
        in line: String
    ) -> [TimeInterval] {
        matches.compactMap { match in
            guard let minutesRange = Range(match.range(at: 1), in: line),
                  let secondsRange = Range(match.range(at: 2), in: line),
                  let minutes = Double(line[minutesRange]),
                  let seconds = Double(line[secondsRange]) else {
                return nil
            }
            let fraction: Double
            if match.range(at: 3).location != NSNotFound,
               let fractionRange = Range(match.range(at: 3), in: line) {
                let rawFraction = String(line[fractionRange])
                fraction = (Double(rawFraction) ?? 0) / pow(10, Double(rawFraction.count))
            } else {
                fraction = 0
            }
            return minutes * 60 + seconds + fraction
        }
    }

    private static func cleanTranslation(_ value: String) -> String {
        var cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix("]") {
            cleaned.removeFirst()
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleaned
    }

    private static let timestampPattern = try! NSRegularExpression(
        pattern: #"\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#
    )

    private struct SearchResponse: Decodable {
        var data: Data

        struct Data: Decodable {
            var song: Song

            struct Song: Decodable {
                var itemlist: [Item]
            }
        }

        struct Item: Decodable {
            var id: String
            var mid: String
        }
    }
}
