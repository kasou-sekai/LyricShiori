import CryptoKit
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
        var presentation: LyricsLinePresentation? = nil
    }

    var format: String
    var version: Int
    var track: Track?
    var source: LyricsCacheSource
    var sourceName: String?
    var offsetMilliseconds: Int
    var desktopLyricsColors: DesktopLyricsColors?
    var lines: [Line]
    var appleMusic: AppleMusicTimedText? = nil

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
        appleMusic = document.appleMusic
        desktopLyricsColors = document.desktopLyricsColors
        lines = document.lines.map { line in
            Line(
                startMilliseconds: Int((line.position * 1000).rounded()),
                durationMilliseconds: line.presentation?.end.map { Int((($0 - line.position) * 1000).rounded()) },
                text: line.content,
                translations: line.translations,
                words: line.wordTimings.map {
                    Word(
                        startMilliseconds: Int(($0.start * 1000).rounded()),
                        durationMilliseconds: $0.duration.map { Int(($0 * 1000).rounded()) },
                        text: $0.text
                    )
                },
                presentation: line.presentation
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
            var decoded = LyricsLine(
                position: TimeInterval(line.startMilliseconds) / 1000,
                content: line.text,
                translations: line.translations,
                wordTimings: line.words.map {
                    WordTiming(
                        start: TimeInterval($0.startMilliseconds) / 1000,
                        duration: $0.durationMilliseconds.map { TimeInterval($0) / 1000 },
                        text: $0.text
                    )
                },
                presentation: line.presentation
            )
            if line.presentation != nil {
                decoded.wordTimings = AppleMusicTTMLParser.preservingUntimedText(decoded.wordTimings, content: decoded.content)
            }
            return decoded
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
            desktopLyricsColors: file.desktopLyricsColors,
            appleMusic: file.appleMusic
        )
        document.selectionState = .from(cacheSource: file.source)
        try LyricsResourceLimits.validate(document)
        return document
    }
}

/// Independent storage slots; playback/bridge selection is separate from acquisition.
enum LyricsStorageFamily: String, Codable, CaseIterable, Sendable {
    case standard
    case appleMusic = "apple-music"

