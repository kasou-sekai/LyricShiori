import Foundation

/// Repairs provider results whose timestamp unit is accidentally exposed as
/// seconds (for example QQ centiseconds reported as 381 instead of 3.81).
/// A track duration is required so normal long timestamps are never guessed at.
enum LyricsTimingNormalizer {
    static func normalized(_ document: LyricsDocument, expectedDuration: TimeInterval?) -> LyricsDocument {
        guard let scale = scaleFactor(for: document, expectedDuration: expectedDuration) else {
            return document
        }

        var copy = document
        copy.lines = copy.lines.map { line in
            var line = line
            line.position /= scale
            line.wordTimings = line.wordTimings.map { timing in
                var timing = timing
                timing.start /= scale
                if let duration = timing.duration {
                    timing.duration = duration / scale
                }
                return timing
            }
            return line
        }
        return copy
    }

    static func scaleFactor(
        for document: LyricsDocument,
        expectedDuration: TimeInterval?
    ) -> Double? {
        guard let expectedDuration, expectedDuration > 0 else { return nil }
        let maximumTime = document.lines.reduce(0.0) { current, line in
            let wordEnd = line.wordTimings.reduce(line.position) { end, timing in
                max(end, timing.start + (timing.duration ?? 0))
            }
            return max(current, max(line.position, wordEnd))
        }

        // A lyric can legitimately run a little past Spotify's duration, but a
        // fivefold overrun is a unit mismatch rather than ordinary metadata drift.
        guard maximumTime > expectedDuration * 5 else { return nil }

        let lowerBound = expectedDuration * 0.1
        let upperBound = expectedDuration + max(30, expectedDuration * 0.25)
        return [10.0, 100.0, 1_000.0]
            .map { scale in (scale: scale, normalizedMaximum: maximumTime / scale) }
            .filter { $0.normalizedMaximum >= lowerBound && $0.normalizedMaximum <= upperBound }
            .min { lhs, rhs in
                abs(lhs.normalizedMaximum - expectedDuration) < abs(rhs.normalizedMaximum - expectedDuration)
            }?
            .scale
    }
}
