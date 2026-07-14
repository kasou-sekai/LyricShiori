import Foundation
import LyricsKit

struct LyricsCacheFile: Codable {
    static let formatIdentifier = "com.lyricshiori.lrcs"
    static let currentVersion = 1

    struct Track: Codable {
        var id: String
        var title: String
        var artist: String
        var album: String?
        var durationMilliseconds: Int?
    }

    struct Word: Codable {
        var startMilliseconds: Int
        var durationMilliseconds: Int?
        var text: String
    }

    struct Line: Codable {
        var startMilliseconds: Int
        var durationMilliseconds: Int?
        var text: String
        var translations: [String: String]
        var words: [Word]
    }

    var format: String
    var version: Int
    var track: Track?
    var source: LyricsCacheSource
    var sourceName: String?
    var offsetMilliseconds: Int
    var desktopLyricsColors: DesktopLyricsColors?
    var lines: [Line]

    init(document: LyricsDocument, track: TrackIdentity?) {
        format = Self.formatIdentifier
        version = Self.currentVersion
        self.track = track.map {
            Track(
                id: $0.id,
                title: $0.title,
                artist: $0.artist,
                album: $0.album,
                durationMilliseconds: $0.duration.map { Int(($0 * 1000).rounded()) }
            )
        }
        source = document.selectionState.cacheSource
        sourceName = document.sourceName
        offsetMilliseconds = document.offsetMilliseconds
        desktopLyricsColors = document.desktopLyricsColors
        lines = document.lines.map { line in
            Line(
                startMilliseconds: Int((line.position * 1000).rounded()),
                durationMilliseconds: nil,
                text: line.content,
                translations: line.translations,
                words: line.wordTimings.map {
                    Word(
                        startMilliseconds: Int(($0.start * 1000).rounded()),
                        durationMilliseconds: $0.duration.map { Int(($0 * 1000).rounded()) },
                        text: $0.text
                    )
                }
            )
        }
    }

    static func encodedString(document: LyricsDocument, track: TrackIdentity?) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Self(document: document, track: track)),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    static func decode(_ content: String, sourceName: String?, localURL: URL?, track: TrackIdentity?) throws -> LyricsDocument {
        let decoder = JSONDecoder()
        let file = try decoder.decode(Self.self, from: Data(content.utf8))
        guard file.format == formatIdentifier, file.version == currentVersion else {
            throw LyricsParserError.invalidLyrics
        }
        if let fileTrack = file.track, let track, fileTrack.id != track.id {
            throw LyricsParserError.invalidLyrics
        }

        let metadataTrack = file.track
        let lines = file.lines.map { line in
            LyricsLine(
                position: TimeInterval(line.startMilliseconds) / 1000,
                content: line.text,
                translations: line.translations,
                wordTimings: line.words.map {
                    WordTiming(
                        start: TimeInterval($0.startMilliseconds) / 1000,
                        duration: $0.durationMilliseconds.map { TimeInterval($0) / 1000 },
                        text: $0.text
                    )
                }
            )
        }
        guard !lines.isEmpty else { throw LyricsParserError.invalidLyrics }

        var document = LyricsDocument(
            metadata: LyricsMetadata(
                title: metadataTrack?.title ?? track?.title,
                artist: metadataTrack?.artist ?? track?.artist,
                album: metadataTrack?.album ?? track?.album,
                languageCode: LyricsLanguageRecognizer.recognize(in: lines.map(\.content).joined(separator: "\n")),
                translationLanguages: Array(Set(lines.flatMap { $0.translations.keys })).sorted(),
                request: nil
            ),
            lines: lines,
            offsetMilliseconds: file.offsetMilliseconds,
            sourceName: file.sourceName ?? sourceName,
            localURL: localURL,
            needsPersist: false,
            desktopLyricsColors: file.desktopLyricsColors
        )
        document.selectionState = .from(cacheSource: file.source)
        return document
    }
}

struct LocalLyricsStorage: LyricsStorageService {
    var baseDirectory: URL
    var isSecurityScoped: Bool

    init(baseDirectory: URL? = nil, isSecurityScoped: Bool = false) {
        self.isSecurityScoped = isSecurityScoped
        if let baseDirectory {
            self.baseDirectory = baseDirectory
        } else {
            self.baseDirectory = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first?
                .appendingPathComponent(Defaults.defaultLyricsDirectoryName, isDirectory: true)
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(Defaults.defaultLyricsDirectoryName, isDirectory: true)
        }
    }

