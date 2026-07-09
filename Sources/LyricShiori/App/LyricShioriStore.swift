import AppKit
import Foundation
import Observation
import SwiftUI

struct DesktopLyricsDisplayLine: Identifiable, Equatable {
    var id: String
    var lineID: LyricsLine.ID
    var text: String
    var isActive: Bool
    var distanceFromActive: Int
    var progress: Double
}

struct DesktopLyricsPalette: Equatable {
    var pending: Color
    var played: Color
    var active: Color
    var secondary: Color
    var shadow: Color
}

@MainActor
@Observable
final class LyricShioriStore {
    var settings: AppSettings
    var playback: PlaybackSnapshot = .stopped
    var currentLyrics: LyricsDocument?
    var currentLineIndex: Int?
    var searchResults: [LyricsSearchResult] = []
    var lastError: String?
    var isSearching = false
    var showDesktopLyrics = true
    var showSearchWindow = false
    var showLyricsWindow = false
    var spotifyAccessMessage = "Not requested"

    @ObservationIgnored private let conversion: ChineseConversionService
    @ObservationIgnored private let sharedLyricsCache: SharedLyricsCache
    @ObservationIgnored private let sharedLyricsCacheServer: SharedLyricsCacheServer
    private var playerServices: [PlayerKind: MusicPlayerService]
    private var lyricsServices: [LyricsProviderID: LyricsSearchService]
    private var playerTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var activeSearchID = UUID()
    private var spotifyPlaybackObserver: NSObjectProtocol?
    private var desktopLyricsWindowController: DesktopLyricsWindowController?

    init(
        settings: AppSettings = AppSettings(),
        conversion: ChineseConversionService = PassthroughChineseConversionService()
    ) {
        let sharedLyricsCache = SharedLyricsCache()
        self.settings = settings
        self.conversion = conversion
        self.sharedLyricsCache = sharedLyricsCache
        self.sharedLyricsCacheServer = SharedLyricsCacheServer(cache: sharedLyricsCache)
        self.playerServices = [.spotify: SpotifyPlayerService()]
        self.lyricsServices = [
            .netease: LyricsKitLyricsService(providerID: .netease),
            .qqMusic: LyricsKitLyricsService(providerID: .qqMusic),
        ]
        self.showDesktopLyrics = settings.desktopLyricsEnabled
    }

    func start() {
        installSpotifyPlaybackObserver()
        syncFullScreenPlayingConnection()
        syncDesktopLyricsWindow()
        playerTask?.cancel()
        playerTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshPlayback()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        playerTask?.cancel()
        searchTask?.cancel()
        sharedLyricsCacheServer.stop()
        desktopLyricsWindowController?.hide()
        if let spotifyPlaybackObserver {
            DistributedNotificationCenter.default().removeObserver(spotifyPlaybackObserver)
            self.spotifyPlaybackObserver = nil
        }
    }

