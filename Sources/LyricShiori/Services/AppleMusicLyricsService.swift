import AppKit
import Foundation
import WebKit

@MainActor
protocol AppleMusicLyricsTransport: AnyObject {
    func isAuthorized() async -> Bool
    func request(_ path: String) async throws -> Data
}

/// Uses the signed-in web player's own MusicKit transport, as in upstream
/// LyricsX's Route A. No developer token or account credential is embedded.
@MainActor
final class AppleMusicLyricsSession: NSObject, AppleMusicLyricsTransport, WKUIDelegate {
    static let shared = AppleMusicLyricsSession()
    private(set) lazy var webView: WKWebView = {
        let view = WKWebView(frame: .zero)
        view.uiDelegate = self
        view.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        return view
    }()
    private var window: NSWindow?
    private var started = false
    private var inFlight: [String: Task<Data, Error>] = [:]
    private var responses: [String: (Date, Data)] = [:]
    private var signInWindows: [NSWindow] = []

    func showSignIn() {
        start()
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720),
                styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Apple Music"
            window.isReleasedWhenClosed = false
            window.contentView = webView
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func start() {
        guard !started else { return }
        started = true
        webView.load(URLRequest(url: URL(string: "https://music.apple.com")!))
    }

    func isAuthorized() async -> Bool {
        start()
        for _ in 0..<30 {
            guard !Task.isCancelled else { return false }
            // A fresh launch must wait for MusicKit to initialize before a
            // persisted web session can report its authorization state.
            let value = try? await webView.callAsyncJavaScript("""
                if (!window.MusicKit) return null;
                const music = MusicKit.getInstance();
                return !!(music.isAuthorized && music.musicUserToken);
                """, arguments: [:], in: nil, contentWorld: .page)
            if let result = value as? Bool { return result }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil else { return nil }
        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.uiDelegate = self
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 720),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Apple Music"
        window.isReleasedWhenClosed = false
        window.contentView = popup
        window.center()
        signInWindows.append(window)
        window.makeKeyAndOrderFront(nil)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        signInWindows.filter { $0.contentView === webView }.forEach { $0.close() }
        signInWindows.removeAll { $0.contentView === webView }
    }

    func request(_ path: String) async throws -> Data {
        if let cached = responses[path], Date().timeIntervalSince(cached.0) < 300 { return cached.1 }
        if let task = inFlight[path] { return try await task.value }
        let task = Task { try await self.performRequest(path) }
        inFlight[path] = task
        defer { inFlight[path] = nil }
        let data = try await task.value
        if responses.count > 80 { responses.removeAll() }
        responses[path] = (Date(), data)
        return data
    }

    private func performRequest(_ path: String) async throws -> Data {
        try Task.checkCancellation()
        guard webView.url?.host == "music.apple.com", path.hasPrefix("/v1/") else {
            throw ServiceError.networkFailed("Apple Music sign-in is required")
        }
        let value = try await webView.callAsyncJavaScript("""
        const music = MusicKit.getInstance();
        let timer;
        try {
            const response = await Promise.race([
                music.api.music(path),
                new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('Apple Music request timed out')), 12000); })
            ]);
            return JSON.stringify(response.data === undefined ? response : response.data);
        } finally { clearTimeout(timer); }
        """, arguments: ["path": path], in: nil, contentWorld: .page)
        try Task.checkCancellation()
        guard let value = value as? String, value.utf8.count <= LyricsResourceLimits.maximumFileBytes else {
            throw LyricsParserError.invalidLyrics
        }
        return Data(value.utf8)
    }
}

enum AppleMusicLyricsAcquisitionError: Error { case unauthorized }

@MainActor
final class AppleMusicLyricsService: LyricsSearchService {
    let providerID = LyricsProviderID.appleMusic
    private let session: any AppleMusicLyricsTransport

    init(session: any AppleMusicLyricsTransport = AppleMusicLyricsSession.shared) { self.session = session }

