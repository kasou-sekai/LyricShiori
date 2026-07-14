import Foundation

enum LyricsBridgeTrace {
    private static let isEnabled = ProcessInfo.processInfo.environment["LYRICSHIORI_BRIDGE_TRACE"] == "1"
    private static let lock = NSLock()
    private static let maximumBytes = 1_000_000
    private static let retainedLines = 400
    private static let duplicateInterval: TimeInterval = 2
    nonisolated(unsafe) private static var recentSignatures: [String: Date] = [:]

    private static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music/\(Defaults.defaultLyricsDirectoryName)", isDirectory: true)
            .appendingPathComponent("lyrics-bridge-trace-v1.jsonl")
    }

    static func record(event: String, entry: SharedLyricsCache.Entry, detail: String? = nil) {
        guard isEnabled else { return }
        let lines = entry.lines
        record(
            event: event,
            trackURI: entry.trackUri,
            kind: entry.kind.rawValue,
            source: entry.cacheSource?.rawValue,
            cachedAt: entry.cachedAt,
            lineCount: lines.count,
            translationCount: lines.count(where: { !($0.translation?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }),
            romanizationCount: lines.count(where: { !($0.romanization?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }),
            wordLineCount: lines.count(where: { !($0.words ?? []).isEmpty }),
            detail: detail
        )
    }

    static func record(event: String, document: LyricsDocument, track: TrackIdentity, detail: String? = nil) {
        guard isEnabled else { return }
        let lines = document.lines
        record(
            event: event,
            trackURI: track.id,
            kind: nil,
            source: document.selectionState.cacheSource.rawValue,
            cachedAt: nil,
            lineCount: lines.count,
            translationCount: lines.count(where: { !($0.translations["default"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }),
            romanizationCount: lines.count(where: { !($0.translations["romanization"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }),
            wordLineCount: lines.count(where: { !$0.wordTimings.isEmpty }),
            detail: detail
        )
    }

    private static func record(
        event: String,
        trackURI: String,
        kind: String?,
        source: String?,
        cachedAt: Int64?,
        lineCount: Int,
        translationCount: Int,
        romanizationCount: Int,
        wordLineCount: Int,
        detail: String?
    ) {
        let payload: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "event": event,
            "trackURI": trackURI,
            "kind": kind ?? NSNull(),
            "source": source ?? NSNull(),
            "cachedAt": cachedAt ?? NSNull(),
            "lineCount": lineCount,
            "translationCount": translationCount,
            "romanizationCount": romanizationCount,
            "wordLineCount": wordLineCount,
            "detail": detail ?? NSNull(),
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else {
            return
        }

        lock.lock()
        defer { lock.unlock() }
        do {
            let signature = [event, trackURI, kind ?? "", source ?? "", "\(cachedAt ?? 0)", "\(lineCount)", "\(translationCount)", "\(romanizationCount)", "\(wordLineCount)", detail ?? ""].joined(separator: "|")
            let now = Date()
            if let lastRecorded = recentSignatures[signature], now.timeIntervalSince(lastRecorded) < duplicateInterval {
                return
            }
            recentSignatures[signature] = now
            recentSignatures = recentSignatures.filter { now.timeIntervalSince($0.value) < duplicateInterval }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            existing.append(line)
            existing.append("\n")
            if existing.utf8.count > maximumBytes {
                existing = existing
                    .split(separator: "\n", omittingEmptySubsequences: true)
                    .suffix(retainedLines)
                    .joined(separator: "\n")
                existing.append("\n")
            }
            try existing.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            // Diagnostics must never affect lyric loading or cache persistence.
        }
    }
}