    private func installSpotifyPlaybackObserver() {
        guard spotifyPlaybackObserver == nil else { return }
        spotifyPlaybackObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshPlayback()
            }
        }
    }

    func refreshPlayback() async {
        let service = playerServices[.spotify]
        guard let service else { return }
        let next = await service.snapshot
        let previousTrackSignature = playback.track?.signature
        playback = next
        updateCurrentLine()
        syncDesktopLyricsWindow()
        if previousTrackSignature != next.track?.signature {
            await currentTrackChanged()
        }
    }

    func currentTrackChanged() async {
        persistIfNeeded()
        currentLyrics = nil
        currentLineIndex = nil
        searchResults = []
        searchTask?.cancel()
        activeSearchID = UUID()

        guard let track = playback.track else { return }
        guard !settings.noSearchingTrackIDs.contains(track.id) else { return }

        do {
            if settings.connectFullScreenPlaying {
                if let shared = try sharedLyricsCache.loadDocument(for: track, kind: .enhanced)
                    ?? sharedLyricsCache.loadDocument(for: track, kind: .enhancedRelaxed) {
                    currentLyrics = settings.filter.apply(to: shared)
                    updateCurrentLine()
                    return
                }
                if let spotify = try sharedLyricsCache.loadDocument(for: track, kind: .spotify) {
                    currentLyrics = settings.filter.apply(to: spotify)
                    updateCurrentLine()
                } else if let local = try localLyricsStorage().loadLyrics(for: track, includeBesideTrack: settings.loadLyricsBesideTrack) {
                    currentLyrics = settings.filter.apply(to: local)
                    updateCurrentLine()
                }
            } else if let local = try localLyricsStorage().loadLyrics(for: track, includeBesideTrack: settings.loadLyricsBesideTrack) {
                currentLyrics = settings.filter.apply(to: local)
                updateCurrentLine()
            }
        } catch {
            lastError = error.localizedDescription
        }

        guard !(track.album.map { settings.noSearchingAlbumNames.contains($0) } ?? false) else { return }
        let searchID = activeSearchID
        let trackSignature = track.signature
        searchTask = Task { [weak self] in
            await self?.searchLyricsForCurrentTrack(searchID: searchID, trackSignature: trackSignature)
        }
    }

    func searchLyricsForCurrentTrack() async {
        guard let track = playback.track else { return }
        activeSearchID = UUID()
        let searchID = activeSearchID
        await searchLyricsForCurrentTrack(searchID: searchID, trackSignature: track.signature)
    }

    private func searchLyricsForCurrentTrack(searchID: UUID, trackSignature: String) async {
        guard let track = playback.track else { return }
        await searchLyrics(
            title: track.title,
            artist: track.artist,
            album: track.album,
            duration: track.duration,
            acceptFirstResult: true,
            searchID: searchID,
            requiredTrackSignature: trackSignature
        )
    }

    func searchLyrics(
        title: String,
        artist: String,
        album: String? = nil,
        duration: TimeInterval? = nil,
        acceptFirstResult: Bool = false,
        searchID: UUID? = nil,
        requiredTrackSignature: String? = nil
    ) async {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty || !cleanArtist.isEmpty else { return }

        isSearching = true
        defer { isSearching = false }
        searchResults = []

        let request = ShioriLyricsSearchRequest(title: cleanTitle, artist: cleanArtist, album: album, duration: duration, limit: 8)
        var collected: [LyricsSearchResult] = []
        let matcher = LyricsCandidateMatcher(request: request, referenceDocument: spotifyReferenceDocument(matching: request))
        for providerID in orderedProviders() {
            guard !Task.isCancelled, isCurrentSearch(searchID, requiredTrackSignature: requiredTrackSignature) else { return }
            guard let service = lyricsServices[providerID] else { continue }
            do {
                let results = try await service.search(request)
                    .compactMap { matcher.evaluate($0) }
                    .sorted(by: matcher.sort)
                guard !Task.isCancelled, isCurrentSearch(searchID, requiredTrackSignature: requiredTrackSignature) else { return }
                collected.append(contentsOf: results)
                searchResults = collected
                if acceptFirstResult, shouldAcceptAutomaticSearchResult, let first = results.first {
                    acceptLyrics(first.document, sourceName: first.provider.rawValue)
                }
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    private func isCurrentSearch(_ searchID: UUID?, requiredTrackSignature: String?) -> Bool {
        if let searchID, searchID != activeSearchID {
            return false
        }
        if let requiredTrackSignature, playback.track?.signature != requiredTrackSignature {
            return false
        }
        return true
    }

    func acceptLyrics(_ document: LyricsDocument, sourceName: String? = nil) {
        let track = playback.track
        var copy = settings.filter.apply(to: document)
        copy.metadata.title = copy.metadata.title?.isEmpty == false ? copy.metadata.title : track?.title
        copy.metadata.artist = copy.metadata.artist?.isEmpty == false ? copy.metadata.artist : track?.artist
        copy.metadata.album = copy.metadata.album?.isEmpty == false ? copy.metadata.album : track?.album
        copy.sourceName = sourceName ?? copy.sourceName
        copy.needsPersist = true
        currentLyrics = copy
        persistSharedLyrics(copy)
        updateCurrentLine()
    }

    func importLyrics(from url: URL) {
        do {
            acceptLyrics(try localLyricsStorage().importLyrics(from: url), sourceName: LyricsProviderID.local.rawValue)
            removeCurrentTrackFromBlockLists()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func exportCurrentLyrics(to url: URL) {
        guard let currentLyrics else {
            lastError = ServiceError.noLyrics.localizedDescription
            return
        }
        do {
            try localLyricsStorage().export(currentLyrics, to: url)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func persistIfNeeded() {
        guard let track = playback.track,
              let document = currentLyrics,
              document.needsPersist else {
            return
        }
        do {
            _ = try localLyricsStorage().save(document, for: track)
            try sharedLyricsCache.save(document, for: track)
            currentLyrics?.needsPersist = false
        } catch {
            lastError = error.localizedDescription
        }
    }

    func adjustOffset(by delta: Int) {
        currentLyrics?.offsetMilliseconds += delta
        currentLyrics?.needsPersist = true
        if let currentLyrics {
            persistSharedLyrics(currentLyrics)
        }
        updateCurrentLine()
    }

    func setOffset(_ offset: Int) {
        currentLyrics?.offsetMilliseconds = offset
        currentLyrics?.needsPersist = true
        if let currentLyrics {
            persistSharedLyrics(currentLyrics)
        }
        updateCurrentLine()
    }

    func seek(to line: LyricsLine) async {
        guard let service = playerServices[.spotify] else { return }
        do {
            try await service.seek(to: line.position)
            updateCurrentLine()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func playPause() async {
        do {
            try await playerServices[.spotify]?.playPause()
            await refreshPlayback()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func nextTrack() async {
        do {
            try await playerServices[.spotify]?.nextTrack()
            await refreshPlayback()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func previousTrack() async {
        do {
            try await playerServices[.spotify]?.previousTrack()
            await refreshPlayback()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func requestSpotifyAccess() async {
        do {
            guard let service = playerServices[.spotify] as? SpotifyAuthorizationService else {
                throw ServiceError.adapterNotImplemented("Spotify authorization")
            }
            try await service.requestAccess()
            spotifyAccessMessage = "Granted"
            await refreshPlayback()
        } catch {
            spotifyAccessMessage = error.localizedDescription
            lastError = error.localizedDescription
        }
    }

    func markWrongLyrics() {
        guard let track = playback.track else { return }
        settings.noSearchingTrackIDs.insert(track.id)
        currentLyrics = nil
        currentLineIndex = nil
        searchTask?.cancel()
    }

    func doNotSearchCurrentAlbum() {
        guard let album = playback.track?.album else { return }
        settings.noSearchingAlbumNames.insert(album)
        currentLyrics = nil
        currentLineIndex = nil
        searchTask?.cancel()
    }

    func converted(_ text: String) -> String {
        conversion.convert(text, mode: settings.chineseConversionMode)
    }

    func displayedLineText(for line: LyricsLine) -> String {
        originalLineText(for: line)
    }

    func originalLineText(for line: LyricsLine) -> String {
        converted(line.content)
    }

    func preferredTranslation(for line: LyricsLine) -> String? {
        line.translations
            .sorted { $0.key < $1.key }
            .map(\.value)
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    func desktopLyricsDisplayLines() -> [DesktopLyricsDisplayLine] {
        guard shouldDisplayLyrics,
              let lyrics = currentLyrics,
              let index = currentLineIndex,
              lyrics.lines.indices.contains(index) else {
            return []
        }

        let lowerBound = max(lyrics.lines.startIndex, index - settings.desktopLyricsPreviousLineCount)
        let upperBound = min(lyrics.lines.index(before: lyrics.lines.endIndex), index + settings.desktopLyricsNextLineCount)
        return (lowerBound...upperBound).compactMap { lineIndex in
            let line = lyrics.lines[lineIndex]
            let text = originalLineText(for: line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return DesktopLyricsDisplayLine(
                id: "\(line.id.uuidString)-\(lineIndex)",
                lineID: line.id,
                text: text,
                isActive: lineIndex == index,
                distanceFromActive: lineIndex - index,
                progress: lineIndex == index ? currentLineProgress() : (lineIndex < index ? 1 : 0)
            )
        }
    }

    func currentLineProgress() -> Double {
        guard let lyrics = currentLyrics,
              let index = currentLineIndex,
              lyrics.lines.indices.contains(index) else {
            return 0
        }
        let current = playback.effectiveElapsedTime + lyrics.adjustedDelay
        let start = lyrics.lines[index].position
        let end = lyrics.lines[(index + 1)...].first?.position
            ?? lyrics.lines[index].wordTimings.last?.start
            ?? playback.track?.duration
            ?? start + 3
        guard end > start else { return 1 }
        return min(max((current - start) / (end - start), 0), 1)
    }

    func desktopLyricsPalette() -> DesktopLyricsPalette {
        guard let key = playback.track?.albumArtworkURL, !key.isEmpty else {
            return DesktopLyricsPalette(
                pending: settings.desktopLyricsColor.opacity(0.42),
                played: settings.desktopLyricsProgressColor,
                active: settings.desktopLyricsColor,
                secondary: settings.desktopLyricsColor.opacity(0.70),
                shadow: settings.desktopLyricsShadowColor
            )
        }

        let palettes: [DesktopLyricsPalette] = [
            .init(pending: Color(red: 0.53, green: 0.63, blue: 0.70), played: Color(red: 0.92, green: 0.97, blue: 1.00), active: Color(red: 0.80, green: 0.91, blue: 0.98), secondary: Color(red: 0.62, green: 0.73, blue: 0.80), shadow: Color(red: 0.08, green: 0.16, blue: 0.20)),
            .init(pending: Color(red: 0.63, green: 0.57, blue: 0.70), played: Color(red: 0.98, green: 0.93, blue: 1.00), active: Color(red: 0.90, green: 0.82, blue: 0.96), secondary: Color(red: 0.72, green: 0.65, blue: 0.80), shadow: Color(red: 0.17, green: 0.10, blue: 0.22)),
            .init(pending: Color(red: 0.58, green: 0.66, blue: 0.56), played: Color(red: 0.94, green: 1.00, blue: 0.88), active: Color(red: 0.79, green: 0.91, blue: 0.73), secondary: Color(red: 0.68, green: 0.77, blue: 0.64), shadow: Color(red: 0.10, green: 0.18, blue: 0.10)),
            .init(pending: Color(red: 0.70, green: 0.59, blue: 0.52), played: Color(red: 1.00, green: 0.94, blue: 0.88), active: Color(red: 0.96, green: 0.78, blue: 0.66), secondary: Color(red: 0.78, green: 0.66, blue: 0.58), shadow: Color(red: 0.22, green: 0.12, blue: 0.08)),
            .init(pending: Color(red: 0.55, green: 0.63, blue: 0.76), played: Color(red: 0.90, green: 0.95, blue: 1.00), active: Color(red: 0.69, green: 0.81, blue: 0.98), secondary: Color(red: 0.63, green: 0.71, blue: 0.84), shadow: Color(red: 0.07, green: 0.12, blue: 0.24)),
            .init(pending: Color(red: 0.70, green: 0.56, blue: 0.61), played: Color(red: 1.00, green: 0.91, blue: 0.94), active: Color(red: 0.96, green: 0.72, blue: 0.80), secondary: Color(red: 0.78, green: 0.63, blue: 0.68), shadow: Color(red: 0.22, green: 0.08, blue: 0.14)),
        ]
        return palettes[stablePaletteIndex(for: key, count: palettes.count)]
    }

    func syncDesktopLyricsWindow() {
        guard settings.desktopLyricsEnabled else {
            desktopLyricsWindowController?.hide()
            return
        }

        if desktopLyricsWindowController == nil {
            desktopLyricsWindowController = DesktopLyricsWindowController(store: self)
        }

        desktopLyricsWindowController?.update()
        if desktopLyricsDisplayLines().isEmpty {
            desktopLyricsWindowController?.hide()
        } else {
            desktopLyricsWindowController?.show()
        }
    }

    func setDesktopLyricsCenter(screenFrame: NSRect, center: NSPoint) {
        guard screenFrame.width > 0, screenFrame.height > 0 else { return }
        let xFactor = min(max((center.x - screenFrame.minX) / screenFrame.width, 0), 1)
        let yFactor = min(max(1 - ((center.y - screenFrame.minY) / screenFrame.height), 0), 1)
        settings.desktopLyricsXPositionFactor = xFactor
        settings.desktopLyricsYPositionFactor = yFactor
    }

    func updateCurrentLine() {
        guard let currentLyrics else {
            currentLineIndex = nil
            return
        }
        currentLineIndex = currentLyrics.lineIndex(at: playback.effectiveElapsedTime)
    }

    var shouldDisplayLyrics: Bool {
        !(settings.disableLyricsWhenPaused && playback.status == .paused)
    }

    private func stablePaletteIndex(for key: String, count: Int) -> Int {
        guard count > 0 else { return 0 }
        var hash = 5381
        for scalar in key.unicodeScalars {
            hash = ((hash << 5) &+ hash) &+ Int(scalar.value)
        }
        return abs(hash) % count
    }

    private func orderedProviders() -> [LyricsProviderID] {
        let enabled = settings.enabledProviders
        if settings.lyricsSourcePriorityEnabled {
            return settings.lyricsSourcePriorityOrder.filter { enabled.contains($0) }
        }
        return LyricsProviderID.allCases.filter { $0 != .local && enabled.contains($0) }
    }

    private func removeCurrentTrackFromBlockLists() {
        guard let track = playback.track else { return }
        settings.noSearchingTrackIDs.remove(track.id)
        if let album = track.album {
            settings.noSearchingAlbumNames.remove(album)
        }
    }

    private func localLyricsStorage() -> LocalLyricsStorage {
        let path = settings.lyricsSavingPath
        return LocalLyricsStorage(baseDirectory: path.url, isSecurityScoped: path.securityScoped)
    }

    func setFullScreenPlayingConnectionEnabled(_ enabled: Bool) {
        settings.connectFullScreenPlaying = enabled
        syncFullScreenPlayingConnection()
        Task { await currentTrackChanged() }
    }

    private func syncFullScreenPlayingConnection() {
        if settings.connectFullScreenPlaying {
            sharedLyricsCacheServer.start()
        } else {
            sharedLyricsCacheServer.stop()
        }
    }

    private func persistSharedLyrics(_ document: LyricsDocument) {
        guard settings.connectFullScreenPlaying,
              let track = playback.track else { return }
        do {
            try sharedLyricsCache.save(document, for: track)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private var shouldAcceptAutomaticSearchResult: Bool {
        currentLyrics == nil
            || currentLyrics?.sourceName == "Spotify Shared Cache"
            || currentLyrics?.sourceName == LyricsProviderID.local.rawValue
    }

    private func spotifyReferenceDocument(matching request: ShioriLyricsSearchRequest) -> LyricsDocument? {
        guard settings.connectFullScreenPlaying,
              let track = playback.track,
              track.title.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(request.title) == .orderedSame,
              track.artist.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(request.artist) == .orderedSame else {
            return nil
        }
        return try? sharedLyricsCache.loadDocument(for: track, kind: .spotify)
    }

}
