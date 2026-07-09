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
        var debug: AnyCodableValue?
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

    private let cacheVersion = 5
    private let readyTTL: Int64 = 14 * 24 * 60 * 60 * 1000
    private let emptyTTL: Int64 = 30 * 60 * 1000
    private let maxEntries = 80

    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music/\(Defaults.defaultLyricsDirectoryName)", isDirectory: true)
            .appendingPathComponent("full-screen-lyrics-cache-v5.json")
    }

    func loadDocument(for track: TrackIdentity) throws -> LyricsDocument? {
        guard isSpotifyTrack(track.id) else { return nil }
        for kind in [Kind.enhanced, .enhancedRelaxed, .spotify] {
            if let document = try loadDocument(for: track, kind: kind) {
                return document
            }
        }
        return nil
    }

    func loadDocument(for track: TrackIdentity, kind: Kind) throws -> LyricsDocument? {
        guard isSpotifyTrack(track.id),
              let entry = try entry(trackUri: track.id, kind: kind),
              !entry.lines.isEmpty else {
            return nil
        }
        return document(from: entry, track: track)
    }

    func save(_ document: LyricsDocument, for track: TrackIdentity) throws {
        guard isSpotifyTrack(track.id) else { return }
        let lines = lines(from: document)
        let now = nowMilliseconds()
        for kind in [Kind.enhanced, .enhancedRelaxed] {
            try save(
                Entry(
                    kind: kind,
                    trackUri: track.id,
                    cachedAt: now,
                    expiresAt: now + (lines.isEmpty ? emptyTTL : readyTTL),
                    lines: lines,
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
        store.entries[cacheKey(trackUri: entry.trackUri, kind: entry.kind)] = entry
        trim(&store)
        try persist(store)
    }

    func encodedEntry(trackUri: String, kind: Kind) throws -> Data? {
        guard let entry = try entry(trackUri: trackUri, kind: kind) else { return nil }
        return try encoder.encode(entry)
    }

    func saveEncodedEntry(_ data: Data) throws {
        let entry = try decoder.decode(Entry.self, from: data)
        try save(entry)
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
                title: track.title,
                artist: track.artist,
                album: track.album,
                languageCode: LyricsLanguageRecognizer.recognize(in: lines.map(\.content).joined(separator: "\n")),
                translationLanguages: lines.contains(where: { !$0.translations.isEmpty }) ? ["default"] : [],
                request: nil
            ),
            lines: lines,
            offsetMilliseconds: 0,
            sourceName: entry.kind == .spotify ? "Spotify Shared Cache" : "Full-Screen Shared Cache",
            localURL: url,
            needsPersist: false
        )
        document.metadata.languageCode = LyricsLanguageRecognizer.recognize(in: lines.map(\.content).joined(separator: "\n"))
        return document
    }

    private func lines(from document: LyricsDocument) -> [Line] {
        document.lines.map { line in
            let sharedOffset = document.adjustedDelay
            let shiftedPosition = max(0, line.position - sharedOffset)
            return Line(
                time: shiftedPosition * 1000,
                text: line.content,
                translation: line.translations["default"],
                romanization: line.translations["romanization"],
                furigana: line.translations["furigana"],
                words: line.wordTimings.isEmpty ? nil : line.wordTimings.map {
                    Word(
                        time: max(0, $0.start - sharedOffset) * 1000,
                        duration: ($0.duration ?? 0) * 1000,
                        text: $0.text
                    )
                },
                duration: nil
            )
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
    private var listener: NWListener?
    private let port: NWEndpoint.Port = 24887

    init(cache: SharedLyricsCache) {
        self.cache = cache
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
        let bodyStart = text.distance(from: text.startIndex, to: headerEnd.upperBound)
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
            response = httpResponse(status: "500 Internal Server Error", body: Data(error.localizedDescription.utf8))
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
            guard let body = try cache.encodedEntry(trackUri: trackUri, kind: kind) else {
                return httpResponse(status: "404 Not Found")
            }
            return httpResponse(status: "200 OK", body: body, contentType: "application/json")
        }

        if method == "POST" {
            let bodyStart = text.distance(from: text.startIndex, to: headerEnd.upperBound)
            let body = data.dropFirst(bodyStart)
            try cache.saveEncodedEntry(Data(body))
            return httpResponse(status: "204 No Content")
        }

        return httpResponse(status: "405 Method Not Allowed")
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
