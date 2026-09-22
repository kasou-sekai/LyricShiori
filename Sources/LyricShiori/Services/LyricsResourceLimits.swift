import Foundation

/// Generous limits for song lyrics, shared by disk and bridge input boundaries.
enum LyricsResourceLimits {
    static let maximumFileBytes = 16 * 1_024 * 1_024
    static let maximumMilliseconds: Double = 366 * 24 * 60 * 60 * 1_000

    static func validMilliseconds(_ value: Double) -> Bool {
        value.isFinite && abs(value) <= maximumMilliseconds
    }

    static func safeSeconds(_ value: Double) -> Double {
        value.isFinite ? min(max(0, value), maximumMilliseconds / 1_000) : 0
    }

    static func validate(_ document: LyricsDocument) throws {
        guard document.lines.count <= 5_000,
              validMilliseconds(Double(document.offsetMilliseconds)),
              document.lines.allSatisfy({ line in
                  validMilliseconds(line.position * 1_000)
                      && line.content.utf8.count <= 16_384
                      && line.translations.count <= 64
                      && line.translations.allSatisfy { $0.key.utf8.count <= 256 && $0.value.utf8.count <= 16_384 }
                      && line.wordTimings.count <= 2_000
                      && line.wordTimings.allSatisfy {
                          validMilliseconds($0.start * 1_000)
                              && $0.duration.map { validMilliseconds($0 * 1_000) } != false
                              && $0.text.utf8.count <= 16_384
                      }
              }) else { throw LyricsParserError.invalidLyrics }
    }

    static func readText(at url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true,
              (values.fileSize ?? 0) <= maximumFileBytes else { throw LyricsParserError.invalidLyrics }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        // Bound the read itself as well: a file may grow after the stat above.
        let data = try handle.read(upToCount: maximumFileBytes + 1) ?? Data()
        guard data.count <= maximumFileBytes,
              let text = String(data: data, encoding: .utf8) else { throw LyricsParserError.invalidLyrics }
        return text
    }
}
