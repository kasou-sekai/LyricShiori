import Foundation

/// The original TTML is authoritative. Unknown Apple extensions, ruby, styling,
/// translations and future effects survive even when a renderer cannot use them.
struct AppleMusicTimedText: Codable, Equatable, Sendable {
    var version: Int = 1
    var ttml: String
    var catalogDurationMilliseconds: Int? = nil
    var catalogID: String?
    var storefront: String?
}

struct TimedTextElement: Codable, Equatable, Sendable {
    var name: String
    var attributes: [String: String]
    var text: String?
    var children: [TimedTextElement]

    var content: String { text ?? children.map(\.content).joined() }

    func attribute(_ localName: String) -> String? {
        attributes[localName] ?? attributes.sorted { $0.key < $1.key }
            .first { $0.key.split(separator: ":").last.map(String.init) == localName }?.value
    }
}

struct LyricsLinePresentation: Codable, Equatable, Sendable {
    enum Alignment: String, Codable, Sendable { case left, center, right }
    var key: String?
    var agent: String?
    var alignment: Alignment?
    var isBackground: Bool
    var parentKey: String?
    /// Seconds, absolute in the song, like LyricsLine.position / WordTiming.start.
    var end: TimeInterval?
    var element: TimedTextElement
}

struct AppleMusicTTMLParser {
    func parse(_ ttml: String, catalogID: String? = nil, storefront: String? = nil) throws -> LyricsDocument {
        guard ttml.utf8.count <= LyricsResourceLimits.maximumFileBytes,
              !ttml.localizedCaseInsensitiveContains("<!DOCTYPE"),
              !ttml.localizedCaseInsensitiveContains("<!ENTITY") else { throw LyricsParserError.invalidLyrics }
        let delegate = TTMLTreeBuilder()
        let parser = XMLParser(data: Data(ttml.utf8))
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), let root = delegate.root, root.name == "tt" else { throw LyricsParserError.invalidLyrics }
        var lines: [LyricsLine] = []
        var agents: [String] = []
        var styles: [String: TimedTextElement] = [:]
        var translations: [String: [String: String]] = [:]
        func collectTranslations(_ node: TimedTextElement, language: String? = nil) {
            let language = node.attribute("lang") ?? language
            if node.name == "text", let key = node.attribute("for"), let language {
                translations[key, default: [:]][language] = node.content.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            node.children.forEach { collectTranslations($0, language: language) }
        }
        for head in root.children where head.name == "head" { collectTranslations(head) }
        func collect(_ node: TimedTextElement) {
            if node.name == "agent", let id = node.attribute("id") { agents.append(id) }
            if ["style", "region"].contains(node.name), let id = node.attribute("id") { styles[id] = node }
            node.children.forEach(collect)
        }
        collect(root)
        func validateTimes(_ node: TimedTextElement) throws {
            for key in ["begin", "end", "dur"] {
                if let value = node.attribute(key), Self.time(value) == nil { throw LyricsParserError.invalidLyrics }
            }
            if let begin = node.attribute("begin").flatMap(Self.time),
               let end = node.attribute("end").flatMap(Self.time), end < begin { throw LyricsParserError.invalidLyrics }
            try node.children.forEach(validateTimes)
        }
        try validateTimes(root)
        func alignment(_ node: TimedTextElement, inherited: LyricsLinePresentation.Alignment?) -> LyricsLinePresentation.Alignment? {
            let refs = [node.attribute("style"), node.attribute("region")].compactMap { $0 }
                .flatMap { $0.split(separator: " ").map(String.init) }
            let value = node.attribute("textAlign") ?? refs.compactMap { styles[$0]?.attribute("textAlign") }.last
            switch value {
            case "right", "end": return .right
            case "left", "start": return .left
            case "center": return .center
            default: return inherited
            }
        }
        func interval(_ node: TimedTextElement, start: Double, end: Double?) -> (Double, Double?) {
            let begin = node.attribute("begin").flatMap(Self.time) ?? start
            let finish = node.attribute("end").flatMap(Self.time)
                ?? node.attribute("dur").flatMap(Self.time).map { begin + $0 } ?? end
            return (begin, finish)
        }
        func visit(_ node: TimedTextElement, start: Double, end: Double?, inheritedAgent: String?, inheritedAlignment: LyricsLinePresentation.Alignment?) {
            let (begin, finish) = interval(node, start: start, end: end)
            let agent = node.attribute("agent") ?? inheritedAgent
            let align = alignment(node, inherited: inheritedAlignment)
            if node.name == "p" {
                let key = node.attribute("key") ?? "line-\(lines.count)"
                let resolvedAlignment = align ?? (agent != nil && agents.count > 1 && agent == agents[1] ? .right : .left)
                func append(_ element: TimedTextElement, background: Bool, parent: String?) {
                    let (lineStart, lineEnd) = interval(element, start: begin, end: finish)
                    var text = ""
                    var words: [WordTiming] = []
                    func flatten(_ item: TimedTextElement, start: Double, end: Double?) {
                        if let value = item.text {
                            // Ignore XML indentation, while retaining actual word spaces.
                            if value.allSatisfy(\.isWhitespace), value.contains("\n") { return }
                            text += value
                            return
                        }
                        if item.name == "br" { text += "\n"; return }
                        if item.attribute("role") == "x-bg" && !background { return }
                        // Ruby readings are preserved in the tree; they must not be
                        // inserted into the sung text or shift word character ranges.
                        if ["text", "textContainer", "delimiter"].contains(item.attribute("ruby") ?? "") { return }
                        let (s, e) = interval(item, start: start, end: end)
                        let before = text.count
                        let wordCount = words.count
                        item.children.forEach { flatten($0, start: s, end: e) }
                        if words.count == wordCount, text.count > before, item.attribute("begin") != nil {
                            words.append(WordTiming(start: s, duration: e.map { max(0, $0 - s) }, text: String(text.dropFirst(before))))
                        }
                    }
                    flatten(element, start: lineStart, end: lineEnd)
                    words = Self.preservingUntimedText(words, content: text)
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    let resolvedStart = background && element.attribute("begin") == nil
                        ? words.map(\.start).min() ?? lineStart : lineStart
                    let resolvedEnd = background && element.attribute("end") == nil
                        ? words.compactMap { word in word.duration.map { word.start + $0 } }.max() ?? lineEnd : lineEnd
                    lines.append(LyricsLine(position: resolvedStart, content: text, translations: background ? [:] : translations[key] ?? [:], wordTimings: words,
                        presentation: LyricsLinePresentation(key: background ? nil : key, agent: element.attribute("agent") ?? agent,
                            alignment: resolvedAlignment, isBackground: background, parentKey: parent, end: resolvedEnd, element: element)))
                }
                append(node, background: false, parent: nil)
                func backgrounds(_ item: TimedTextElement) {
                    for child in item.children {
                        if child.attribute("role") == "x-bg" { append(child, background: true, parent: key) }
                        else { backgrounds(child) }
                    }
                }
                backgrounds(node)
                return
            }
            node.children.forEach { visit($0, start: begin, end: finish, inheritedAgent: agent, inheritedAlignment: align) }
        }
        // Only body contains sung paragraphs; metadata can also contain <p>.
        for body in root.children where body.name == "body" {
            visit(body, start: 0, end: nil, inheritedAgent: nil, inheritedAlignment: nil)
        }
        lines = lines.enumerated().sorted { $0.element.position == $1.element.position ? $0.offset < $1.offset : $0.element.position < $1.element.position }.map(\.element)
        guard !lines.isEmpty else { throw LyricsParserError.invalidLyrics }
        let document = LyricsDocument(metadata: LyricsMetadata(title: nil, artist: nil, album: nil,
            languageCode: root.attribute("lang"), translationLanguages: Array(Set(translations.values.flatMap { $0.keys })).sorted(), request: nil), lines: lines,
            offsetMilliseconds: 0, sourceName: LyricsProviderID.appleMusic.rawValue, localURL: nil, needsPersist: false,
            appleMusic: AppleMusicTimedText(ttml: ttml, catalogID: catalogID, storefront: storefront))
        try LyricsResourceLimits.validate(document)
        return document
    }

