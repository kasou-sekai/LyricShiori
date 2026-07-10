import Foundation
import Network

final class SharedLyricsCache: @unchecked Sendable {
    enum Kind: String, CaseIterable, Codable {
        case spotify
        case enhanced
        case enhancedRelaxed = "enhanced-relaxed"
    }

    struct Store: Codable {
        var version: Int
        var entries: [String: Entry]
    }

    struct Entry: Codable {
        var kind: Kind
        var trackUri: String
        var cachedAt: Int64
        var expiresAt: Int64
        var lines: [Line]
        var metadata: Metadata?
        var cacheSource: LyricsCacheSource?
        var source: Source?
        var sourceName: String?
        var isManualSelection: Bool?
        var cachedWithoutPlugin: Bool?
        var offsetMilliseconds: Int?
        var timingOffsetApplied: Bool?
        var debug: AnyCodableValue?
    }

    struct Metadata: Codable {
        var title: String?
        var artist: String?
        var album: String?
        var languageCode: String?
        var translationLanguages: [String]?
    }

    enum Source: String, Codable {
        case plugin
        case lyricShiori = "lyric-shiori"
        case unknown
    }

    struct Line: Codable {
        var time: Double?
        var text: String
        var translation: String?
        var romanization: String?
        var furigana: String?
        var words: [Word]?
        var duration: Double?
    }

    struct Word: Codable {
        var time: Double
        var duration: Double
        var text: String
    }

