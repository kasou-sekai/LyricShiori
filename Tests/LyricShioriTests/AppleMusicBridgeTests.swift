import Foundation
import Network
import XCTest
@testable import LyricShiori

@MainActor
final class AppleMusicBridgeTests: XCTestCase {
    private final class Service: LyricsSearchService {
        let providerID = LyricsProviderID.appleMusic
        var count = 0
        var document: LyricsDocument
        init() throws {
            document = try AppleMusicTTMLParser().parse("<tt><body><p begin='10' end='15'><span begin='10' end='15'>Hello ocean</span></p></body></tt>")
            document.metadata.title = "Example"
            document.metadata.artist = "Artist"
            document.appleMusic?.catalogDurationMilliseconds = 180000
        }
        func search(_ request: ShioriLyricsSearchRequest) async throws -> [LyricsSearchResult] {
            count += 1
            try await Task.sleep(for: .milliseconds(30))
            return [LyricsSearchResult(provider: .appleMusic, title: "Example", artist: "Artist", duration: 180, document: document)]
        }
    }
    private func body(generation: Int = 1, known: Bool = true, policy: String = "auto", revision: String? = nil) throws -> Data {
        var value: [String: Any] = ["trackUri":"spotify:track:bridge", "title":"Example", "artists":"Artist", "duration":180000,
            "reference":[["time":10000,"text":"Hello ocean"]], "relaxed":true,"matcherVersion":FullscapeLyricsMatcher.version,
            "generation":generation,"sourcePolicy":policy,"referenceKnown":known]
        if let revision { value["knownRevision"] = revision }
        return try JSONSerialization.data(withJSONObject: value)
    }
    private func json(_ data: Data) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]) }

    func testSharedMatcherUsesExistingRelaxedBoundaries() async throws {
        let service = try Service()
        let track = TrackIdentity(id: "spotify:track:bridge", title: "Localized", artist: "Localized", duration: 180)
        let matcher = FullscapeLyricsMatcher.shared
        let document = service.document
        let exact = await matcher.matches(document, track: track, reference: [.init(time: 10000, text: "Hello ocean")], relaxed: true)
        let boundary = await matcher.matches(document, track: track, reference: [.init(time: 12500, text: "Hello ocean")], relaxed: true)
        let outside = await matcher.matches(document, track: track, reference: [.init(time: 12501, text: "Hello ocean")], relaxed: true)
        let early = await matcher.matches(document, track: track, reference: [.init(time: 1000, text: "Hello ocean")], relaxed: true)
        let missing = await matcher.matches(document, track: track, reference: [], relaxed: true)
        XCTAssertTrue(exact); XCTAssertTrue(boundary); XCTAssertFalse(outside); XCTAssertTrue(early); XCTAssertFalse(missing)
    }

    func testPrefetchAndActivationShareOneJobAndKeepDesktopSelection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = LocalLyricsStorage(baseDirectory: directory)
        let service = try Service()
        let cache = SharedLyricsCache(url: directory.appendingPathComponent("cache.json"))
        let broker = AppleMusicPrefetchCoordinator(service: service, cache: cache, storage: {storage})
        let missing = try json(await broker.handle(body(known: false), activate: false))
        XCTAssertEqual(missing["status"] as? String, "reference-required")
        XCTAssertEqual(service.count, 0)
        let first = try json(await broker.handle(body(), activate: false))
        let second = try json(await broker.handle(body(generation: 2), activate: true))
        XCTAssertEqual(first["jobId"] as? String, second["jobId"] as? String)
        XCTAssertNil(first["entry"])
        var ready: [String: Any] = [:]
        for _ in 0..<100 {
            ready = try json(await broker.handle(body(generation: 3), activate: true))
            if ready["status"] as? String == "ready" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(service.count, 1)
        XCTAssertEqual(ready["status"] as? String, "ready")
        let entry = try XCTUnwrap(ready["entry"] as? [String: Any])
        XCTAssertEqual(entry["sourceFamily"] as? String, "apple-music")
        XCTAssertEqual(entry["validatedMatcherVersion"] as? String, FullscapeLyricsMatcher.version)
        XCTAssertNil(entry["appleMusic"], "Raw TTML stays in LRCS, not every bridge response")
        let revision = try XCTUnwrap(entry["documentRevision"] as? String)
        let unchanged = try json(await broker.handle(body(revision: revision), activate: true))
        XCTAssertEqual(unchanged["status"] as? String, "unchanged")
        XCTAssertNil(unchanged["entry"])
        let track = TrackIdentity(id: "spotify:track:bridge", title: "Example", artist: "Artist", duration: 180)
        var ordinary = try LyricsParser().parse("[00:10.00]Hello ocean")
        ordinary.selectionState = .manual()
        _ = try storage.save(ordinary, for: track)
        let pinned = try json(await broker.handle(body(), activate: true))
        XCTAssertEqual(pinned["status"] as? String, "standard")
        XCTAssertNotNil(try storage.loadLyrics(for: track, family: .appleMusic))
        XCTAssertNil(try storage.loadLyrics(for: track)?.appleMusic)
    }

    func testReleasedNextTrackDoesNotLaunchAfterCurrentWorker() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = LocalLyricsStorage(baseDirectory: directory)
        let service = try Service()
        let broker = AppleMusicPrefetchCoordinator(service: service,
            cache: SharedLyricsCache(url: directory.appendingPathComponent("cache.json")), storage: {storage})
        _ = try await broker.handle(body(), activate: false)
        var queued = try json(body())
        queued["trackUri"] = "spotify:track:removed"
        queued["clientSessionId"] = "test-client"
        queued["role"] = "next"
        queued["interestRevision"] = 1
        _ = try await broker.handle(JSONSerialization.data(withJSONObject: queued), activate: false)
        try broker.release(JSONSerialization.data(withJSONObject: ["clientSessionId":"test-client", "role":"next", "trackUri":"spotify:track:removed", "generation":1]))
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(service.count, 1, "A queued track that left the queue must not launch an Apple request")
        queued["interestRevision"] = 2
        _ = try await broker.handle(JSONSerialization.data(withJSONObject: queued), activate: false)
        // An old release must not erase a renewed interest in the same URI.
        try broker.release(JSONSerialization.data(withJSONObject: ["clientSessionId":"test-client", "role":"next", "trackUri":"spotify:track:removed", "generation":1]))
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(service.count, 2)
    }

    func testAuthenticatedV2EndpointPreservesV1AndRejectsInvalidInput() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = LocalLyricsStorage(baseDirectory: directory)
        let cache = SharedLyricsCache(url: directory.appendingPathComponent("cache.json"))
        let broker = AppleMusicPrefetchCoordinator(service: try Service(), cache: cache, storage: {storage})
        let server = SharedLyricsCacheServer(cache: cache, localStorage: storage, port: .any)
        server.onRichRequest = { data, activate in try await broker.handle(data, activate: activate) }
        server.start()
        defer { server.stop() }
        for _ in 0..<100 where server.listeningPort == nil { try await Task.sleep(for: .milliseconds(10)) }
        let port = try XCTUnwrap(server.listeningPort).rawValue
        let base = "http://127.0.0.1:\(port)"
        let (session, _) = try await URLSession.shared.data(from: URL(string: base + "/bridge-session")!)
        let handshake = try json(session)
        XCTAssertEqual(handshake["protocolVersion"] as? Int, 1)
        XCTAssertTrue((handshake["capabilities"] as? [String])?.contains("apple-music-v2") == true)
        var request = URLRequest(url: URL(string: base + "/lyrics-v2/prepare")!)
        request.httpMethod = "POST"; request.httpBody = try body(known: false)
        let (_, unauth) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((unauth as? HTTPURLResponse)?.statusCode, 401)
        request.setValue(handshake["token"] as? String, forHTTPHeaderField: "X-LyricShiori-Token")
        let (reply, authorized) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((authorized as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(try json(reply)["status"] as? String, "reference-required")
        request.httpBody = Data("{}".utf8)
        let (_, bad) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((bad as? HTTPURLResponse)?.statusCode, 400)
    }
}

