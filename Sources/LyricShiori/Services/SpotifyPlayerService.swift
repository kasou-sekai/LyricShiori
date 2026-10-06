import AppKit
import Carbon
import Foundation

@MainActor
final class SpotifyPlayerService: MusicPlayerService, SpotifyAuthorizationService {
    let playerKind: PlayerKind = .spotify

    var snapshot: PlaybackSnapshot {
        get async {
            guard NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.spotify.client" }) else {
                return .stopped
            }
            do {
                return try await Self.runSnapshotScript()
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
        _ = try runSpotifyCommand("set player position to \(LyricsResourceLimits.safeSeconds(time))")
    }

    func writeLyrics(_ content: String, to track: TrackIdentity) async throws {
        throw ServiceError.adapterNotImplemented("Spotify lyrics writing")
    }

    func requestAccess() async throws {
        _ = try Self.runAppleScript("""
        tell application id "com.spotify.client"
            activate
            return player state as string
        end tell
        """)
    }

    /// Checks TCC's Automation decision without sending an event or presenting
    /// a permission prompt. Apple requires the target app to be running for
    /// this check, so the caller can give a useful status in that case.
    func authorizationStatus() async -> SpotifyAuthorizationStatus {
        guard let spotify = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.spotify.client"
        }) else {
            return .spotifyNotRunning
        }

        return await Task.detached(priority: .utility) {
            Self.authorizationStatus(for: spotify.processIdentifier)
        }.value
    }

    private nonisolated static func authorizationStatus(for processIdentifier: pid_t) -> SpotifyAuthorizationStatus {
        let target = NSAppleEventDescriptor(processIdentifier: processIdentifier)
        guard let address = target.aeDesc else { return .notRequested }

        switch AEDeterminePermissionToAutomateTarget(address, typeWildCard, typeWildCard, false) {
        case noErr:
            return .granted
        case OSStatus(errAEEventNotPermitted):
            return .denied
        case OSStatus(errAEEventWouldRequireUserConsent):
            return .notRequested
        default:
            return .notRequested
        }
    }

    private nonisolated static let snapshotScript = ReusableAppleScript(source: """
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
        """)

    private nonisolated static func runSnapshotScript() async throws -> PlaybackSnapshot {
        let result = try await snapshotScript.execute()
        let lines = result.output.components(separatedBy: .newlines)
        guard lines.first != "stopped", lines.count >= 7 else {
            return .stopped
        }

        let status: PlaybackStatus = lines[0] == "playing" ? .playing : .paused
        let duration = TimeInterval(Double(lines[5]) ?? 0) / 1000
        let elapsed = LyricsResourceLimits.safeSeconds(Double(lines[6]) ?? 0)
        let track = TrackIdentity(
            id: lines[1],
            title: lines[2],
            artist: lines[3],
            album: lines[4].isEmpty ? nil : lines[4],
            duration: duration.isFinite && duration > 0 ? LyricsResourceLimits.safeSeconds(duration) : nil,
            albumArtworkURL: lines.indices.contains(7) && !lines[7].isEmpty ? lines[7] : nil,
            localFileURL: nil,
            embeddedLyrics: nil
        )

        return PlaybackSnapshot(track: track, status: status, elapsedTime: elapsed, capturedAt: result.capturedAt)
    }

    private func runSpotifyCommand(_ command: String) throws -> String {
        try Self.runAppleScript("""
        tell application id "com.spotify.client"
            \(command)
        end tell
        """)
    }

    private nonisolated static func runAppleScript(_ source: String) throws -> String {
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

/// The script is created, compiled and executed only on this serial queue.
/// Polling and playback notifications can overlap, but must never execute the
/// same NSAppleScript concurrently. No AppKit or script object crosses queues.
final class ReusableAppleScript: @unchecked Sendable {
    struct Result: Sendable {
        var output: String
        var capturedAt: Date
    }

    private let queue = DispatchQueue(label: "dev.lyricshiori.spotify-snapshot", qos: .utility)
    private let source: String
    private var script: NSAppleScript?

    init(source: String) {
        self.source = source
    }

    func execute() async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    if script == nil {
                        guard let created = NSAppleScript(source: source) else {
                            throw ServiceError.adapterNotImplemented("AppleScript")
                        }
                        var error: NSDictionary?
                        guard created.compileAndReturnError(&error) else {
                            throw Self.failure(error)
                        }
                        script = created
                    }
                    let startedAt = Date()
                    var error: NSDictionary?
                    let descriptor = script!.executeAndReturnError(&error)
                    let finishedAt = Date()
                    if let error { throw Self.failure(error) }
                    continuation.resume(returning: Result(
                        output: descriptor.stringValue ?? "",
                        capturedAt: startedAt.addingTimeInterval(finishedAt.timeIntervalSince(startedAt) / 2)
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func failure(_ error: NSDictionary?) -> ServiceError {
        if error?[NSAppleScript.errorNumber] as? Int == -1743 { return .automationDenied }
        return .scriptFailed(error?[NSAppleScript.errorMessage] as? String ?? "Spotify AppleScript failed")
    }
}