    func search(_ request: ShioriLyricsSearchRequest) async throws -> [LyricsSearchResult] {
        try await search(request, shouldContinue: { true })
    }

    func search(_ request: ShioriLyricsSearchRequest, shouldContinue: @escaping @MainActor () -> Bool) async throws -> [LyricsSearchResult] {
        guard shouldContinue() else { return [] }
        guard await session.isAuthorized() else { throw AppleMusicLyricsAcquisitionError.unauthorized }
        let storefrontData = try await session.request("/v1/me/storefront")
        let storefront = try Self.decode(StorefrontResponse.self, from: storefrontData).data.first?.id
        guard let storefront, storefront.allSatisfy({ $0.isASCII && $0.isLetter }), storefront.count <= 8 else { return [] }
        var components = URLComponents()
        components.path = "/v1/catalog/\(storefront)/search"
        components.queryItems = [URLQueryItem(name: "types", value: "songs"),
            URLQueryItem(name: "term", value: "\(request.title) \(request.artist)"),
            URLQueryItem(name: "limit", value: String(min(max(1, request.limit), 10)))]
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        let data = try await session.request(components.string!)
        let songs = try Self.decode(SearchResponse.self, from: data).results.songs?.data ?? []
        var results: [LyricsSearchResult] = []
        for song in songs.prefix(min(max(1, request.limit), 10)) {
            try Task.checkCancellation()
            guard shouldContinue() else { break }
            guard song.id.allSatisfy(\.isNumber), !song.id.isEmpty else { continue }
            let duration = song.attributes.durationInMillis.map { Double($0) / 1000 }
            // Different live / cover recordings must not silently win a search.
            if let expected = request.duration, let duration, abs(expected - duration) > 12 { continue }
            do {
                var lyricsURL = URLComponents()
                lyricsURL.path = "/v1/catalog/\(storefront)/songs/\(song.id)/syllable-lyrics"
                lyricsURL.queryItems = [URLQueryItem(name: "l", value: Locale.preferredLanguages.first ?? "zh-Hans"),
                    URLQueryItem(name: "extend", value: "ttmlLocalizations")]
                let data = try await session.request(lyricsURL.string!)
                let response = try Self.decode(LyricsResponse.self, from: data)
                guard let attributes = response.data.first?.attributes,
                      let ttml = attributes.ttmlLocalizations ?? attributes.ttml else { continue }
                var document = try AppleMusicTTMLParser().parse(ttml, catalogID: song.id, storefront: storefront)
                document.appleMusic?.catalogDurationMilliseconds = song.attributes.durationInMillis
                document.metadata.title = song.attributes.name
                document.metadata.artist = song.attributes.artistName
                document.metadata.album = song.attributes.albumName
                document.metadata.request = request
                results.append(LyricsSearchResult(provider: .appleMusic, title: song.attributes.name,
                    artist: song.attributes.artistName, duration: duration, document: document, quality: 1))
            } catch is CancellationError { throw CancellationError() }
            catch { continue } // Catalog entries without lyrics are common.
        }
        return results
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        if let direct = try? JSONDecoder().decode(type, from: data) { return direct }
        return try JSONDecoder().decode(Envelope<T>.self, from: data).data
    }
    private struct Envelope<T: Decodable>: Decodable { var data: T }

    private struct StorefrontResponse: Decodable {
        var data: [Storefront]
        struct Storefront: Decodable { var id: String }
    }
    private struct SearchResponse: Decodable {
        var results: Results
        struct Results: Decodable { var songs: Songs? }
        struct Songs: Decodable { var data: [Song] }
        struct Song: Decodable {
            var id: String
            var attributes: Attributes
            struct Attributes: Decodable {
                var name: String
                var artistName: String
                var albumName: String?
                var durationInMillis: Int?
            }
        }
    }
    private struct LyricsResponse: Decodable {
        var data: [Resource]
        struct Resource: Decodable {
            var attributes: Attributes
            struct Attributes: Decodable { var ttml: String?; var ttmlLocalizations: String? }
        }
    }
}