@MainActor
final class AppleMusicRealCacheTests: XCTestCase {
    func testUserProvidedCoralSeaCacheTraversesBridgeWithoutRefetching() async throws {
        guard let path = ProcessInfo.processInfo.environment["FULLSCAPE_APPLE_FIXTURE"] else { throw XCTSkip("Set FULLSCAPE_APPLE_FIXTURE for the local real-song acceptance check") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = try LyricsResourceLimits.readText(at: URL(fileURLWithPath: path))
        let file = try JSONDecoder().decode(LyricsCacheFile.self, from: Data(text.utf8))
        let identity = try XCTUnwrap(file.track)
        let track = TrackIdentity(id: identity.id, title: identity.title, artist: identity.artist,
            album: identity.album, duration: identity.durationMilliseconds.map { Double($0) / 1000 })
        let storage = LocalLyricsStorage(baseDirectory: directory)
        var document = try LyricsCacheFile.decode(text, sourceName: nil, localURL: nil, track: track)
        XCTAssertEqual(document.lines.count, 68)
        XCTAssertEqual(document.lines.filter { $0.presentation?.alignment == .right }.count, 14)
        // Validate this real TTML against the independently cached Spotify
        // baseline before testing the manual, cache-only delivery path.
        let root = URL(fileURLWithPath: path).deletingLastPathComponent().deletingLastPathComponent()
        let baselineURLs = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        var baseline: LyricsDocument?
        for url in baselineURLs where url.pathExtension == "lrcs" {
            if let content = try? LyricsResourceLimits.readText(at: url),
               let candidate = try? LyricsCacheFile.decode(content, sourceName: nil, localURL: nil, track: track),
               candidate.sourceName == "Spotify" { baseline = candidate; break }
        }
        if let baseline {
            document.appleMusic?.catalogDurationMilliseconds = identity.durationMilliseconds
            let matched = await FullscapeLyricsMatcher.shared.matches(document, track: track,
                reference: baseline.lines.prefix(5).map { BridgeReferenceLine(time: $0.position * 1000, text: $0.content) }, relaxed: true)
            XCTAssertTrue(matched, "Real Coral Sea TTML must match the Spotify baseline with FullScape's actual rules")
        }
        document.selectionState = .manual()
        _ = try storage.saveCandidate(document, for: track)
        let cache = SharedLyricsCache(url: directory.appendingPathComponent("shared.json"))
        let broker = AppleMusicPrefetchCoordinator(cache: cache, storage: {storage})
        let request: [String: Any] = ["trackUri":track.id,"title":track.title,"artists":track.artist,"duration":(track.duration ?? 0) * 1000,"reference":[],"referenceKnown":false,"relaxed":true,"matcherVersion":FullscapeLyricsMatcher.version,"generation":9,"sourcePolicy":"apple-music"]
        let payload = try JSONSerialization.data(withJSONObject: request)
        let manifest = try JSONSerialization.jsonObject(with: await broker.handle(payload, activate: false)) as! [String: Any]
        XCTAssertEqual(manifest["status"] as? String, "ready")
        XCTAssertNil(manifest["entry"])
        let delivery = try JSONDecoder().decode(AppleMusicPrefetchCoordinator.Response.self, from: await broker.handle(payload, activate: true))
        XCTAssertEqual(delivery.entry?.lines.count, 68)
        XCTAssertEqual(delivery.entry?.lines.filter { $0.presentation?.alignment == .right }.count, 14)
        XCTAssertEqual(delivery.generation, 9)
        XCTAssertNotNil(delivery.entry?.documentRevision)
        XCTAssertNil(delivery.entry?.appleMusic)
    }
}