    private let url: URL
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private let cacheVersion = 9
    private let readyTTL: Int64 = 14 * 24 * 60 * 60 * 1000
    private let emptyTTL: Int64 = 30 * 60 * 1000
    private let maxEntries = 80

    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music/\(Defaults.defaultLyricsDirectoryName)", isDirectory: true)
            .appendingPathComponent("full-screen-lyrics-cache-v9.json")
    }

    func loadDocument(for track: TrackIdentity) throws -> LyricsDocument? {
        guard isSpotifyTrack(track.id) else { return nil }
        if let manual = try firstDocument(for: track, matching: { effectiveCacheSource(for: $0) == .manual }) {
            return manual
        }
        if let plugin = try firstDocument(for: track, matching: { isPluginEntry($0) }) {
            return plugin
        }
        for kind in preferredKinds {
            if let document = try loadDocument(for: track, kind: kind) { return document }
        }
        return nil
    }

    func loadManualDocument(for track: TrackIdentity) throws -> LyricsDocument? {
        try firstDocument(for: track) { effectiveCacheSource(for: $0) == .manual }
    }

    func loadPluginDocument(for track: TrackIdentity) throws -> LyricsDocument? {
        try firstDocument(for: track) { isPluginEntry($0) }
    }

    func loadAutomaticDocument(for track: TrackIdentity) throws -> LyricsDocument? {
        try firstDocument(for: track) {
            effectiveCacheSource(for: $0) != .manual && !isPluginEntry($0)
        }
    }

    func loadDocument(for track: TrackIdentity, kind: Kind) throws -> LyricsDocument? {
        guard isSpotifyTrack(track.id),
              let entry = try entry(trackUri: track.id, kind: kind),
              !entry.lines.isEmpty,
              isEntryCompatible(entry, with: track) else {
            return nil
        }
        return document(from: entry, track: track)
    }

    func save(_ document: LyricsDocument, for track: TrackIdentity) throws {
        try save(
            document,
            for: track,
            source: source(for: document),
            sourceName: document.sourceName,
            isManualSelection: document.selectionState.isManualSelection,
            cachedWithoutPlugin: document.selectionState.cachedWithoutPlugin
        )
    }

    func save(
        _ document: LyricsDocument,
        for track: TrackIdentity,
        source: Source,
        sourceName: String?,
        isManualSelection: Bool,
        cachedWithoutPlugin: Bool
    ) throws {
        guard isSpotifyTrack(track.id) else { return }
        let lines = lines(from: document)
        guard !lines.isEmpty else { return }
        let now = nowMilliseconds()
        for kind in [Kind.enhanced, .enhancedRelaxed] {
            try save(
                Entry(
                    kind: kind,
                    trackUri: track.id,
                    cachedAt: now,
                    expiresAt: now + readyTTL,
                    lines: lines,
                    metadata: Metadata(
                        title: document.metadata.title ?? track.title,
                        artist: document.metadata.artist ?? track.artist,
                        album: document.metadata.album ?? track.album,
                        languageCode: document.metadata.languageCode,
                        translationLanguages: document.metadata.translationLanguages
                    ),
                    cacheSource: document.selectionState.cacheSource,
                    source: source,
                    sourceName: sourceName,
                    isManualSelection: isManualSelection,
                    cachedWithoutPlugin: cachedWithoutPlugin,
                    offsetMilliseconds: document.offsetMilliseconds,
                    timingOffsetApplied: false,
                    debug: nil
                )
            )
        }
    }

    func entry(trackUri: String, kind: Kind) throws -> Entry? {
        lock.lock()
        defer { lock.unlock() }

        var store = try loadStore()
        removeExpiredEntries(from: &store)
        let key = cacheKey(trackUri: trackUri, kind: kind)
        guard let entry = store.entries[key], entry.expiresAt > nowMilliseconds() else {
            store.entries.removeValue(forKey: key)
            try persist(store)
            return nil
        }
        return entry
    }

    func save(_ entry: Entry) throws {
        lock.lock()
        defer { lock.unlock() }

        var store = try loadStore()
        removeExpiredEntries(from: &store)
        let key = cacheKey(trackUri: entry.trackUri, kind: entry.kind)
        if effectiveCacheSource(for: store.entries[key]) == .manual,
           effectiveCacheSource(for: entry) != .manual {
            try persist(store)
            return
        }
        store.entries[key] = entry
        trim(&store)
        try persist(store)
    }

    func encodedEntry(trackUri: String, kind: Kind) throws -> Data? {
        guard let entry = try entry(trackUri: trackUri, kind: kind) else { return nil }
        return try encoder.encode(entry)
    }

    func encodedPreferredEntry(trackUri: String, kind: Kind) throws -> Data? {
        guard let entry = try entry(trackUri: trackUri, kind: kind),
              isSharedBridgePreferred(entry) else {
            return nil
        }
        return try encoder.encode(entry)
    }

    func encodedEntry(_ document: LyricsDocument, for track: TrackIdentity, kind: Kind) throws -> Data? {
        let entry = entry(from: document, for: track, kind: kind)
        guard !entry.lines.isEmpty, isSharedBridgePreferred(entry) else { return nil }
        return try encoder.encode(entry)
    }

    @discardableResult
    func saveEncodedEntry(_ data: Data) throws -> Entry {
        let entry = try decoder.decode(Entry.self, from: data)
        try save(entry)
        return entry
    }

    func localPersistenceDocument(from entry: Entry) -> (track: TrackIdentity, document: LyricsDocument)? {
        guard let track = trackIdentity(from: entry), !entry.lines.isEmpty else { return nil }
        return (track, document(from: entry, track: track))
    }

    func localPersistenceDocuments() throws -> [(track: TrackIdentity, document: LyricsDocument)] {
        lock.lock()
        defer { lock.unlock() }

        var store = try loadStore()
        removeExpiredEntries(from: &store)
        var bestEntries: [String: Entry] = [:]
        for entry in store.entries.values where !entry.lines.isEmpty {
            guard trackIdentity(from: entry) != nil else { continue }
            if let existing = bestEntries[entry.trackUri],
               compareLocalPersistencePriority(entry, existing) <= 0 {
                continue
            }
            bestEntries[entry.trackUri] = entry
        }
        try persist(store)
        return bestEntries.values.compactMap { localPersistenceDocument(from: $0) }
    }

    private func document(from entry: Entry, track: TrackIdentity) -> LyricsDocument {
        let lines = entry.lines.compactMap { line -> LyricsLine? in
            guard let time = line.time else { return nil }
            var translations: [String: String] = [:]
            if let translation = line.translation, !translation.isEmpty {
                translations["default"] = translation
            }
            if let romanization = line.romanization, !romanization.isEmpty {
                translations["romanization"] = romanization
            }
            if let furigana = line.furigana, !furigana.isEmpty {
                translations["furigana"] = furigana
            }
            return LyricsLine(
                position: time / 1000,
                content: line.text,
                translations: translations,
                wordTimings: (line.words ?? []).map {
                    WordTiming(start: $0.time / 1000, duration: $0.duration / 1000, text: $0.text)
                }
            )
        }
        var document = LyricsDocument(
            metadata: LyricsMetadata(
                title: entry.metadata?.title ?? track.title,
                artist: entry.metadata?.artist ?? track.artist,
                album: entry.metadata?.album ?? track.album,
                languageCode: entry.metadata?.languageCode ?? LyricsLanguageRecognizer.recognize(in: lines.map(\.content).joined(separator: "\n")),
                translationLanguages: entry.metadata?.translationLanguages ?? (lines.contains(where: { !$0.translations.isEmpty }) ? ["default"] : []),
                request: nil
            ),
            lines: lines,
            offsetMilliseconds: entry.timingOffsetApplied == true ? 0 : (entry.offsetMilliseconds ?? 0),
            sourceName: entry.sourceName ?? defaultSourceName(for: entry),
            localURL: url,
            needsPersist: false
        )
        document.selectionState = selectionState(from: entry)
        document.metadata.languageCode = LyricsLanguageRecognizer.recognize(in: lines.map(\.content).joined(separator: "\n"))
        return document
    }

    private func entry(from document: LyricsDocument, for track: TrackIdentity, kind: Kind) -> Entry {
        let now = nowMilliseconds()
        return Entry(
            kind: kind,
            trackUri: track.id,
            cachedAt: now,
            expiresAt: now + readyTTL,
            lines: lines(from: document),
            metadata: Metadata(
                title: document.metadata.title ?? track.title,
                artist: document.metadata.artist ?? track.artist,
                album: document.metadata.album ?? track.album,
                languageCode: document.metadata.languageCode,
                translationLanguages: document.metadata.translationLanguages
            ),
            cacheSource: document.selectionState.cacheSource,
            source: source(for: document),
            sourceName: document.sourceName,
            isManualSelection: document.selectionState.isManualSelection,
            cachedWithoutPlugin: document.selectionState.cachedWithoutPlugin,
            offsetMilliseconds: document.offsetMilliseconds,
            timingOffsetApplied: false,
            debug: nil
        )
    }

    private func lines(from document: LyricsDocument) -> [Line] {
        document.lines.compactMap { line in
            let content = line.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return nil }
            let words = line.wordTimings
                .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return Line(
                time: line.position * 1000,
                text: content,
                translation: line.translations["default"],
                romanization: line.translations["romanization"],
                furigana: line.translations["furigana"],
                words: words.isEmpty ? nil : words.map {
                    Word(
                        time: $0.start * 1000,
                        duration: ($0.duration ?? 0) * 1000,
                        text: $0.text
                    )
                },
                duration: nil
            )
        }
    }

    private var preferredKinds: [Kind] {
        [.enhanced, .enhancedRelaxed, .spotify]
    }

    private func trackIdentity(from entry: Entry) -> TrackIdentity? {
        let title = entry.metadata?.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let artist = entry.metadata?.artist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard isSpotifyTrack(entry.trackUri), !title.isEmpty, !artist.isEmpty else {
            return nil
        }
        return TrackIdentity(
            id: entry.trackUri,
            title: title,
            artist: artist,
            album: entry.metadata?.album,
            duration: nil,
            albumArtworkURL: nil,
            localFileURL: nil,
            embeddedLyrics: nil
        )
    }

    private func compareLocalPersistencePriority(_ lhs: Entry, _ rhs: Entry) -> Int {
        let sourceScore = localPersistenceSourceScore(lhs) - localPersistenceSourceScore(rhs)
        if sourceScore != 0 { return sourceScore }
        let kindScore = localPersistenceKindScore(lhs.kind) - localPersistenceKindScore(rhs.kind)
        if kindScore != 0 { return kindScore }
        let lineScore = lhs.lines.count - rhs.lines.count
        if lineScore != 0 { return lineScore }
        return Int(lhs.cachedAt - rhs.cachedAt)
    }

    private func localPersistenceSourceScore(_ entry: Entry) -> Int {
        switch effectiveCacheSource(for: entry) {
        case .manual:
            return 3
        case .plugin:
            return 2
        case .withoutPlugin:
            return 1
        }
    }

    private func localPersistenceKindScore(_ kind: Kind) -> Int {
        switch kind {
        case .enhanced:
            return 3
        case .enhancedRelaxed:
            return 2
        case .spotify:
            return 1
        }
    }

    private func firstDocument(for track: TrackIdentity, matching predicate: (Entry) -> Bool) throws -> LyricsDocument? {
        guard isSpotifyTrack(track.id) else { return nil }
        for kind in preferredKinds {
            guard let entry = try entry(trackUri: track.id, kind: kind),
                  !entry.lines.isEmpty,
                  isEntryCompatible(entry, with: track),
                  predicate(entry) else {
                continue
            }
            return document(from: entry, track: track)
        }
        return nil
    }

    private func selectionState(from entry: Entry) -> LyricsSelectionState {
        switch effectiveCacheSource(for: entry) {
        case .manual:
            return .manual(origin: .manualSelection)
        case .plugin:
            return entry.kind == .spotify
                ? LyricsSelectionState(isManualSelection: false, origin: .spotify, cachedWithoutPlugin: false)
                : .plugin
        case .withoutPlugin:
            return .automaticSearch(cachedWithoutPlugin: true)
        }
    }

    private func defaultSourceName(for entry: Entry) -> String {
        if effectiveCacheSource(for: entry) == .manual {
            return "Manual Shared Cache"
        }
        if isPluginEntry(entry) {
            return entry.kind == .spotify ? "Spotify Shared Cache" : "Full-Screen Shared Cache"
        }
        return "LyricShiori Shared Cache"
    }

    private func isPluginEntry(_ entry: Entry) -> Bool {
        effectiveCacheSource(for: entry) == .plugin
    }

    private func isSharedBridgePreferred(_ entry: Entry) -> Bool {
        switch effectiveCacheSource(for: entry) {
        case .manual, .plugin:
            return true
        case .withoutPlugin:
            return false
        }
    }

    private func effectiveCacheSource(for entry: Entry?) -> LyricsCacheSource {
        guard let entry else { return .withoutPlugin }
        if let cacheSource = entry.cacheSource {
            return cacheSource
        }
        if entry.isManualSelection == true {
            return .manual
        }
        if entry.source == .plugin || (entry.source == nil && entry.kind == .spotify) {
            return .plugin
        }
        return (entry.cachedWithoutPlugin ?? false) ? .withoutPlugin : .withoutPlugin
    }

    private func isEntryCompatible(_ entry: Entry, with track: TrackIdentity) -> Bool {
        if effectiveCacheSource(for: entry) == .manual {
            return true
        }
        if let title = entry.metadata?.title,
           !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !isLooseTextMatch(title, track.title) {
            return false
        }
        if let artist = entry.metadata?.artist,
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

    private func source(for document: LyricsDocument) -> Source {
        switch document.selectionState.origin {
        case .plugin, .spotify:
            return .plugin
        case .automaticSearch, .manualSelection, .local, .unknown:
            return .lyricShiori
        }
    }

    private func loadStore() throws -> Store {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Store(version: cacheVersion, entries: [:])
        }
        let data = try Data(contentsOf: url)
        let store = try decoder.decode(Store.self, from: data)
        guard store.version == cacheVersion else {
            return Store(version: cacheVersion, entries: [:])
        }
        return store
    }

    private func persist(_ store: Store) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoder.encode(store)
        try data.write(to: url, options: .atomic)
    }

    private func removeExpiredEntries(from store: inout Store) {
        let now = nowMilliseconds()
        store.entries = store.entries.filter { _, entry in
            entry.expiresAt > now && !entry.trackUri.isEmpty
        }
    }

    private func trim(_ store: inout Store) {
        guard store.entries.count > maxEntries else { return }
        store.entries = Dictionary(
            uniqueKeysWithValues: store.entries
                .sorted { $0.value.cachedAt > $1.value.cachedAt }
                .prefix(maxEntries)
                .map { ($0.key, $0.value) }
        )
    }

    private func cacheKey(trackUri: String, kind: Kind) -> String {
        "\(kind.rawValue):\(trackUri)"
    }

    private func nowMilliseconds() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded())
    }

    private func isSpotifyTrack(_ id: String) -> Bool {
        id.hasPrefix("spotify:track:")
    }
}

