import Foundation

struct TrackIdentity: Identifiable, Equatable, Codable, Hashable {
    var id: String
    var title: String
    var artist: String
    var album: String?
    var duration: TimeInterval?
    var albumArtworkURL: String?
    var localFileURL: URL?
    var embeddedLyrics: String?

    static let placeholder = TrackIdentity(
        id: "lyricshiori.placeholder",
        title: "No Track",
        artist: "Lyric Shiori",
        album: nil,
        duration: nil,
        albumArtworkURL: nil,
        localFileURL: nil,
        embeddedLyrics: nil
    )

    var signature: String {
        [
            id,
            title,
            artist,
            album ?? "",
            albumArtworkURL ?? "",
            duration.map { String(Int($0.rounded())) } ?? "",
        ]
        .joined(separator: "\u{1f}")
    }
}

enum PlaybackStatus: String, Codable, CaseIterable, Identifiable {
    case stopped
    case playing
    case paused

    var id: String { rawValue }
}

struct PlaybackSnapshot: Equatable {
    var track: TrackIdentity?
    var status: PlaybackStatus
    var elapsedTime: TimeInterval
    var capturedAt: Date

    static let stopped = PlaybackSnapshot(
        track: nil,
        status: .stopped,
        elapsedTime: 0,
        capturedAt: Date()
    )

    var effectiveElapsedTime: TimeInterval {
        guard status == .playing else { return elapsedTime }
        return max(0, elapsedTime + Date().timeIntervalSince(capturedAt))
    }
}

struct LyricsDocument: Identifiable, Equatable {
    var id = UUID()
    var metadata: LyricsMetadata
    var lines: [LyricsLine]
    var offsetMilliseconds: Int
    var sourceName: String?
    var localURL: URL?
    var needsPersist: Bool
    var selectionState: LyricsSelectionState = .automaticSearch(cachedWithoutPlugin: false)
    /// Optional per-lyric display data persisted in the LRCX `desktopLyricsColors` field.
    var desktopLyricsColors: DesktopLyricsColors? = nil

    var adjustedDelay: TimeInterval {
        TimeInterval(offsetMilliseconds) / 1000
    }

    var lrcx: String {
        LyricsCacheFile.encodedString(document: self, track: nil)
    }

    func lineIndex(at playbackTime: TimeInterval) -> Int? {
        guard !lines.isEmpty else { return nil }
        let target = playbackTime + adjustedDelay
        var low = 0
        var high = lines.count - 1
        var match: Int?
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].position <= target {
                match = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return match
    }

    static func formatTimestamp(_ time: TimeInterval) -> String {
        let total = max(0, time)
        let minutes = Int(total / 60)
        let seconds = Int(total.truncatingRemainder(dividingBy: 60))
        let centiseconds = Int((total - floor(total)) * 100)
        return String(format: "%02d:%02d.%02d", minutes, seconds, centiseconds)
    }

}

struct DesktopLyricsColors: Codable, Equatable {
    /// The selected setting, for example `Automatic`, `Aurora`, or `Custom`.
    var preset: String?
    /// RGBA hex values are platform-neutral so the shared lyrics bridge can return them too.
    var unplayedColor: String
    var playedColor: String
    var outlineColor: String
}

struct LyricsSelectionState: Equatable, Codable {
    var isManualSelection: Bool
    var origin: LyricsSelectionOrigin
    var cachedWithoutPlugin: Bool

    static func automaticSearch(cachedWithoutPlugin: Bool) -> LyricsSelectionState {
        LyricsSelectionState(
            isManualSelection: false,
            origin: .automaticSearch,
            cachedWithoutPlugin: cachedWithoutPlugin
        )
    }

    static func manual(origin: LyricsSelectionOrigin = .manualSelection) -> LyricsSelectionState {
        LyricsSelectionState(
            isManualSelection: true,
            origin: origin,
            cachedWithoutPlugin: false
        )
    }

    static let plugin = LyricsSelectionState(
        isManualSelection: false,
        origin: .plugin,
        cachedWithoutPlugin: false
    )

    var cacheSource: LyricsCacheSource {
        if isManualSelection {
            return .manual
        }
        switch origin {
        case .plugin, .spotify:
            return .plugin
        case .automaticSearch:
            return cachedWithoutPlugin ? .withoutPlugin : .manual
        case .manualSelection, .local, .unknown:
            return .manual
        }
    }

    static func from(cacheSource: LyricsCacheSource) -> LyricsSelectionState {
        switch cacheSource {
        case .withoutPlugin:
            return .automaticSearch(cachedWithoutPlugin: true)
        case .plugin:
            return .plugin
        case .manual:
            return .manual()
        }
    }
}

enum LyricsSelectionOrigin: String, Codable, Equatable {
    case plugin
    case automaticSearch = "automatic-search"
    case manualSelection = "manual-selection"
    case local
    case spotify
    case unknown
}

enum LyricsCacheSource: String, Codable, Equatable {
    case withoutPlugin = "without-plugin"
    case plugin
    case manual
}

struct LyricsMetadata: Equatable, Codable {
    var title: String?
    var artist: String?
    var album: String?
    var languageCode: String?
    var translationLanguages: [String]
    var request: ShioriLyricsSearchRequest?
}

struct LyricsLine: Identifiable, Equatable, Codable {
    var id = UUID()
    var position: TimeInterval
    var content: String
    var translations: [String: String]
    var wordTimings: [WordTiming]
}

struct WordTiming: Identifiable, Equatable, Codable {
    var id = UUID()
    var start: TimeInterval
    var duration: TimeInterval?
    var text: String
}

struct ShioriLyricsSearchRequest: Equatable, Codable, Hashable {
    var title: String
    var artist: String
    var album: String?
    var duration: TimeInterval?
    var limit: Int
}

struct LyricsSearchResult: Identifiable, Equatable {
    var id = UUID()
    var provider: LyricsProviderID
    var title: String
    var artist: String
    var duration: TimeInterval?
    var document: LyricsDocument
    var quality: Double = 0
    var isMatched: Bool = true
}

enum LyricsProviderID: String, CaseIterable, Identifiable, Codable {
    case netease = "NetEase"
    case qqMusic = "QQMusic"
    case local = "Local"

    var id: String { rawValue }
}

enum PlayerKind: String, CaseIterable, Identifiable, Codable {
    case spotify = "Spotify"

    var id: String { rawValue }
}
