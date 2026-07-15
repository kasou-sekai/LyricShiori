import Foundation
import Network

final class SharedLyricsCache: @unchecked Sendable {
    enum SaveResult {
        case saved
        case unchanged
        case rejected
    }
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
        var hidden: Bool?
        var desktopLyricsColors: DesktopLyricsColors? = nil
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
    private var memoryStore: Store?

    private let cacheVersion = 10
    private let readyTTL: Int64 = 14 * 24 * 60 * 60 * 1000
    private let maxEntries = 80

    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music/\(Defaults.defaultLyricsDirectoryName)", isDirectory: true)
            .appendingPathComponent("full-screen-lyrics-cache-v10.json")
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
                    hidden: false,
                    desktopLyricsColors: document.desktopLyricsColors,
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

    func hideLyrics(for track: TrackIdentity) throws {
        guard isSpotifyTrack(track.id) else { return }
        let now = nowMilliseconds()
        for kind in Kind.allCases {
            try save(
                Entry(
                    kind: kind,
                    trackUri: track.id,
                    cachedAt: now,
                    expiresAt: now + readyTTL,
                    lines: [],
                    metadata: Metadata(
                        title: track.title,
                        artist: track.artist,
                        album: track.album,
                        languageCode: nil,
                        translationLanguages: []
                    ),
                    cacheSource: .manual,
                    source: .lyricShiori,
                    sourceName: "LyricShiori",
                    isManualSelection: true,
                    cachedWithoutPlugin: false,
                    offsetMilliseconds: 0,
                    timingOffsetApplied: false,
                    hidden: true,
                    debug: nil
                )
            )
        }
    }

