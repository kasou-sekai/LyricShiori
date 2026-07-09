import Foundation

struct LocalLyricsStorage: LyricsStorageService {
    var parser = LyricsParser()
    var baseDirectory: URL
    var isSecurityScoped: Bool

    init(baseDirectory: URL? = nil, isSecurityScoped: Bool = false) {
        self.isSecurityScoped = isSecurityScoped
        if let baseDirectory {
            self.baseDirectory = baseDirectory
        } else {
            self.baseDirectory = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first?
                .appendingPathComponent("LyricsX", isDirectory: true)
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("LyricsX", isDirectory: true)
        }
    }

    func candidateURLs(for track: TrackIdentity, includeBesideTrack: Bool) -> [URL] {
        var urls: [URL] = []
        if includeBesideTrack, let beside = track.localFileURL?.deletingPathExtension() {
            urls.append(beside.appendingPathExtension("lrcx"))
            urls.append(beside.appendingPathExtension("lrc"))
        }
        let fileName = "\(sanitize(track.title)) - \(sanitize(track.artist))"
        urls.append(baseDirectory.appendingPathComponent(fileName).appendingPathExtension("lrcx"))
        urls.append(baseDirectory.appendingPathComponent(fileName).appendingPathExtension("lrc"))
        return urls
    }

    func loadLyrics(for track: TrackIdentity, includeBesideTrack: Bool) throws -> LyricsDocument? {
        let accessed = beginSecurityScopeIfNeeded()
        defer { endSecurityScopeIfNeeded(accessed) }

        if includeBesideTrack,
           let embedded = track.embeddedLyrics,
           !embedded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let document = try? parser.parse(embedded, sourceName: "Embedded") {
            return attach(track: track, to: document)
        }

        for url in candidateURLs(for: track, includeBesideTrack: includeBesideTrack) where FileManager.default.fileExists(atPath: url.path) {
            let content = try String(contentsOf: url, encoding: .utf8)
            if let document = try? parser.parse(content, sourceName: LyricsProviderID.local.rawValue, localURL: url) {
                return attach(track: track, to: document)
            }
        }
        return nil
    }

    func save(_ document: LyricsDocument, for track: TrackIdentity) throws -> URL {
        let accessed = beginSecurityScopeIfNeeded()
        defer { endSecurityScopeIfNeeded(accessed) }

        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let url = baseDirectory
            .appendingPathComponent("\(sanitize(track.title)) - \(sanitize(track.artist))")
            .appendingPathExtension("lrcx")
        try document.legacyLRC.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func importLyrics(from url: URL) throws -> LyricsDocument {
        let content = try String(contentsOf: url, encoding: .utf8)
        var document = try parser.parse(content, sourceName: LyricsProviderID.local.rawValue, localURL: url)
        document.needsPersist = true
        return document
    }

    func export(_ document: LyricsDocument, to url: URL) throws {
        try document.legacyLRC.write(to: url, atomically: true, encoding: .utf8)
    }

    private func attach(track: TrackIdentity, to document: LyricsDocument) -> LyricsDocument {
        var copy = document
        if copy.metadata.title?.isEmpty ?? true {
            copy.metadata.title = track.title
        }
        if copy.metadata.artist?.isEmpty ?? true {
            copy.metadata.artist = track.artist
        }
        if copy.metadata.album?.isEmpty ?? true {
            copy.metadata.album = track.album
        }
        return copy
    }

    private func sanitize(_ value: String) -> String {
        value.replacingOccurrences(of: "/", with: ":")
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func beginSecurityScopeIfNeeded() -> Bool {
        guard isSecurityScoped else { return false }
        return baseDirectory.startAccessingSecurityScopedResource()
    }

    private func endSecurityScopeIfNeeded(_ accessed: Bool) {
        guard accessed else { return }
        baseDirectory.stopAccessingSecurityScopedResource()
    }
}
