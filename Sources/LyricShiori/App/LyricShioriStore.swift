import AppKit
import Foundation
import Observation
import SwiftUI

struct DesktopLyricsDisplayLine: Identifiable, Equatable {
    var id: String
    var lineID: LyricsLine.ID
    var text: String
    var wordTimings: [WordTiming]
    var lineStart: TimeInterval
    var lineEnd: TimeInterval?
    var playbackTime: TimeInterval
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
    private var lyricClockTask: Task<Void, Never>?
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
        self.sharedLyricsCacheServer.onEntrySaved = { [weak self] entry in
            Task { @MainActor in
                self?.sharedLyricsCacheEntrySaved(entry)
            }
        }
    }

    func start() {
        installSpotifyPlaybackObserver()
        syncFullScreenPlayingConnection()
        hydrateLocalLyricsFromSharedCache()
        syncDesktopLyricsWindow()
        playerTask?.cancel()
        playerTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshPlayback()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        lyricClockTask?.cancel()
        lyricClockTask = Task { [weak self] in
            while !Task.isCancelled {
                await MainActor.run {
                    self?.updateCurrentLine()
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    func stop() {
        playerTask?.cancel()
        lyricClockTask?.cancel()
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

        loadCachedLyricsForCurrentTrack(track)
        // The playback refresh hides the window before loading the new track's cache.
        // Re-sync here so a successfully loaded cache can show the window again.
        syncDesktopLyricsWindow()
        guard !currentLyricsBlocksAutomaticSearch else { return }
        guard !settings.connectFullScreenPlaying else { return }

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

        // A manual search is a chooser, not an automatic decision. Ask each
        // provider for a broad result set so alternate versions remain visible.
        let request = ShioriLyricsSearchRequest(
            title: cleanTitle,
            artist: cleanArtist,
            album: album,
            duration: duration,
            limit: acceptFirstResult ? 8 : 50
        )
        var collected: [LyricsSearchResult] = []
        let matcher = LyricsCandidateMatcher(
            request: request,
            referenceDocument: spotifyReferenceDocument(matching: request),
            mode: acceptFirstResult ? .strictAutomatic : .rankedManual
        )
        for providerID in orderedProviders() {
            guard !Task.isCancelled, isCurrentSearch(searchID, requiredTrackSignature: requiredTrackSignature) else { return }
            guard let service = lyricsServices[providerID] else { continue }
            do {
                let results = try await service.search(request)
                    .compactMap { matcher.evaluate($0) }
                    .sorted(by: matcher.sort)
                guard !Task.isCancelled, isCurrentSearch(searchID, requiredTrackSignature: requiredTrackSignature) else { return }
                collected.append(contentsOf: results)
                searchResults = collected.sorted(by: matcher.sort)
                if acceptFirstResult, shouldAcceptAutomaticSearchResult, let first = results.first {
                    acceptLyrics(first.document, sourceName: first.provider.rawValue, isManualSelection: false)
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

    func acceptLyrics(_ document: LyricsDocument, sourceName: String? = nil, isManualSelection: Bool = true) {
        let track = playback.track
        var copy = settings.filter.apply(to: LyricsContentNormalizer.removingLeadingMetadata(from: document, track: track))
        copy.metadata.title = copy.metadata.title?.isEmpty == false ? copy.metadata.title : track?.title
        copy.metadata.artist = copy.metadata.artist?.isEmpty == false ? copy.metadata.artist : track?.artist
        copy.metadata.album = copy.metadata.album?.isEmpty == false ? copy.metadata.album : track?.album
        copy.sourceName = sourceName ?? copy.sourceName
        copy.selectionState = isManualSelection
            ? .manual(origin: sourceName == LyricsProviderID.local.rawValue ? .local : .manualSelection)
            : .automaticSearch(cachedWithoutPlugin: !settings.connectFullScreenPlaying)
        copy.needsPersist = true
        currentLyrics = copy
        persistIfNeeded()
        updateCurrentLine()
        syncDesktopLyricsWindow()
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
        currentLyrics?.selectionState = .manual(origin: .manualSelection)
        currentLyrics?.needsPersist = true
        persistIfNeeded()
        updateCurrentLine()
        syncDesktopLyricsWindow()
    }

    func setOffset(_ offset: Int) {
        currentLyrics?.offsetMilliseconds = offset
        currentLyrics?.selectionState = .manual(origin: .manualSelection)
        currentLyrics?.needsPersist = true
        persistIfNeeded()
        updateCurrentLine()
        syncDesktopLyricsWindow()
    }

    func resetOffset() {
        setOffset(0)
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
        let playbackTime = playback.effectiveElapsedTime + lyrics.adjustedDelay
        return (lowerBound...upperBound).compactMap { lineIndex in
            let line = lyrics.lines[lineIndex]
            let text = originalLineText(for: line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return DesktopLyricsDisplayLine(
                id: "\(line.id.uuidString)-\(lineIndex)",
                lineID: line.id,
                text: text,
                wordTimings: line.wordTimings,
                lineStart: line.position,
                lineEnd: lyrics.lines[(lineIndex + 1)...].first?.position
                    ?? line.wordTimings.last.flatMap { timing in
                        timing.duration.map { timing.start + $0 }
                    }
                    ?? playback.track?.duration,
                playbackTime: playbackTime,
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
            if currentLineIndex != nil {
                currentLineIndex = nil
            }
            return
        }
        let nextIndex = currentLyrics.lineIndex(at: playback.effectiveElapsedTime)
        if currentLineIndex != nextIndex {
            currentLineIndex = nextIndex
        }
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

    private func loadCachedLyricsForCurrentTrack(_ track: TrackIdentity) {
        do {
            if let local = try localLyricsStorage().loadLyrics(for: track, includeBesideTrack: settings.loadLyricsBesideTrack) {
                useCachedLyrics(
                    local,
                    for: track,
                    persistLocal: false,
                    syncShared: settings.connectFullScreenPlaying && local.selectionState.cacheSource == .manual
                )
                return
            }

            if settings.connectFullScreenPlaying {
                return
            }

            if let automatic = try sharedLyricsCache.loadAutomaticDocument(for: track) {
                useCachedLyrics(automatic, for: track, persistLocal: true, syncShared: false)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func useCachedLyrics(_ document: LyricsDocument, for track: TrackIdentity, persistLocal: Bool, syncShared: Bool) {
        let copy = settings.filter.apply(to: LyricsContentNormalizer.removingLeadingMetadata(from: document, track: track))
        currentLyrics = copy
        updateCurrentLine()
        syncDesktopLyricsWindow()
        if persistLocal {
            persistLocalLyrics(copy, for: track)
        }
        if syncShared {
            persistSharedLyrics(copy, for: track)
        }
    }

    private func sharedLyricsCacheEntrySaved(_ entry: SharedLyricsCache.Entry) {
        if let cached = try? sharedLyricsCache.bestLocalPersistenceDocument(for: entry.trackUri) {
            persistLocalLyrics(cached.document, for: cached.track)
        }

        guard settings.connectFullScreenPlaying,
              playback.track?.id == entry.trackUri,
              let track = playback.track else {
            return
        }
        loadCachedLyricsForCurrentTrack(track)
        if currentLyricsBlocksAutomaticSearch {
            searchTask?.cancel()
            activeSearchID = UUID()
        }
    }

    func setFullScreenPlayingConnectionEnabled(_ enabled: Bool) {
        settings.connectFullScreenPlaying = enabled
        syncFullScreenPlayingConnection()
        if enabled {
            hydrateLocalLyricsFromSharedCache()
        }
        Task { await currentTrackChanged() }
    }

    private func syncFullScreenPlayingConnection() {
        if settings.connectFullScreenPlaying {
            sharedLyricsCacheServer.start()
        } else {
            sharedLyricsCacheServer.stop()
        }
    }

    private func persistLocalLyrics(_ document: LyricsDocument, for track: TrackIdentity) {
        do {
            _ = try localLyricsStorage().save(document, for: track)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func hydrateLocalLyricsFromSharedCache() {
        do {
            for cached in try sharedLyricsCache.localPersistenceDocuments() {
                persistLocalLyrics(cached.document, for: cached.track)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func persistSharedLyrics(_ document: LyricsDocument) {
        guard let track = playback.track else { return }
        persistSharedLyrics(document, for: track)
    }

    private func persistSharedLyrics(_ document: LyricsDocument, for track: TrackIdentity) {
        do {
            try sharedLyricsCache.save(document, for: track)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private var shouldAcceptAutomaticSearchResult: Bool {
        guard !settings.connectFullScreenPlaying else { return false }
        guard currentLyrics != nil else { return true }
        return !currentLyricsBlocksAutomaticSearch
    }

    private var currentLyricsBlocksAutomaticSearch: Bool {
        guard let currentLyrics else { return false }
        return currentLyrics.selectionState.cacheSource == .manual
            || currentLyrics.selectionState.cacheSource == .plugin
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