    @discardableResult
    func save(_ entry: Entry) throws -> SaveResult {
        guard isValid(entry) else { return .rejected }
        lock.lock()
        defer { lock.unlock() }

        var store = try loadStore()
        removeExpiredEntries(from: &store)
        let key = cacheKey(trackUri: entry.trackUri, kind: entry.kind)
        if effectiveCacheSource(for: store.entries[key]) == .manual,
           effectiveCacheSource(for: entry) != .manual {
            try persist(store)
            LyricsBridgeTrace.record(event: "cache.rejected.manual-preserved", entry: entry)
            return .rejected
        }
        if let existing = store.entries[key],
           effectiveCacheSource(for: entry) != .manual,
           compareLyricsQuality(existing.lines, entry.lines) > 0 {
            // The plugin can publish an enhanced result first and then later
            // replace the same cache kind with its plain Spotify fallback. Keep
            // the richer entry so word timings are never downgraded to line-only
            // lyrics by a late bridge update.
            try persist(store)
            LyricsBridgeTrace.record(event: "cache.rejected.quality-preserved", entry: entry)
            return .rejected
        }
        // Retried bridge POSTs carry the same cache timestamp. They are not a
        // new lyric selection, so avoid re-persisting the cache and notifying
        // the UI to reload the current lyric file.
        if store.entries[key]?.cachedAt == entry.cachedAt {
            return .unchanged
        }
        store.entries[key] = entry
        trim(&store)
        try persist(store)
        LyricsBridgeTrace.record(event: "cache.saved", entry: entry)
        return .saved
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

    func encodedBestPreferredEntry(_ document: LyricsDocument, for track: TrackIdentity, kind: Kind) throws -> Data? {
        let localEntry = entry(from: document, for: track, kind: kind)
        let cachedEntry = try entry(trackUri: track.id, kind: kind)
        let candidates = [localEntry, cachedEntry]
            .compactMap { $0 }
            .filter { isSharedBridgePreferred($0) }
        if let hidden = candidates.first(where: { $0.hidden == true }) {
            return try encoder.encode(hidden)
        }
        guard let best = bestLocalPersistenceEntry(from: candidates) else { return nil }
        return try encoder.encode(best)
    }

    func encodedEntry(_ document: LyricsDocument, for track: TrackIdentity, kind: Kind) throws -> Data? {
        let entry = entry(from: document, for: track, kind: kind)
        guard !entry.lines.isEmpty, isSharedBridgePreferred(entry) else { return nil }
        return try encoder.encode(entry)
    }

    @discardableResult
    func saveEncodedEntry(_ data: Data) throws -> Entry? {
        let entry = try decoder.decode(Entry.self, from: data)
        LyricsBridgeTrace.record(event: "bridge.received", entry: entry)
        return try save(entry) == .saved ? entry : nil
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
            needsPersist: false,
            desktopLyricsColors: entry.desktopLyricsColors
        )
        document = LyricsTimingNormalizer.normalized(document, expectedDuration: track.duration)
        document.selectionState = selectionState(from: entry)
        document.metadata.languageCode = LyricsLanguageRecognizer.recognize(in: lines.map(\.content).joined(separator: "\n"))
        return LyricsContentNormalizer.removingLeadingMetadata(from: document, track: track)
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
            hidden: false,
            desktopLyricsColors: document.desktopLyricsColors,
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

    private func compareLocalPersistencePriority(_ lhs: Entry, _ rhs: Entry) -> Int {
        let sourceScore = localPersistenceSourceScore(lhs) - localPersistenceSourceScore(rhs)
        if sourceScore != 0 { return sourceScore }
        let qualityScore = compareLyricsQuality(lhs.lines, rhs.lines)
        if qualityScore != 0 { return qualityScore }
        let kindScore = localPersistenceKindScore(lhs.kind) - localPersistenceKindScore(rhs.kind)
        if kindScore != 0 { return kindScore }
        let lineScore = lhs.lines.count - rhs.lines.count
        if lineScore != 0 { return lineScore }
        return Int(lhs.cachedAt - rhs.cachedAt)
    }

    private func bestLocalPersistenceEntry<S: Sequence>(from entries: S) -> Entry? where S.Element == Entry {
        entries.reduce(nil) { best, entry in
            guard let best else { return entry }
            return compareLocalPersistencePriority(entry, best) > 0 ? entry : best
        }
    }

    private func compareLyricsQuality(_ lhs: [Line], _ rhs: [Line]) -> Int {
        let left = lyricsQualityScore(lhs)
        let right = lyricsQualityScore(rhs)
        for (leftValue, rightValue) in zip(left, right) where leftValue != rightValue {
            return leftValue - rightValue
        }
        return 0
    }

    private func lyricsQualityScore(_ lines: [Line]) -> [Int] {
        let meaningful = lines.count(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        let timed = lines.count(where: { $0.time != nil })
        let karaoke = lines.count(where: { !($0.words ?? []).isEmpty })
        let furigana = lines.count(where: { !($0.furigana?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) })
        let translation = lines.count(where: { !($0.translation?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) })
        let romanization = lines.count(where: { !($0.romanization?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) })
        return [
            karaoke > 0 ? 1 : 0,
            furigana > 0 ? 1 : 0,
            translation > 0 ? 1 : 0,
            karaoke,
            furigana,
            translation,
            romanization,
            timed,
            meaningful,
        ]
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
        let candidates = try preferredKinds.compactMap { kind -> Entry? in
            guard let entry = try entry(trackUri: track.id, kind: kind),
                  !entry.lines.isEmpty,
                  isEntryCompatible(entry, with: track),
                  predicate(entry) else {
                return nil
            }
            return entry
        }
        guard let best = bestLocalPersistenceEntry(from: candidates) else { return nil }
        return document(from: best, track: track)
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
        if let memoryStore { return memoryStore }
        guard FileManager.default.fileExists(atPath: url.path) else {
            let store = Store(version: cacheVersion, entries: [:])
            memoryStore = store
            return store
        }
        let data = try Data(contentsOf: url)
        let store: Store
        do {
            store = try decoder.decode(Store.self, from: data)
        } catch {
            let quarantineURL = url
                .deletingPathExtension()
                .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: quarantineURL)
            let store = Store(version: cacheVersion, entries: [:])
            memoryStore = store
            return store
        }
        guard store.version == cacheVersion else {
            let empty = Store(version: cacheVersion, entries: [:])
            memoryStore = empty
            return empty
        }
        memoryStore = store
        return store
    }

    private func persist(_ store: Store) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoder.encode(store)
        try data.write(to: url, options: .atomic)
        memoryStore = store
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

    private func isValid(_ entry: Entry) -> Bool {
        guard isSpotifyTrack(entry.trackUri),
              entry.trackUri.utf8.count <= 256,
              entry.lines.count <= 5_000,
              entry.expiresAt > entry.cachedAt,
              entry.expiresAt - entry.cachedAt <= 31 * 24 * 60 * 60 * 1_000 else {
            return false
        }
        return entry.lines.allSatisfy { line in
            line.text.utf8.count <= 16_384
                && (line.translation?.utf8.count ?? 0) <= 16_384
                && (line.romanization?.utf8.count ?? 0) <= 16_384
                && (line.furigana?.utf8.count ?? 0) <= 16_384
                && (line.words?.count ?? 0) <= 2_000
        }
    }
}

final class SharedLyricsCacheServer: @unchecked Sendable {
    private struct BridgePresence: Codable {
        var client: String
        var leaseMilliseconds: Int?
    }

