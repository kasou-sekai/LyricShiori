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

    init(document: LyricsDocument, track: TrackIdentity?) throws {
        try LyricsResourceLimits.validate(document)
        guard track?.duration.map({ LyricsResourceLimits.validMilliseconds($0 * 1_000) }) != false else {
            throw LyricsParserError.invalidLyrics
        }
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
        (try? encode(document: document, track: track)) ?? "{}"
    }

    static func encode(document: LyricsDocument, track: TrackIdentity?) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Self(document: document, track: track))
        guard data.count <= LyricsResourceLimits.maximumFileBytes,
              let string = String(data: data, encoding: .utf8) else { throw LyricsParserError.invalidLyrics }
        return string
    }

    static func decode(_ content: String, sourceName: String?, localURL: URL?, track: TrackIdentity?) throws -> LyricsDocument {
        guard content.utf8.count <= LyricsResourceLimits.maximumFileBytes else { throw LyricsParserError.invalidLyrics }
        let decoder = JSONDecoder()
        let file = try decoder.decode(Self.self, from: Data(content.utf8))
        guard file.format == formatIdentifier, file.version == currentVersion else {
            throw LyricsParserError.invalidLyrics
        }
        if let fileTrack = file.track, let track, fileTrack.id != track.id {
            throw LyricsParserError.invalidLyrics
        }

        guard file.lines.count <= 5_000,
              LyricsResourceLimits.validMilliseconds(Double(file.offsetMilliseconds)),
              file.lines.allSatisfy({ line in
                  LyricsResourceLimits.validMilliseconds(Double(line.startMilliseconds))
                      && line.text.utf8.count <= 16_384
                      && line.translations.count <= 64
                      && line.translations.allSatisfy { $0.key.utf8.count <= 256 && $0.value.utf8.count <= 16_384 }
                      && line.words.count <= 2_000
                      && line.words.allSatisfy {
                          LyricsResourceLimits.validMilliseconds(Double($0.startMilliseconds))
                              && $0.durationMilliseconds.map { LyricsResourceLimits.validMilliseconds(Double($0)) } != false
                              && $0.text.utf8.count <= 16_384
                      }
              }) else { throw LyricsParserError.invalidLyrics }
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

struct LocalLyricsStorage: LyricsStorageService, Sendable {
    private static let documentCache = LocalLyricsDocumentCache()
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
        let canonical = baseDirectory.appendingPathComponent(fileName(for: track)).appendingPathExtension("lrcs")
        let identifier = track.id
            .split(separator: ":")
            .last
            .map(String.init)
            .map(sanitizeIdentifier) ?? "unknown"
        let suffix = "[\(String(identifier.suffix(32)))].lrcs"
        let existing = (try? FileManager.default.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))?
            .filter { $0.pathExtension == "lrcs" && $0.lastPathComponent.hasSuffix(suffix) }
            .filter { $0 != canonical }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
        return [canonical] + existing
    }

    func loadLyrics(for track: TrackIdentity) throws -> LyricsDocument? {
        let accessed = beginSecurityScopeIfNeeded()
        defer { endSecurityScopeIfNeeded(accessed) }

        let canonical = baseDirectory.appendingPathComponent(fileName(for: track)).appendingPathExtension("lrcs")
        if FileManager.default.fileExists(atPath: canonical.path),
           let document = try loadDocument(at: canonical, for: track) { return document }
        for url in candidateURLs(for: track).dropFirst() where FileManager.default.fileExists(atPath: url.path) {
            if let document = try loadDocument(at: url, for: track) {
                return document
            }
        }
        return nil
    }

    private func loadDocument(at url: URL, for track: TrackIdentity) throws -> LyricsDocument? {
        try Self.documentCache.load(url: url, track: track) {
            let content = try LyricsResourceLimits.readText(at: url)
            guard let decoded = try? LyricsCacheFile.decode(content, sourceName: LyricsProviderID.local.rawValue, localURL: url, track: track) else { return nil }
            let document = LyricsContentNormalizer.removingLeadingMetadata(from: decoded, track: track)
            LyricsBridgeTrace.record(event: "local.lrcs.loaded", document: document, track: track, detail: url.lastPathComponent)
            return document
        }
    }

    func save(_ document: LyricsDocument, for track: TrackIdentity) throws -> URL {
        let accessed = beginSecurityScopeIfNeeded()
        defer { endSecurityScopeIfNeeded(accessed) }

        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let url = baseDirectory
            .appendingPathComponent(fileName(for: track))
            .appendingPathExtension("lrcs")
        let normalized = LyricsContentNormalizer.removingLeadingMetadata(from: document, track: track)
        let content = try LyricsCacheFile.encode(document: normalized, track: track)
        try content.write(to: url, atomically: true, encoding: .utf8)
        LyricsBridgeTrace.record(event: "local.lrcs.saved", document: normalized, track: track, detail: url.lastPathComponent)
        return url
    }

    /// Removes the persisted choice for a track so it can return to automatic
    /// lyric discovery. Imported source files are left untouched; only the
    /// LRCS copy managed by LyricShiori is removed.
    func removeLyrics(for track: TrackIdentity) throws {
        let accessed = beginSecurityScopeIfNeeded()
        defer { endSecurityScopeIfNeeded(accessed) }

        for url in candidateURLs(for: track) where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func importLyrics(from url: URL) throws -> LyricsDocument {
        let content = try LyricsResourceLimits.readText(at: url)
        var document = try LyricsCacheFile.decode(content, sourceName: LyricsProviderID.local.rawValue, localURL: url, track: nil)
        document.needsPersist = true
        return document
    }

    func export(_ document: LyricsDocument, to url: URL) throws {
        try LyricsCacheFile.encode(document: document, track: nil).write(to: url, atomically: true, encoding: .utf8)
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

/// File identity and dates invalidate both atomic replacements and in-place edits.
/// The lock coalesces simultaneous bridge requests for the same file.
private final class LocalLyricsDocumentCache: @unchecked Sendable {
    private struct Key: Hashable { var url: URL; var track: TrackIdentity }
    private struct Stamp: Equatable {
        var size: UInt64
        var modified: Date?
        var created: Date?
        var inode: UInt64
        init(_ attributes: [FileAttributeKey: Any]) {
            size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            modified = attributes[.modificationDate] as? Date
            created = attributes[.creationDate] as? Date
            inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        }
    }
    private let lock = NSLock()
    private var entries: [Key: (Stamp, LyricsDocument)] = [:]

    func load(url: URL, track: TrackIdentity, read: () throws -> LyricsDocument?) throws -> LyricsDocument? {
        try lock.withLock {
            let key = Key(url: url, track: track)
            let stamp = Stamp(try FileManager.default.attributesOfItem(atPath: url.path))
            if let cached = entries[key], cached.0 == stamp { return cached.1 }
            entries[key] = nil
            guard let document = try read() else { return nil }
            // Avoid caching a read across an external write.
            if stamp == Stamp(try FileManager.default.attributesOfItem(atPath: url.path)) {
                if entries.count >= 4 { entries.removeAll(keepingCapacity: true) }
                entries[key] = (stamp, document)
            }
            return document
        }
    }
}