    func candidateURLs(for track: TrackIdentity) -> [URL] {
        [baseDirectory.appendingPathComponent(fileName(for: track)).appendingPathExtension("lrcs")]
    }

    func loadLyrics(for track: TrackIdentity) throws -> LyricsDocument? {
        let accessed = beginSecurityScopeIfNeeded()
        defer { endSecurityScopeIfNeeded(accessed) }

        for url in candidateURLs(for: track) where FileManager.default.fileExists(atPath: url.path) {
            if let document = try loadDocument(at: url, for: track) {
                return document
            }
        }
        return nil
    }

    private func loadDocument(at url: URL, for track: TrackIdentity) throws -> LyricsDocument? {
        let content = try String(contentsOf: url, encoding: .utf8)
        if let decoded = try? LyricsCacheFile.decode(content, sourceName: LyricsProviderID.local.rawValue, localURL: url, track: track) {
            let document = LyricsContentNormalizer.removingLeadingMetadata(from: decoded, track: track)
            guard isMetadataCompatible(document, with: track) else { return nil }
            LyricsBridgeTrace.record(event: "local.lrcs.loaded", document: document, track: track, detail: url.lastPathComponent)
            return document
        }
        return nil
    }

    func save(_ document: LyricsDocument, for track: TrackIdentity) throws -> URL {
        let accessed = beginSecurityScopeIfNeeded()
        defer { endSecurityScopeIfNeeded(accessed) }

        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let url = baseDirectory
            .appendingPathComponent(fileName(for: track))
            .appendingPathExtension("lrcs")
        let normalized = LyricsContentNormalizer.removingLeadingMetadata(from: document, track: track)
        let content = LyricsCacheFile.encodedString(document: normalized, track: track)
        try content.write(to: url, atomically: true, encoding: .utf8)
        LyricsBridgeTrace.record(event: "local.lrcs.saved", document: normalized, track: track, detail: url.lastPathComponent)
        return url
    }

    func importLyrics(from url: URL) throws -> LyricsDocument {
        let content = try String(contentsOf: url, encoding: .utf8)
        var document = try LyricsCacheFile.decode(content, sourceName: LyricsProviderID.local.rawValue, localURL: url, track: nil)
        document.needsPersist = true
        return document
    }

    func export(_ document: LyricsDocument, to url: URL) throws {
        try LyricsCacheFile.encodedString(document: document, track: nil).write(to: url, atomically: true, encoding: .utf8)
    }

    private func isMetadataCompatible(_ document: LyricsDocument, with track: TrackIdentity) -> Bool {
        if let title = document.metadata.title,
           !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !isLooseTextMatch(title, track.title) {
            return false
        }
        if let artist = document.metadata.artist,
           !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !isLooseTextMatch(artist, track.artist) {
            return false
        }
        return true
    }

    private func isLooseTextMatch(_ lhs: String, _ rhs: String) -> Bool {
        let first = normalizedText(lhs)
        let second = normalizedText(rhs)
        return !first.isEmpty && !second.isEmpty && (first == second || first.contains(second) || second.contains(first))
    }

    private func normalizedText(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
            .lowercased()
            .replacingOccurrences(of: #"\[[^\]]+\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[\s　'’"“”.,!?，。！？、:：;；~～\-—_/\\]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sanitize(_ value: String) -> String {
        value.replacingOccurrences(of: "/", with: ":")
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func fileName(for track: TrackIdentity) -> String {
        let title = String(sanitize(track.title).prefix(90))
        let artist = String(sanitize(track.artist).prefix(70))
        let identifier = track.id
            .split(separator: ":")
            .last
            .map(String.init)
            .map(sanitizeIdentifier) ?? "unknown"
        return "\(title) - \(artist) [\(String(identifier.suffix(32)))]"
    }

    private func sanitizeIdentifier(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return value.unicodeScalars
            .map { allowed.contains($0) ? String($0) : "_" }
            .joined()
    }

    private func beginSecurityScopeIfNeeded() -> Bool {
        guard isSecurityScoped else { return false }
        return baseDirectory.startAccessingSecurityScopedResource()
    }

    private func endSecurityScopeIfNeeded(_ accessed: Bool) {
        guard accessed else { return }
        baseDirectory.stopAccessingSecurityScopedResource()
    }
}