    private struct BridgeState: Codable {
        var trackUri: String
        var leaseMilliseconds: Int?
        var active: Bool
    }

    private struct SessionResponse: Codable {
        var token: String
        var protocolVersion: Int
    }

    private let cache: SharedLyricsCache
    private let localStorage: LocalLyricsStorage
    private var listener: NWListener?
    private let port: NWEndpoint.Port = 24887
    private let sessionToken = UUID().uuidString
    private let stateLock = NSLock()
    private var activeLeases: [String: Int64] = [:]
    private var activeClients: [String: Int64] = [:]
    private let maximumHeaderBytes = 32 * 1_024
    private let maximumBodyBytes = 1_024 * 1_024
    private let allowedOrigins: Set<String> = [
        "https://xpui.app.spotify.com",
    ]
    var onEntrySaved: ((SharedLyricsCache.Entry) -> Void)?

    init(cache: SharedLyricsCache, localStorage: LocalLyricsStorage = LocalLyricsStorage()) {
        self.cache = cache
        self.localStorage = localStorage
    }

    func start() {
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
            let listener = try NWListener(using: parameters)
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
        stateLock.withLock {
            activeLeases.removeAll()
            activeClients.removeAll()
        }
    }

    func hasActiveLease(for trackURI: String) -> Bool {
        stateLock.withLock {
            let now = nowMilliseconds()
            activeLeases = activeLeases.filter { $0.value > now }
            return (activeLeases[trackURI] ?? 0) > now
        }
    }

