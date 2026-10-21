import CryptoKit
import Foundation

/// Prefetch only acquires Apple Music. FullScape owns Spotify and ordinary
/// providers while collaboration is enabled. Only a confirmed display selection
/// changes the desktop source; speculative prefetch never does.
@MainActor
final class AppleMusicPrefetchCoordinator {
    struct Request: Codable, Sendable {
        var trackUri: String
        var title: String
        var artists: String
        var album: String?
        var duration: Double?
        var reference: [BridgeReferenceLine]
        var referenceKnown: Bool? = nil
        var relaxed: Bool
        var matcherVersion: String
        var generation: Int
        var clientSessionId: String? = nil
        var role: String? = nil
        var interestRevision: Int? = nil
        var knownRevision: String? = nil
        var cachedOnly: Bool? = nil
        var sourcePolicy: String
    }
    struct Response: Codable {
        var status: String
        var trackUri: String
        var generation: Int
        var matcherVersion: String = FullscapeLyricsMatcher.version
        var jobId: String?
        var entry: SharedLyricsCache.Entry?
    }
    private struct Job {
        var task: Task<Void, Never>?
        var status: String
        var document: LyricsDocument?
        var expires: Date
    }
    private var jobs: [String: Job] = [:]
    private var workTail: Task<Void, Never>?
    private struct Interest { var track: String; var generation: Int; var expires: Date }
    private var interests: [String: Interest] = [:]

    func release(_ data: Data) throws {
        struct Release: Decodable { var clientSessionId: String; var trackUri: String; var role: String; var generation: Int }
        let value = try JSONDecoder().decode(Release.self, from: data)
        let key = value.clientSessionId + "/" + value.role
        if interests[key]?.track == value.trackUri, interests[key]?.generation == value.generation { interests[key] = nil }
    }

    var onSelection: ((LyricsDocument, TrackIdentity) -> Void)?
    var canSelectTrack: ((String) -> Bool)?
    var selectionTrack: ((String) -> TrackIdentity?)?
    private var selectionRevisions: [String: Int] = [:]

