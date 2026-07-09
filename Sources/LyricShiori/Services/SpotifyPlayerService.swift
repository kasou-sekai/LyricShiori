import AppKit
import Foundation

@MainActor
final class SpotifyPlayerService: MusicPlayerService, SpotifyAuthorizationService {
    let playerKind: PlayerKind = .spotify

    var snapshot: PlaybackSnapshot {
        get async {
            do {
                return try runSnapshotScript()
            } catch {
                return .stopped
            }
        }
    }

    func playPause() async throws {
        _ = try runSpotifyCommand("playpause")
    }

    func nextTrack() async throws {
        _ = try runSpotifyCommand("next track")
    }

    func previousTrack() async throws {
        _ = try runSpotifyCommand("previous track")
    }

    func seek(to time: TimeInterval) async throws {
        _ = try runSpotifyCommand("set player position to \(max(0, time))")
    }

    func writeLyrics(_ content: String, to track: TrackIdentity) async throws {
        throw ServiceError.adapterNotImplemented("Spotify lyrics writing")
    }

    func requestAccess() async throws {
        _ = try runAppleScript("""
        tell application id "com.spotify.client"
            activate
            return player state as string
        end tell
        """)
    }

    private func runSnapshotScript() throws -> PlaybackSnapshot {
        guard NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.spotify.client" }) else {
            return .stopped
        }

        let script = """
        tell application id "com.spotify.client"
            if player state is stopped then
                return "stopped"
            end if
            set trackName to name of current track
            set artistName to artist of current track
            set albumName to album of current track
            set trackID to spotify url of current track
            set artworkURL to ""
            try
                set artworkURL to artwork url of current track
            end try
            set durationMS to duration of current track
            set positionSeconds to player position
            return (player state as string) & linefeed & trackID & linefeed & trackName & linefeed & artistName & linefeed & albumName & linefeed & durationMS & linefeed & positionSeconds & linefeed & artworkURL
        end tell
        """

        let output = try runAppleScript(script)
        let lines = output.components(separatedBy: .newlines)
        guard lines.first != "stopped", lines.count >= 7 else {
            return .stopped
        }

        let status: PlaybackStatus = lines[0] == "playing" ? .playing : .paused
        let duration = TimeInterval(Double(lines[5]) ?? 0) / 1000
        let elapsed = TimeInterval(Double(lines[6]) ?? 0)
        let track = TrackIdentity(
            id: lines[1],
            title: lines[2],
            artist: lines[3],
            album: lines[4].isEmpty ? nil : lines[4],
            duration: duration > 0 ? duration : nil,
            albumArtworkURL: lines.indices.contains(7) && !lines[7].isEmpty ? lines[7] : nil,
            localFileURL: nil,
            embeddedLyrics: nil
        )

        return PlaybackSnapshot(track: track, status: status, elapsedTime: elapsed, capturedAt: Date())
    }

    private func runSpotifyCommand(_ command: String) throws -> String {
        try runAppleScript("""
        tell application id "com.spotify.client"
            \(command)
        end tell
        """)
    }

    private func runAppleScript(_ source: String) throws -> String {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw ServiceError.adapterNotImplemented("AppleScript")
        }
        let descriptor = script.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int
            if code == -1743 {
                throw ServiceError.automationDenied
            }
            throw ServiceError.scriptFailed(error[NSAppleScript.errorMessage] as? String ?? "Spotify AppleScript failed")
        }
        return descriptor.stringValue ?? ""
    }
}
