import Foundation

@MainActor
protocol MusicPlayerService: AnyObject {
    var playerKind: PlayerKind { get }
    var snapshot: PlaybackSnapshot { get async }
    func playPause() async throws
    func nextTrack() async throws
    func previousTrack() async throws
    func seek(to time: TimeInterval) async throws
    func writeLyrics(_ content: String, to track: TrackIdentity) async throws
}

@MainActor
protocol SpotifyAuthorizationService: AnyObject {
    func requestAccess() async throws
    func authorizationStatus() async -> SpotifyAuthorizationStatus
}

enum SpotifyAuthorizationStatus: Sendable {
    case granted
    case denied
    case notRequested
    case spotifyNotRunning
}

@MainActor
protocol LyricsSearchService: AnyObject {
    var providerID: LyricsProviderID { get }
    func search(_ request: ShioriLyricsSearchRequest) async throws -> [LyricsSearchResult]
}

protocol LyricsStorageService {
    func candidateURLs(for track: TrackIdentity) -> [URL]
    func loadLyrics(for track: TrackIdentity) throws -> LyricsDocument?
    func save(_ document: LyricsDocument, for track: TrackIdentity) throws -> URL
    func importLyrics(from url: URL) throws -> LyricsDocument
    func export(_ document: LyricsDocument, to url: URL) throws
}

protocol ChineseConversionService {
    func convert(_ text: String, mode: ChineseConversionMode) -> String
}

enum ServiceError: LocalizedError {
    case adapterNotImplemented(String)
    case noCurrentTrack
    case noLyrics
    case automationDenied
    case scriptFailed(String)
    case networkFailed(String)

    var errorDescription: String? {
        switch self {
        case .adapterNotImplemented(let name):
            "\(name) adapter is not implemented yet."
        case .noCurrentTrack:
            "No music playing"
        case .noLyrics:
            "No lyrics available"
        case .automationDenied:
            "Spotify access was denied. Enable Automation permission for LyricShiori in System Settings > Privacy & Security > Automation, then restart the app."
        case .scriptFailed(let message):
            message
        case .networkFailed(let message):
            message
        }
    }
}