    func confirmSelection(_ data: Data) throws -> Data {
        struct Selection: Decodable {
            var trackUri: String
            var sourceFamily: String
            var documentRevision: String?
            var entry: SharedLyricsCache.Entry?
            var clientSessionId: String
            var selectionRevision: Int
            var sourcePolicy: String
        }
        let value = try JSONDecoder().decode(Selection.self, from: data)
        guard value.trackUri.hasPrefix("spotify:track:"), value.trackUri.utf8.count <= 256,
              value.clientSessionId.utf8.count <= 128,
              ["auto", "apple-music", "standard"].contains(value.sourcePolicy),
              let family = LyricsStorageFamily(rawValue: value.sourceFamily) else { throw LyricsParserError.invalidLyrics }
        func reply(_ status: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["status": status])
        }
        if value.selectionRevision < (selectionRevisions[value.clientSessionId] ?? -1) { return try reply("stale") }
        guard canSelectTrack?(value.trackUri) != false else { return try reply("stale") }
        if try cache.entry(trackUri: value.trackUri, kind: .enhanced)?.hidden == true { return try reply("hidden") }
        let storage = storage()
        let track: TrackIdentity
        var document: LyricsDocument
        if family == .appleMusic {
            guard let entry = value.entry, entry.trackUri == value.trackUri,
                  let cached = cache.localPersistenceDocument(from: entry),
                  let local = try storage.loadLyrics(for: cached.track, family: .appleMusic),
                  try cache.richBridgeEntry(local, for: cached.track).documentRevision == value.documentRevision else {
                return try reply("revision-mismatch")
            }
            track = selectionTrack?(value.trackUri) ?? cached.track
            document = local
        } else {
            guard let entry = value.entry, entry.trackUri == value.trackUri,
                  entry.appleMusic == nil, entry.lines.allSatisfy({ $0.presentation == nil }),
                  try cache.save(entry) != .rejected,
                  let cached = cache.localPersistenceDocument(from: entry) else { return try reply("invalid-selection") }
            track = selectionTrack?(value.trackUri) ?? cached.track
            document = cached.document
        }
        if value.sourcePolicy == "auto", let existing = try storage.loadLyrics(for: track),
           existing.selectionState.isManualSelection,
           (LyricsStorageFamily(document: existing) != family || !document.selectionState.isManualSelection) { return try reply("manual-preserved") }
        if !document.selectionState.isManualSelection { document.selectionState = .plugin }
        _ = try storage.saveCandidate(document, for: track, preservingManualSelection: true)
        try storage.select(family, for: track)
        selectionRevisions[value.clientSessionId] = value.selectionRevision
        if selectionRevisions.count > 80 { selectionRevisions = [value.clientSessionId: value.selectionRevision] }
        onSelection?(document, track)
        return try reply("selected")
    }

    private let service: any LyricsSearchService
    private let storage: () -> LocalLyricsStorage
    private let cache: SharedLyricsCache

    init(service: any LyricsSearchService = AppleMusicLyricsService(), cache: SharedLyricsCache,
         storage: @escaping () -> LocalLyricsStorage) {
        self.service = service
        self.cache = cache
        self.storage = storage
    }

    func handle(_ data: Data, activate: Bool) async throws -> Data {
        let request = try JSONDecoder().decode(Request.self, from: data)
        guard request.trackUri.hasPrefix("spotify:track:"), request.trackUri.utf8.count <= 256,
              request.title.utf8.count <= 4096, request.artists.utf8.count <= 4096,
              request.reference.count <= 5, request.reference.allSatisfy({ $0.text.utf8.count <= 16384 && $0.time.map(LyricsResourceLimits.validMilliseconds) != false }),
              request.duration.map({ $0 > 0 && LyricsResourceLimits.validMilliseconds($0) }) != false,
              ["auto", "apple-music", "standard"].contains(request.sourcePolicy) else { throw LyricsParserError.invalidLyrics }
        interests = interests.filter { $0.value.expires > Date() }
        if let client = request.clientSessionId, let role = request.role {
            guard client.utf8.count <= 128, ["current", "next"].contains(role) else { throw LyricsParserError.invalidLyrics }
            let interestKey = client + "/" + role
            if let current = interests[interestKey], current.generation > (request.interestRevision ?? request.generation) {
                return try JSONEncoder().encode(Response(status: "stale", trackUri: request.trackUri, generation: request.generation))
            }
            interests[interestKey] = Interest(track: request.trackUri, generation: request.interestRevision ?? request.generation, expires: Date().addingTimeInterval(15))
        }
        let track = TrackIdentity(id: request.trackUri, title: request.title, artist: request.artists, album: request.album, duration: request.duration.map { $0 / 1000 })
        let storage = storage()
        func response(_ status: String, id: String? = nil, document: LyricsDocument? = nil) throws -> Data {
            var entry: SharedLyricsCache.Entry?
            if activate, let document {
                entry = try cache.richBridgeEntry(document, for: track)
                entry?.validatedMatcherVersion = request.matcherVersion
                if entry?.documentRevision == request.knownRevision, request.knownRevision != nil {
                    return try JSONEncoder().encode(Response(status: "unchanged", trackUri: track.id, generation: request.generation))
                }
            }
            return try JSONEncoder().encode(Response(status: status, trackUri: track.id, generation: request.generation, jobId: id, entry: entry))
        }
        guard request.matcherVersion == FullscapeLyricsMatcher.version else { return try response("matcher-mismatch") }
        if try cache.entry(trackUri: track.id, kind: .enhanced)?.hidden == true { return try response("hidden") }
        if request.sourcePolicy == "standard" { return try response("standard") }
        // A pinned ordinary choice wins in auto mode, including a choice made
        // while the network request was running. Explicit Apple mode is separate.
        if request.sourcePolicy == "auto", let selected = try storage.loadLyrics(for: track),
           selected.selectionState.isManualSelection, LyricsStorageFamily(document: selected) == .standard {
            return try response("standard")
        }
        if let local = try storage.loadLyrics(for: track, family: .appleMusic) {
            if local.selectionState.isManualSelection { return try response("ready", document: local) }
            if request.referenceKnown == true,
               await FullscapeLyricsMatcher.shared.matches(local, track: track, reference: request.reference, relaxed: request.relaxed) {
                return try response("ready", document: local)
            }
        }
        if request.cachedOnly == true { return try response("not-found") }
        guard request.referenceKnown == true else { return try response("reference-required") }
        var identity = request
        identity.generation = 0
        identity.clientSessionId = nil
        identity.role = nil
        identity.interestRevision = nil
        identity.knownRevision = nil
        identity.cachedOnly = nil
        identity.sourcePolicy = "apple-music"
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let key = SHA256.hash(data: try encoder.encode(identity)).map { String(format: "%02x", $0) }.joined()
        jobs = jobs.filter { $0.value.task != nil || $0.value.expires > Date() }
        if jobs[key]?.status == "canceled" { jobs[key] = nil }
        if let job = jobs[key] { return try response(job.status, id: key, document: job.document) }
        guard jobs.count < 64 else { return try response("busy") }
        jobs[key] = Job(task: nil, status: "pending", expires: Date().addingTimeInterval(120))
        let predecessor = workTail
        let work = Task { [weak self] in
            await predecessor?.value
            guard let self else { return }
            // One acquisition worker bounds queue churn. A removed next-track
            // waiter cannot launch a new network request when it reaches the head.
            if request.clientSessionId != nil, !self.interests.values.contains(where: { $0.track == track.id && $0.expires > Date() }) {
                self.jobs[key] = Job(status: "canceled", expires: Date())
                return
            }
            do {
                let query = ShioriLyricsSearchRequest(title: track.title, artist: track.artist, album: track.album, duration: track.duration, limit: 8)
                let candidates: [LyricsSearchResult]
                if let apple = service as? AppleMusicLyricsService {
                    candidates = try await apple.search(query, shouldContinue: { [weak self] in
                        request.clientSessionId == nil || self?.interests.values.contains(where: { $0.track == track.id && $0.expires > Date() }) == true
                    })
                } else { candidates = try await service.search(query) }
                var matched: LyricsDocument?
                var bestScore: [Int] = []
                for candidate in candidates {
                    if await FullscapeLyricsMatcher.shared.matches(candidate.document, track: track, reference: request.reference, relaxed: request.relaxed) {
                        let score = await FullscapeLyricsMatcher.shared.preferenceScore(candidate.document)
                        if matched == nil || bestScore.lexicographicallyPrecedes(score) {
                            matched = candidate.document
                            bestScore = score
                        }
                    }
                }
                if var document = matched {
                    document.selectionState = .automaticSearch(cachedWithoutPlugin: true)
                    // Preserve a newer manual file and never change active selection.
                    _ = try self.storage().saveCandidate(document, for: track, preservingManualSelection: true)
                    self.jobs[key] = Job(status: "ready", document: document, expires: Date().addingTimeInterval(600))
                } else {
                    self.jobs[key] = Job(status: "not-found", expires: Date().addingTimeInterval(60))
                }
            } catch AppleMusicLyricsAcquisitionError.unauthorized {
                self.jobs[key] = Job(status: "unauthorized", expires: Date().addingTimeInterval(15))
            } catch {
                self.jobs[key] = Job(status: "failed", expires: Date().addingTimeInterval(20))
            }
        }
        jobs[key]?.task = work
        workTail = work
        return try response("pending", id: key)
    }
}