    /// Apple places spaces and punctuation between timed spans. Attach these
    /// literal gaps to adjacent syllables without changing their timestamps.
    /// Also used when loading caches written before gap preservation.
    static func preservingUntimedText(_ words: [WordTiming], content: String) -> [WordTiming] {
        guard !words.isEmpty, words.map(\.text).joined() != content else { return words }
        var ranges: [Range<String.Index>] = []
        var cursor = content.startIndex
        for word in words {
            guard !word.text.isEmpty,
                  let range = content.range(of: word.text, range: cursor..<content.endIndex) else { return words }
            ranges.append(range)
            cursor = range.upperBound
        }
        return words.enumerated().map { index, word in
            var result = word
            let start = index == 0 ? content.startIndex : ranges[index].lowerBound
            let end = index + 1 < ranges.count ? ranges[index + 1].lowerBound : content.endIndex
            result.text = String(content[start..<end])
            return result
        }
    }

    static func time(_ value: String) -> TimeInterval? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let number: Double?
        if value.hasSuffix("ms") { number = Double(value.dropLast(2)).map { $0 / 1000 } }
        else if value.hasSuffix("s") { number = Double(value.dropLast()) }
        else if value.hasSuffix("m") { number = Double(value.dropLast()).map { $0 * 60 } }
        else if value.hasSuffix("h") { number = Double(value.dropLast()).map { $0 * 3600 } }
        else {
            let parts = value.split(separator: ":", omittingEmptySubsequences: false)
            guard (1...3).contains(parts.count) else { return nil }
            var total = 0.0
            for part in parts {
                guard let component = Double(part), component.isFinite, component >= 0 else { return nil }
                total = total * 60 + component
            }
            number = total
        }
        guard let number, number >= 0, LyricsResourceLimits.validMilliseconds(number * 1000) else { return nil }
        return number
    }
}

private final class TTMLTreeBuilder: NSObject, XMLParserDelegate {
    var root: TimedTextElement?
    private var stack: [TimedTextElement] = []
    private var count = 0
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        count += 1
        guard count <= 100_000, stack.count < 64 else { parser.abortParsing(); return }
        stack.append(TimedTextElement(name: elementName.split(separator: ":").last.map(String.init) ?? elementName, attributes: attributeDict, children: []))
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !stack.isEmpty else { return }
        if stack[stack.count - 1].children.last?.name == "#text" {
            stack[stack.count - 1].children[stack[stack.count - 1].children.count - 1].text! += string
        } else {
            stack[stack.count - 1].children.append(TimedTextElement(name: "#text", attributes: [:], text: string, children: []))
        }
    }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let text = String(data: CDATABlock, encoding: .utf8) else { parser.abortParsing(); return }
        self.parser(parser, foundCharacters: text)
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard let node = stack.popLast() else { return }
        if stack.isEmpty { root = node } else { stack[stack.count - 1].children.append(node) }
    }
}