final class SharedLyricsCacheServer: @unchecked Sendable {
    private let cache: SharedLyricsCache
    private let localStorage: LocalLyricsStorage
    private var listener: NWListener?
    private let port: NWEndpoint.Port = 24887
    var onEntrySaved: ((SharedLyricsCache.Entry) -> Void)?

    init(cache: SharedLyricsCache, localStorage: LocalLyricsStorage = LocalLyricsStorage()) {
        self.cache = cache
        self.localStorage = localStorage
    }

    func start() {
        guard listener == nil else { return }
        do {
            let listener = try NWListener(using: .tcp, on: port)
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: .global(qos: .utility))
            self.listener = listener
        } catch {
            // The cache still works through the shared file when the bridge port is unavailable.
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .utility))
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 2_000_000) { [weak self] data, _, isComplete, _ in
            guard let self else {
                connection.cancel()
                return
            }
            var nextBuffer = buffer
            if let data {
                nextBuffer.append(data)
            }
            if self.isCompleteRequest(nextBuffer) || isComplete {
                self.respond(to: nextBuffer, on: connection)
            } else {
                self.receive(on: connection, buffer: nextBuffer)
            }
        }
    }

    private func isCompleteRequest(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8),
              let headerEnd = text.range(of: "\r\n\r\n") else {
            return false
        }
        let headers = String(text[..<headerEnd.lowerBound])
        let bodyStart = String(text[..<headerEnd.upperBound]).utf8.count
        let contentLength = headers
            .components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? "") } ?? 0
        return data.count >= bodyStart + contentLength
    }

    private func respond(to data: Data, on connection: NWConnection) {
        let response: Data
        do {
            response = try handleRequest(data)
        } catch {
            response = httpResponse(status: "500 Internal Server Error", body: Data(describe(error).utf8))
        }
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func handleRequest(_ data: Data) throws -> Data {
        guard let text = String(data: data, encoding: .utf8),
              let headerEnd = text.range(of: "\r\n\r\n") else {
            return httpResponse(status: "400 Bad Request")
        }
        let headerText = String(text[..<headerEnd.lowerBound])
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return httpResponse(status: "400 Bad Request")
        }
        let requestParts = requestLine.split(separator: " ")
        guard requestParts.count >= 2 else {
            return httpResponse(status: "400 Bad Request")
        }
        let method = String(requestParts[0])
        let target = String(requestParts[1])

        if method == "OPTIONS" {
            return httpResponse(status: "204 No Content")
        }

        guard let components = URLComponents(string: "http://localhost\(target)"),
              components.path == "/lyrics-cache" else {
            return httpResponse(status: "404 Not Found")
        }

        if method == "GET" {
            let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            guard let trackUri = query["trackUri"],
                  let kindValue = query["kind"],
                  let kind = SharedLyricsCache.Kind(rawValue: kindValue) else {
                return httpResponse(status: "400 Bad Request")
            }
            if let localBody = try encodedLocalEntry(query: query, trackUri: trackUri, kind: kind) {
                return httpResponse(status: "200 OK", body: localBody, contentType: "application/json")
            }
            guard let body = try cache.encodedPreferredEntry(trackUri: trackUri, kind: kind) else {
                return httpResponse(status: "404 Not Found")
            }
            return httpResponse(status: "200 OK", body: body, contentType: "application/json")
        }

        if method == "POST" {
            let bodyStart = String(text[..<headerEnd.upperBound]).utf8.count
            let body = data.dropFirst(bodyStart)
            let entry = try cache.saveEncodedEntry(Data(body))
            onEntrySaved?(entry)
            return httpResponse(status: "204 No Content")
        }

        return httpResponse(status: "405 Method Not Allowed")
    }

    private func encodedLocalEntry(query: [String: String], trackUri: String, kind: SharedLyricsCache.Kind) throws -> Data? {
        let title = query["title"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let artist = query["artist"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty, !artist.isEmpty else { return nil }
        let duration = query["duration"].flatMap(Double.init).map { $0 / 1000 }
        let track = TrackIdentity(
            id: trackUri,
            title: title,
            artist: artist,
            album: query["album"]?.nilIfEmpty,
            duration: duration,
            albumArtworkURL: nil,
            localFileURL: nil,
            embeddedLyrics: nil
        )
        guard let document = try localStorage.loadLyrics(for: track, includeBesideTrack: false) else {
            return nil
        }
        return try cache.encodedEntry(document, for: track, kind: kind)
    }

    private func httpResponse(status: String, body: Data = Data(), contentType: String = "text/plain; charset=utf-8") -> Data {
        let header = """
        HTTP/1.1 \(status)\r
        Access-Control-Allow-Origin: *\r
        Access-Control-Allow-Methods: GET, POST, OPTIONS\r
        Access-Control-Allow-Headers: Content-Type, Accept\r
        Content-Type: \(contentType)\r
        Content-Length: \(body.count)\r
        Connection: close\r
        \r

        """
        var data = Data(header.utf8)
        data.append(body)
        return data
    }

    private func describe(_ error: Error) -> String {
        guard let decodingError = error as? DecodingError else {
            return error.localizedDescription
        }
        switch decodingError {
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .keyNotFound(_, let context):
            return "\(context.debugDescription) at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
        case .dataCorrupted(let context):
            return "\(context.debugDescription) at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
        @unknown default:
            return decodingError.localizedDescription
        }
    }
}

enum AnyCodableValue: Codable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([AnyCodableValue])
    case object([String: AnyCodableValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([AnyCodableValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: AnyCodableValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
