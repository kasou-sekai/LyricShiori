import Foundation
import JavaScriptCore

/// The same generated, trusted module runs in FullScape and JavaScriptCore.
actor FullscapeLyricsMatcher {
    static let shared = FullscapeLyricsMatcher()
    nonisolated static let version: String = {
        guard let url = Bundle.module.url(forResource: "fullscape-matcher-version", withExtension: "txt") else { return "unavailable" }
        return (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unavailable"
    }()
    private var context: JSContext?

    func matches(_ document: LyricsDocument, track: TrackIdentity, reference: [BridgeReferenceLine], relaxed: Bool) -> Bool {
        if context == nil {
            guard let url = Bundle.module.url(forResource: "fullscape-matcher", withExtension: "js"),
                  let script = try? String(contentsOf: url, encoding: .utf8), let context = JSContext() else { return false }
            context.evaluateScript(script)
            guard context.exception == nil else { return false }
            self.context = context
        }
        let song: [String: Any] = ["name": document.metadata.title ?? "", "artists": document.metadata.artist ?? "", "album": document.metadata.album ?? "", "duration": document.appleMusic?.catalogDurationMilliseconds ?? 0]
        let request: [String: Any] = ["title": track.title, "artists": track.artist, "album": track.album ?? "", "duration": (track.duration ?? 0) * 1000]
        let lines: [[String: Any]] = document.lines.filter { $0.presentation?.isBackground != true }.map { ["text": $0.content, "time": $0.position * 1000] }
        let baseline: [[String: Any]] = reference.map { ["text": $0.text, "time": ($0.time as Any?) ?? NSNull()] }
        context?.exception = nil
        guard let matcher = context?.objectForKeyedSubscript("FullscapeMatcher"),
              let result = matcher.invokeMethod("matchLyrics", withArguments: [song, request, baseline, lines, relaxed]), context?.exception == nil else { return false }
        return result.toBool()
    }
}

struct BridgeReferenceLine: Codable, Equatable, Sendable {
    var time: Double?
    var text: String
}