    /// A recent bridge-state heartbeat means the Full-Screen Playing plugin is
    /// currently connected, even when it is reporting a different track.
    func hasActiveConnection() -> Bool {
        stateLock.withLock {
            let now = nowMilliseconds()
            activeLeases = activeLeases.filter { $0.value > now }
            activeClients = activeClients.filter { $0.value > now }
            return !activeClients.isEmpty || !activeLeases.isEmpty
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .utility))
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
            connection.cancel()
        }
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
            if nextBuffer.count > self.maximumHeaderBytes + self.maximumBodyBytes {
                self.send(self.httpResponse(status: "413 Payload Too Large"), on: connection)
                return
            }
            if self.isCompleteRequest(nextBuffer) || isComplete {
                self.respond(to: nextBuffer, on: connection)
            } else {
                self.receive(on: connection, buffer: nextBuffer)
            }
        }
    }

    private func isCompleteRequest(_ data: Data) -> Bool {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator) else {
            return false
        }
        guard headerRange.lowerBound <= maximumHeaderBytes,
              let headers = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else {
            return true
        }
        let contentLength = headers
            .components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? "") } ?? 0
        guard contentLength >= 0, contentLength <= maximumBodyBytes else { return true }
        return data.count >= headerRange.upperBound + contentLength
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

    private func send(_ response: Data, on connection: NWConnection) {
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func handleRequest(_ data: Data) throws -> Data {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator),
              headerRange.lowerBound <= maximumHeaderBytes,
              let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else {
            return httpResponse(status: "400 Bad Request")
        }
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
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            headers[String(parts[0]).lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        let origin = headers["origin"]
        guard origin.map({ allowedOrigins.contains($0) }) ?? true else {
            return httpResponse(status: "403 Forbidden")
        }

        if method == "OPTIONS" {
            return httpResponse(status: "204 No Content", origin: origin)
        }

        guard let components = URLComponents(string: "http://localhost\(target)") else {
            return httpResponse(status: "400 Bad Request", origin: origin)
        }

        if method == "GET", components.path == "/bridge-session" {
            let body = try JSONEncoder().encode(SessionResponse(token: sessionToken, protocolVersion: 1))
            return httpResponse(status: "200 OK", body: body, contentType: "application/json", origin: origin)
        }

        guard headers["x-lyricshiori-token"] == sessionToken else {
            return httpResponse(status: "401 Unauthorized", origin: origin)
        }

        let declaredLength = headers["content-length"].flatMap(Int.init) ?? 0
        guard declaredLength >= 0, declaredLength <= maximumBodyBytes,
              data.count >= headerRange.upperBound + declaredLength else {
            return httpResponse(status: "413 Payload Too Large", origin: origin)
        }
        let body = Data(data[headerRange.upperBound..<(headerRange.upperBound + declaredLength)])

        if method == "POST", components.path == "/bridge-presence" {
            let presence = try JSONDecoder().decode(BridgePresence.self, from: body)
            guard presence.client == "full-screen-playing" else {
                return httpResponse(status: "400 Bad Request", origin: origin)
            }
            stateLock.withLock {
                let lease = min(max(presence.leaseMilliseconds ?? 8_000, 1_000), 15_000)
                activeClients[presence.client] = nowMilliseconds() + Int64(lease)
            }
            return httpResponse(status: "204 No Content", origin: origin)
        }

        if method == "POST", components.path == "/bridge-state" {
            let state = try JSONDecoder().decode(BridgeState.self, from: body)
            guard state.trackUri.hasPrefix("spotify:track:"), state.trackUri.utf8.count <= 256 else {
                return httpResponse(status: "400 Bad Request", origin: origin)
            }
            stateLock.withLock {
                if state.active {
                    let lease = min(max(state.leaseMilliseconds ?? 8_000, 1_000), 15_000)
                    activeLeases[state.trackUri] = nowMilliseconds() + Int64(lease)
                } else {
                    activeLeases.removeValue(forKey: state.trackUri)
                }
            }
            return httpResponse(status: "204 No Content", origin: origin)
        }

        guard components.path == "/lyrics-cache" else {
            return httpResponse(status: "404 Not Found")
        }

        if method == "GET" {
            var query: [String: String] = [:]
            for item in components.queryItems ?? [] where query[item.name] == nil {
                query[item.name] = item.value ?? ""
            }
            guard let trackUri = query["trackUri"],
                  trackUri.hasPrefix("spotify:track:"),
                  trackUri.utf8.count <= 256,
                  let kindValue = query["kind"],
                  let kind = SharedLyricsCache.Kind(rawValue: kindValue) else {
                return httpResponse(status: "400 Bad Request", origin: origin)
            }
            if let localBody = try encodedLocalEntry(query: query, trackUri: trackUri, kind: kind) {
                return httpResponse(status: "200 OK", body: localBody, contentType: "application/json", origin: origin)
            }
            guard let body = try cache.encodedPreferredEntry(trackUri: trackUri, kind: kind) else {
                return httpResponse(status: "404 Not Found", origin: origin)
            }
            return httpResponse(status: "200 OK", body: body, contentType: "application/json", origin: origin)
        }

        if method == "POST" {
            if let entry = try cache.saveEncodedEntry(body) {
                onEntrySaved?(entry)
            }
            return httpResponse(status: "204 No Content", origin: origin)
        }

        return httpResponse(status: "405 Method Not Allowed", origin: origin)
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
        guard let document = try localStorage.loadLyrics(for: track) else {
            return nil
        }
        return try cache.encodedBestPreferredEntry(document, for: track, kind: kind)
    }

    private func httpResponse(
        status: String,
        body: Data = Data(),
        contentType: String = "text/plain; charset=utf-8",
        origin: String? = nil
    ) -> Data {
        let corsOrigin = origin.flatMap { allowedOrigins.contains($0) ? $0 : nil }
        let corsHeaders = corsOrigin.map {
            "Access-Control-Allow-Origin: \($0)\r\nVary: Origin\r\n"
        } ?? ""
        let header = """
        HTTP/1.1 \(status)\r
        \(corsHeaders)\
        Access-Control-Allow-Methods: GET, POST, OPTIONS\r
        Access-Control-Allow-Headers: Content-Type, Accept, X-LyricShiori-Token\r
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

    private func nowMilliseconds() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1_000).rounded())
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
