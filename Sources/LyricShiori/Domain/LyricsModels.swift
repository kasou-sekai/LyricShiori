import Foundation

struct TrackIdentity: Identifiable, Equatable, Codable, Hashable {
    var id: String
    var title: String
    var artist: String
    var album: String?
    var duration: TimeInterval?
    var localFileURL: URL?
    var embeddedLyrics: String?

    static let placeholder = TrackIdentity(
        id: "lyricshiori.placeholder",
        title: "No Track",
        artist: "Lyric Shiori",
        album: nil,
        duration: nil,
        localFileURL: nil,
        embeddedLyrics: nil
    )

    var signature: String {
        [
            id,
            title,
            artist,
            album ?? "",
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

    var adjustedDelay: TimeInterval {
        TimeInterval(offsetMilliseconds) / 1000
    }

    var legacyLRC: String {
        var output: [String] = []
        if let title = metadata.title, !title.isEmpty {
            output.append("[ti:\(title)]")
        }
        if let artist = metadata.artist, !artist.isEmpty {
            output.append("[ar:\(artist)]")
        }
        if let album = metadata.album, !album.isEmpty {
            output.append("[al:\(album)]")
        }
        if offsetMilliseconds != 0 {
            output.append("[offset:\(offsetMilliseconds)]")
        }
        output.append(contentsOf: lines.map { "[\(Self.formatTimestamp($0.position))]\($0.content)" })
        return output.joined(separator: "\n")
    }

    var lrcx: String {
        var output: [String] = []
        if let title = metadata.title, !title.isEmpty {
            output.append("[ti:\(title)]")
        }
        if let artist = metadata.artist, !artist.isEmpty {
            output.append("[ar:\(artist)]")
        }
        if let album = metadata.album, !album.isEmpty {
            output.append("[al:\(album)]")
        }
        if offsetMilliseconds != 0 {
            output.append("[offset:\(offsetMilliseconds)]")
        }

        for line in lines {
            let timestamp = Self.formatTimestamp(line.position)
            output.append("[\(timestamp)]\(line.content)")
            if !line.wordTimings.isEmpty {
                let tags = line.wordTimings.enumerated().map { index, timing in
                    let milliseconds = Int(max(0, timing.start - line.position) * 1000)
                    return "<\(milliseconds),\(index)>"
                }
                .joined()
                output.append("[\(timestamp)][tt]\(tags)")
            }
            for (language, translation) in line.translations.sorted(by: { $0.key < $1.key }) {
                let tag = language == "default" ? "tr" : "tr:\(language)"
                output.append("[\(timestamp)][\(tag)]\(translation)")
            }
        }
        return output.joined(separator: "\n")
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