    init(document: LyricsDocument) {
        self = document.appleMusic != nil || document.lines.contains(where: { $0.presentation != nil })
            || document.sourceName == LyricsProviderID.appleMusic.rawValue ? .appleMusic : .standard
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

    private struct Selection: Codable {
        var trackID: String
        var family: LyricsStorageFamily
    }

    private func directory(for family: LyricsStorageFamily) -> URL {
        family == .appleMusic ? baseDirectory.appendingPathComponent("Apple Music", isDirectory: true) : baseDirectory
    }

    private func selectionURL(for track: TrackIdentity) -> URL {
        let digest = SHA256.hash(data: Data(track.id.utf8)).map { String(format: "%02x", $0) }.joined()
        return baseDirectory.appendingPathComponent("Selections", isDirectory: true)
            .appendingPathComponent(digest).appendingPathExtension("json")
    }

    func candidateURLs(for track: TrackIdentity) -> [URL] {
        LyricsStorageFamily.allCases.flatMap { candidateURLs(for: track, in: $0) }
    }

    private func candidateURLs(for track: TrackIdentity, in family: LyricsStorageFamily) -> [URL] {
        let directory = directory(for: family)
        let canonical = directory.appendingPathComponent(fileName(for: track)).appendingPathExtension("lrcs")
        let identifier = track.id.split(separator: ":").last.map(String.init).map(sanitizeIdentifier) ?? "unknown"
        let suffix = "[\(String(identifier.suffix(32)))].lrcs"
        let existing = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ))?.filter { $0.pathExtension == "lrcs" && $0.lastPathComponent.hasSuffix(suffix) && $0 != canonical }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
        return [canonical] + existing
    }

    func loadLyrics(for track: TrackIdentity) throws -> LyricsDocument? {
        let accessed = beginSecurityScopeIfNeeded()
        defer { endSecurityScopeIfNeeded(accessed) }
        if let data = try? LyricsResourceLimits.readText(at: selectionURL(for: track)),
           let selection = try? JSONDecoder().decode(Selection.self, from: Data(data.utf8)),
           selection.trackID == track.id,
           let document = try loadLyrics(for: track, family: selection.family) { return document }
        return try loadLyrics(for: track, family: .standard) ?? loadLyrics(for: track, family: .appleMusic)
    }

    /// Explicit source access is used by the bridge, independent of desktop choice.
    func loadLyrics(for track: TrackIdentity, family: LyricsStorageFamily) throws -> LyricsDocument? {
        let accessed = beginSecurityScopeIfNeeded()
        defer { endSecurityScopeIfNeeded(accessed) }
        var candidates = candidateURLs(for: track, in: family)
        // Earlier builds stored Apple Music in the root directory. Read it until
        // the next write migrates it without discarding the other source slot.
        if family == .appleMusic { candidates += candidateURLs(for: track, in: .standard) }
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            if let document = try loadDocument(at: url, for: track), LyricsStorageFamily(document: document) == family {
                return document
            }
        }
        return nil
    }

    func select(_ family: LyricsStorageFamily, for track: TrackIdentity) throws {
        let accessed = beginSecurityScopeIfNeeded()
        defer { endSecurityScopeIfNeeded(accessed) }
        let url = selectionURL(for: track)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Selection(trackID: track.id, family: family)).write(to: url, options: .atomic)
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
        let url = try saveCandidate(document, for: track)
        try select(LyricsStorageFamily(document: document), for: track)
        return url
    }

    /// Downloading another source must not change the active source selection.
    @discardableResult
    func saveCandidate(_ document: LyricsDocument, for track: TrackIdentity, preservingManualSelection: Bool = false) throws -> URL {
        let accessed = beginSecurityScopeIfNeeded()
        defer { endSecurityScopeIfNeeded(accessed) }
        try migrateLegacyAppleMusic(for: track)
        let family = LyricsStorageFamily(document: document)
        if preservingManualSelection, let existing = try loadLyrics(for: track, family: family),
           existing.selectionState.isManualSelection, let url = existing.localURL { return url }
        let directory = directory(for: family)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName(for: track)).appendingPathExtension("lrcs")
        let normalized = LyricsContentNormalizer.removingLeadingMetadata(from: document, track: track)
        try LyricsCacheFile.encode(document: normalized, track: track).write(to: url, atomically: true, encoding: .utf8)
        LyricsBridgeTrace.record(event: "local.lrcs.saved", document: normalized, track: track, detail: url.lastPathComponent)
        return url
    }

    private func migrateLegacyAppleMusic(for track: TrackIdentity) throws {
        for oldURL in candidateURLs(for: track, in: .standard) where FileManager.default.fileExists(atPath: oldURL.path) {
            guard let document = try loadDocument(at: oldURL, for: track),
                  LyricsStorageFamily(document: document) == .appleMusic else { continue }
            let directory = directory(for: .appleMusic)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var newURL = directory.appendingPathComponent(oldURL.lastPathComponent)
            if FileManager.default.fileExists(atPath: newURL.path) {
                // Preserve both files if a newer Apple Music variant already exists.
                newURL = directory.appendingPathComponent("Legacy \(UUID().uuidString) \(oldURL.lastPathComponent)")
            }
            try FileManager.default.copyItem(at: oldURL, to: newURL)
            if !FileManager.default.fileExists(atPath: selectionURL(for: track).path) {
                try select(.appleMusic, for: track)
            }
            try FileManager.default.removeItem(at: oldURL)
        }
    }

    /// Reset removes both source slots and the current choice for this track.
    func removeLyrics(for track: TrackIdentity) throws {
        let accessed = beginSecurityScopeIfNeeded()
        defer { endSecurityScopeIfNeeded(accessed) }
        for url in candidateURLs(for: track) + [selectionURL(for: track)] where FileManager.default.fileExists(atPath: url.path) {
            // Match the embedded full track identity before deleting suffix matches.
            if url.pathExtension == "lrcs", try loadDocument(at: url, for: track) == nil { continue }
            try FileManager.default.removeItem(at: url)
        }
    }

    func importLyrics(from url: URL) throws -> LyricsDocument {
        let content = try LyricsResourceLimits.readText(at: url)
        var document = content.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<")
            ? try LyricsParser().parse(content, localURL: url)
            : try LyricsCacheFile.decode(content, sourceName: LyricsProviderID.local.rawValue, localURL: url, track: nil)
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
