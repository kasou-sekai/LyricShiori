import AppKit
import Foundation
import ImageIO
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
    var isPlaying: Bool
    var isActive: Bool
    var distanceFromActive: Int
    var progress: Double
}

struct DesktopLyricsPalette: Equatable {
    var pending: Color
    var played: Color
    var secondary: Color
    var shadow: Color

    static func custom(using settings: AppSettings) -> Self {
        Self(
            pending: settings.desktopLyricsColor,
            played: settings.desktopLyricsProgressColor,
            secondary: settings.desktopLyricsColor.opacity(0.72),
            shadow: settings.desktopLyricsShadowColor
        )
    }
}

enum SpotifyAccessPresentationState {
    case checking
    case granted
    case denied
    case notRequested
    case spotifyNotRunning
    case error
}

extension DesktopLyricsColorPreset {
    /// All presets use a dark, near-opaque outline. This keeps the bright lyric
    /// colours legible on light wallpapers without sacrificing dark wallpapers.
    var previewPalette: DesktopLyricsPalette {
        switch self {
        case .automatic:
            DesktopLyricsColorPreset.aurora.previewPalette
        case .aurora:
            .init(pending: Color(red: 0.86, green: 0.95, blue: 1.00), played: Color(red: 0.15, green: 0.88, blue: 1.00), secondary: Color(red: 0.63, green: 0.75, blue: 0.84), shadow: Color.black)
        case .orchid:
            .init(pending: Color(red: 0.94, green: 0.87, blue: 1.00), played: Color(red: 0.77, green: 0.45, blue: 1.00), secondary: Color(red: 0.75, green: 0.63, blue: 0.84), shadow: Color.black)
        case .meadow:
            .init(pending: Color(red: 0.90, green: 1.00, blue: 0.84), played: Color(red: 0.34, green: 0.92, blue: 0.53), secondary: Color(red: 0.65, green: 0.78, blue: 0.61), shadow: Color.black)
        case .sunset:
            .init(pending: Color(red: 1.00, green: 0.92, blue: 0.78), played: Color(red: 1.00, green: 0.62, blue: 0.12), secondary: Color(red: 0.85, green: 0.70, blue: 0.53), shadow: Color.black)
        case .rose:
            .init(pending: Color(red: 1.00, green: 0.86, blue: 0.92), played: Color(red: 1.00, green: 0.34, blue: 0.61), secondary: Color(red: 0.82, green: 0.61, blue: 0.69), shadow: Color.black)
        case .custom:
            .init(pending: .white, played: .cyan, secondary: .white.opacity(0.72), shadow: .black)
        }
    }
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
    var spotifyAccessMessage = "Checking…"
    var spotifyAccessPresentationState: SpotifyAccessPresentationState = .checking
    var isFullScreenPlayingPluginConnected = false
    var isDesktopLyricsDragging = false
    var isPointerOverDesktopLyrics = false
    private(set) var isSpotifyFrontmost = false
    let updateService: GitHubUpdateService

    @ObservationIgnored private let conversion: ChineseConversionService
    @ObservationIgnored private let sharedLyricsCache: SharedLyricsCache
    @ObservationIgnored private let sharedLyricsCacheServer: SharedLyricsCacheServer
    private var playerServices: [PlayerKind: MusicPlayerService]
    private var lyricsServices: [LyricsProviderID: LyricsSearchService]
    private var playerTask: Task<Void, Never>?
    private var pluginConnectionTask: Task<Void, Never>?
    private var lyricClockTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var activeSearchID = UUID()
    private var spotifyPlaybackObserver: NSObjectProtocol?
    private var frontmostApplicationObserver: NSObjectProtocol?
    private var desktopLyricsWindowController: DesktopLyricsWindowController?
    private var searchLyricsWindowController: SearchLyricsWindowController?
    @ObservationIgnored private var artworkPresetCache: [String: DesktopLyricsColorPreset] = [:]
    @ObservationIgnored private var artworkPresetTasks: [String: Task<Void, Never>] = [:]

    init(
        settings: AppSettings = AppSettings(),
        conversion: ChineseConversionService = FoundationChineseConversionService()
    ) {
        let sharedLyricsCache = SharedLyricsCache()
        self.settings = settings
        self.updateService = GitHubUpdateService()
        self.conversion = conversion
        self.sharedLyricsCache = sharedLyricsCache
        self.sharedLyricsCacheServer = SharedLyricsCacheServer(cache: sharedLyricsCache)
        self.playerServices = [.spotify: SpotifyPlayerService()]
        self.lyricsServices = [
            .netease: LyricsKitLyricsService(providerID: .netease),
            .qqMusic: LyricsKitLyricsService(providerID: .qqMusic),
        ]
        self.sharedLyricsCacheServer.onEntrySaved = { [weak self] entry in
            Task { @MainActor in
                self?.sharedLyricsCacheEntrySaved(entry)
            }
        }
    }

    func start() {
        installSpotifyPlaybackObserver()
        installFrontmostApplicationObserver()
        syncFullScreenPlayingConnection()
        refreshFullScreenPlayingPluginConnectionStatus()
        Task { await refreshSpotifyAuthorizationStatus() }
        syncDesktopLyricsWindow()
        if settings.automaticallyCheckForUpdates {
            Task { [weak self] in
                // Avoid competing with launch-time Spotify and window setup.
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                await self?.updateService.checkForUpdates()
            }
        }
        playerTask?.cancel()
        playerTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshPlayback()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        pluginConnectionTask?.cancel()
        pluginConnectionTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshFullScreenPlayingPluginConnectionStatus()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        lyricClockTask?.cancel()
        lyricClockTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.updateCurrentLine()
                let interval = self?.playback.status == .playing && self?.currentLyrics != nil
                    ? 33
                    : 500
                try? await Task.sleep(for: .milliseconds(interval))
            }
        }
    }

    func stop() {
        playerTask?.cancel()
        pluginConnectionTask?.cancel()
        lyricClockTask?.cancel()
        searchTask?.cancel()
        sharedLyricsCacheServer.stop()
        desktopLyricsWindowController?.hide()
        if let spotifyPlaybackObserver {
            DistributedNotificationCenter.default().removeObserver(spotifyPlaybackObserver)
            self.spotifyPlaybackObserver = nil
        }
        if let frontmostApplicationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(frontmostApplicationObserver)
            self.frontmostApplicationObserver = nil
        }
    }

    func checkForUpdates() async {
        await updateService.checkForUpdates()
    }

    func installAvailableUpdate() async {
        await updateService.downloadAndInstallAvailableUpdate()
    }

    func showSearchLyricsWindow() {
        if searchLyricsWindowController == nil {
            searchLyricsWindowController = SearchLyricsWindowController()
        }
        searchLyricsWindowController?.show(store: self)
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

    private func installFrontmostApplicationObserver() {
        guard frontmostApplicationObserver == nil else { return }
        updateFrontmostApplication(NSWorkspace.shared.frontmostApplication)
        frontmostApplicationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor [weak self] in
                self?.updateFrontmostApplication(application)
            }
        }
    }

    private func updateFrontmostApplication(_ application: NSRunningApplication?) {
        let isSpotify = DesktopLyricsVisibilityPolicy.isSpotifyFrontmost(
            bundleIdentifier: application?.bundleIdentifier
        )
        guard isSpotifyFrontmost != isSpotify else { return }
        isSpotifyFrontmost = isSpotify
        syncDesktopLyricsWindow()
    }

    func refreshPlayback() async {
        let service = playerServices[.spotify]
        guard let service else { return }
        let next = await service.snapshot
        let previousTrackSignature = playback.track?.signature
        playback = next
        updateCurrentLine()
        syncDesktopLyricsWindow()
        if spotifyAccessMessage == "Open Spotify to check" {
            await refreshSpotifyAuthorizationStatus()
        }
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
        let searchID = activeSearchID
        let trackSignature = track.signature
        searchTask = Task { [weak self] in
            // Give the extension a short discovery window. This is bounded: a
            // missing or unresponsive extension must never suppress Shiori's
            // own providers indefinitely.
            if self?.settings.connectFullScreenPlaying == true {
                try? await Task.sleep(for: .seconds(1))
                let deadline = ContinuousClock.now + .seconds(9)
                while !Task.isCancelled,
                      ContinuousClock.now < deadline,
                      self?.sharedLyricsCacheServer.hasActiveLease(for: track.id) == true {
                    try? await Task.sleep(for: .milliseconds(400))
                }
            }
            guard !Task.isCancelled else { return }
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

        // Both remote providers rank Simplified Chinese queries more reliably.
        // Keep the form fields untouched, but normalize every submitted field
        // at this single boundary so automatic and manual searches agree.
        let submittedTitle = conversion.convert(cleanTitle, mode: .simplified)
        let submittedArtist = conversion.convert(cleanArtist, mode: .simplified)
        let submittedAlbum = album.map {
            conversion.convert(
                $0.trimmingCharacters(in: .whitespacesAndNewlines),
                mode: .simplified
            )
        }

        isSearching = true
        defer { isSearching = false }
        // Search failures from public lyric providers are common and transient.
        // They should not interrupt a manual search with an alert.
        lastError = nil
        searchResults = []

        // A manual search is a chooser, not an automatic decision. Ask each
        // provider for a broad result set so alternate versions remain visible.
        let request = ShioriLyricsSearchRequest(
            title: submittedTitle,
            artist: submittedArtist,
            album: submittedAlbum,
            duration: duration,
            limit: acceptFirstResult ? 8 : 50
        )
        let mode: LyricsCandidateMatcher.Mode = acceptFirstResult ? .strictAutomatic : .rankedManual
        let referenceDocument = spotifyReferenceDocument(matching: request)
        let preciseMatcher = LyricsCandidateMatcher(
            request: request,
            referenceDocument: referenceDocument,
            mode: mode
        )
        var collected = await searchProviders(
            request: request,
            matcher: preciseMatcher,
            searchID: searchID,
            requiredTrackSignature: requiredTrackSignature
        )

        // Manual search always includes a second title-only query. Provider
        // relevance is used for ordering only; weakly related results remain
        // visible so the user can choose alternate/live/aliased versions.
        if (!acceptFirstResult || collected.isEmpty), !submittedTitle.isEmpty,
           !Task.isCancelled,
           isCurrentSearch(searchID, requiredTrackSignature: requiredTrackSignature) {
            let broadRequest = ShioriLyricsSearchRequest(
                title: submittedTitle,
                artist: "",
                album: nil,
                duration: duration,
                limit: request.limit
            )
            let broadResults = await searchProviders(
                request: broadRequest,
                matcher: LyricsCandidateMatcher(request: broadRequest, referenceDocument: referenceDocument, mode: mode),
                searchID: searchID,
                requiredTrackSignature: requiredTrackSignature
            )
            collected = mergedSearchResults(collected + broadResults).sorted(by: preciseMatcher.sort)
        }

        guard !Task.isCancelled, isCurrentSearch(searchID, requiredTrackSignature: requiredTrackSignature) else { return }
        searchResults = collected
        if acceptFirstResult, shouldAcceptAutomaticSearchResult, let first = collected.first {
            acceptLyrics(first.document, sourceName: first.provider.rawValue, isManualSelection: false)
        }
    }

    /// Searches each configured provider without surfacing transient provider
    /// errors. Each attempt gets a short backoff so rate limits and flaky
    /// connections can recover before the broader title-only fallback is used.
    private func searchProviders(
        request: ShioriLyricsSearchRequest,
        matcher: LyricsCandidateMatcher,
        searchID: UUID?,
        requiredTrackSignature: String?
    ) async -> [LyricsSearchResult] {
        var collected: [LyricsSearchResult] = []

        for providerID in orderedProviders() {
            guard !Task.isCancelled,
                  isCurrentSearch(searchID, requiredTrackSignature: requiredTrackSignature),
                  let service = lyricsServices[providerID] else {
                return collected.sorted(by: matcher.sort)
            }

            let results = await searchWithRetry(service, request: request)
                .compactMap { matcher.evaluate($0) }
                .sorted(by: matcher.sort)
            guard !Task.isCancelled, isCurrentSearch(searchID, requiredTrackSignature: requiredTrackSignature) else {
                return collected.sorted(by: matcher.sort)
            }

            collected.append(contentsOf: results)
            let sorted = collected.sorted(by: matcher.sort)
            searchResults = sorted
        }

        return collected.sorted(by: matcher.sort)
    }

    private func searchWithRetry(
        _ service: LyricsSearchService,
        request: ShioriLyricsSearchRequest,
        maximumAttempts: Int = 2
    ) async -> [LyricsSearchResult] {
        for attempt in 0..<maximumAttempts where !Task.isCancelled {
            do {
                // An empty successful response is authoritative. Retrying it
                // only repeats the same public API request and delays fallback.
                return try await service.search(request)
            } catch {
                // The next retry or provider fallback is intentionally silent.
            }

            if attempt + 1 < maximumAttempts {
                try? await Task.sleep(for: .milliseconds(350 * (attempt + 1)))
            }
        }
        return []
    }

    private func mergedSearchResults(_ results: [LyricsSearchResult]) -> [LyricsSearchResult] {
        var seen: Set<String> = []
        return results.filter { result in
            let sample = result.document.lines.prefix(3).map(\.content).joined(separator: "\u{1f}")
            let key = [
                result.provider.rawValue,
                conversion.convert(result.title, mode: .simplified)
                    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current),
                conversion.convert(result.artist, mode: .simplified)
                    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current),
                String(Int((result.duration ?? 0).rounded())),
                sample,
            ].joined(separator: "\u{1e}")
            return seen.insert(key).inserted
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
            : .automaticSearch(cachedWithoutPlugin: true)
        copy.needsPersist = true
        applyDesktopLyricsColors(from: copy)
        if isManualSelection, let track {
            settings.noSearchingTrackIDs.remove(track.id)
        }
        currentLyrics = copy
        persistIfNeeded()
        updateCurrentLine()
        syncDesktopLyricsWindow()
    }

    func importLyrics(from url: URL) {
        do {
            acceptLyrics(try localLyricsStorage().importLyrics(from: url), sourceName: LyricsProviderID.local.rawValue)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func persistIfNeeded() {
        guard let track = playback.track,
              var document = currentLyrics,
              document.needsPersist else {
            return
        }
        do {
            document.desktopLyricsColors = currentDesktopLyricsColors()
            currentLyrics = document
            if document.selectionState.cacheSource == .manual {
                _ = try localLyricsStorage().save(document, for: track)
            }
            try sharedLyricsCache.save(document, for: track)
            currentLyrics?.needsPersist = false
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Saves the current desktop lyric appearance into the active LRCS file.
    func persistDesktopLyricsColors() {
        guard var document = currentLyrics else { return }
        document.desktopLyricsColors = currentDesktopLyricsColors()
        document.needsPersist = true
        currentLyrics = document
        persistIfNeeded()
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
            spotifyAccessPresentationState = .granted
            await refreshPlayback()
        } catch {
            spotifyAccessMessage = error.localizedDescription
            spotifyAccessPresentationState = {
                if case ServiceError.automationDenied = error { return .denied }
                return .error
            }()
            lastError = error.localizedDescription
        }
    }

    func refreshSpotifyAuthorizationStatus() async {
        guard let service = playerServices[.spotify] as? SpotifyAuthorizationService else { return }
        switch await service.authorizationStatus() {
        case .granted:
            spotifyAccessMessage = "Granted"
            spotifyAccessPresentationState = .granted
        case .denied:
            spotifyAccessMessage = "Denied"
            spotifyAccessPresentationState = .denied
        case .notRequested:
            spotifyAccessMessage = "Not requested"
            spotifyAccessPresentationState = .notRequested
        case .spotifyNotRunning:
            // Do not claim that access is missing merely because macOS cannot
            // inspect a target app which is not currently running.
            spotifyAccessMessage = "Open Spotify to check"
            spotifyAccessPresentationState = .spotifyNotRunning
        }
    }

    func markWrongLyrics() {
        guard let track = playback.track else { return }
        settings.noSearchingTrackIDs.insert(track.id)
        currentLyrics = nil
        currentLineIndex = nil
        searchTask?.cancel()
        activeSearchID = UUID()
        do {
            try sharedLyricsCache.hideLyrics(for: track)
        } catch {
            lastError = error.localizedDescription
        }
        syncDesktopLyricsWindow()
    }

    var hasManualLyricsSelection: Bool {
        currentLyrics?.selectionState.cacheSource == .manual
    }

    /// Removes the current track's persisted manual choice and resumes the
    /// normal plugin/cache/provider selection flow.
    func resetManualLyricsSelection() async {
        guard let track = playback.track, hasManualLyricsSelection else { return }

        searchTask?.cancel()
        activeSearchID = UUID()
        do {
            try localLyricsStorage().removeLyrics(for: track)
            try sharedLyricsCache.removeManualEntries(for: track)
        } catch {
            lastError = error.localizedDescription
            return
        }

        settings.noSearchingTrackIDs.remove(track.id)
        currentLyrics = nil
        currentLineIndex = nil
        searchResults = []
        loadCachedLyricsForCurrentTrack(track)
        syncDesktopLyricsWindow()

        guard playback.track?.signature == track.signature,
              !currentLyricsBlocksAutomaticSearch else {
            return
        }
        let searchID = activeSearchID
        await searchLyricsForCurrentTrack(searchID: searchID, trackSignature: track.signature)
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
                isPlaying: playback.status == .playing,
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
        switch settings.desktopLyricsColorPreset {
        case .custom:
            return .custom(using: settings)
        case .automatic:
            guard let artworkURL = playback.track?.albumArtworkURL, !artworkURL.isEmpty else {
                return DesktopLyricsColorPreset.aurora.previewPalette
            }
            if let preset = artworkPresetCache[artworkURL] {
                return preset.previewPalette
            }
            detectArtworkPreset(for: artworkURL)
            return DesktopLyricsColorPreset.aurora.previewPalette
        default:
            return settings.desktopLyricsColorPreset.previewPalette
        }
    }

    private func currentDesktopLyricsColors() -> DesktopLyricsColors {
        let palette = desktopLyricsPalette()
        return DesktopLyricsColors(
            preset: settings.desktopLyricsColorPreset.rawValue,
            unplayedColor: palette.pending.lrcsRGBAHex,
            playedColor: palette.played.lrcsRGBAHex,
            outlineColor: palette.shadow.lrcsRGBAHex
        )
    }

    private func applyDesktopLyricsColors(from document: LyricsDocument) {
        guard let colors = document.desktopLyricsColors else { return }
        if let preset = colors.preset.flatMap(DesktopLyricsColorPreset.init(rawValue:)) {
            settings.desktopLyricsColorPreset = preset
        }
        if let unplayed = Color(lrcsRGBAHex: colors.unplayedColor) {
            settings.desktopLyricsColor = unplayed
        }
        if let played = Color(lrcsRGBAHex: colors.playedColor) {
            settings.desktopLyricsProgressColor = played
        }
        if let outline = Color(lrcsRGBAHex: colors.outlineColor) {
            settings.desktopLyricsShadowColor = outline
        }
    }

    func syncDesktopLyricsWindow() {
        let hasDisplayLines = !desktopLyricsDisplayLines().isEmpty
        guard DesktopLyricsVisibilityPolicy.shouldShow(
            desktopLyricsEnabled: settings.desktopLyricsEnabled,
            hasDisplayLines: hasDisplayLines,
            hideWhenSpotifyIsFrontmost: settings.hideDesktopLyricsWhenSpotifyIsFrontmost,
            isSpotifyFrontmost: isSpotifyFrontmost
        ) else {
            desktopLyricsWindowController?.hide()
            return
        }

        if desktopLyricsWindowController == nil {
            desktopLyricsWindowController = DesktopLyricsWindowController(store: self)
        }

        desktopLyricsWindowController?.update()
        desktopLyricsWindowController?.show()
    }

    func setDesktopLyricsCenter(screenFrame: NSRect, center: NSPoint) {
        guard screenFrame.width > 0, screenFrame.height > 0 else { return }
        // Keep the exact dragged location, including positions over the Dock or
        // partially outside the display. Clamping here made the panel jump back
        // during the next playback refresh.
        let xFactor = (center.x - screenFrame.minX) / screenFrame.width
        let yFactor = 1 - ((center.y - screenFrame.minY) / screenFrame.height)
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

    private func detectArtworkPreset(for artworkURL: String) {
        guard artworkPresetTasks[artworkURL] == nil,
              let url = URL(string: artworkURL) else { return }

        artworkPresetTasks[artworkURL] = Task { [weak self] in
            defer { self?.artworkPresetTasks[artworkURL] = nil }
            guard let self else { return }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200..<300).contains(httpResponse.statusCode),
                      !Task.isCancelled else { return }
                self.artworkPresetCache[artworkURL] = Self.closestPreset(to: data)
            } catch {
                // Keep the readable Aurora fallback when Spotify's artwork is unavailable.
            }
        }
    }

    private static func closestPreset(to artworkData: Data) -> DesktopLyricsColorPreset {
        guard let source = CGImageSourceCreateWithData(artworkData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let profile = dominantColourProfile(in: image) else {
            return .aurora
        }

        guard profile.saturation >= 0.16 else { return .aurora }
        let candidates: [(DesktopLyricsColorPreset, Double)] = [
            (.aurora, 0.54),
            (.orchid, 0.76),
            (.meadow, 0.37),
            (.sunset, 0.10),
            (.rose, 0.94),
        ]
        return candidates.min { circularHueDistance(profile.hue, $0.1) < circularHueDistance(profile.hue, $1.1) }?.0 ?? .aurora
    }

    private static func dominantColourProfile(in image: CGImage) -> (hue: Double, saturation: Double)? {
        let side = 32
        let bytesPerPixel = 4
        var pixels = [UInt8](repeating: 0, count: side * side * bytesPerPixel)
        guard let context = CGContext(
            data: &pixels,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * bytesPerPixel,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))

        var weightedHueX = 0.0
        var weightedHueY = 0.0
        var weightedSaturation = 0.0
        var weightTotal = 0.0
        for pixel in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
            let red = Double(pixels[pixel]) / 255
            let green = Double(pixels[pixel + 1]) / 255
            let blue = Double(pixels[pixel + 2]) / 255
            let maximum = max(red, green, blue)
            let minimum = min(red, green, blue)
            let delta = maximum - minimum
            guard delta > 0.02, maximum > 0.08 else { continue }

            let saturation = delta / maximum
            let hue: Double
            if maximum == red {
                hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
            } else if maximum == green {
                hue = (blue - red) / delta + 2
            } else {
                hue = (red - green) / delta + 4
            }
            let normalizedHue = (hue < 0 ? hue + 6 : hue) / 6
            let weight = saturation * (0.25 + maximum * 0.75)
            weightedHueX += cos(normalizedHue * 2 * .pi) * weight
            weightedHueY += sin(normalizedHue * 2 * .pi) * weight
            weightedSaturation += saturation * weight
            weightTotal += weight
        }

        guard weightTotal > 0 else { return nil }
        let angle = atan2(weightedHueY, weightedHueX)
        let hue = (angle < 0 ? angle + 2 * .pi : angle) / (2 * .pi)
        return (hue, weightedSaturation / weightTotal)
    }

    private static func circularHueDistance(_ lhs: Double, _ rhs: Double) -> Double {
        min(abs(lhs - rhs), 1 - abs(lhs - rhs))
    }

    private func orderedProviders() -> [LyricsProviderID] {
        let enabled = settings.enabledProviders
        return [.qqMusic, .netease].filter { enabled.contains($0) }
    }

    private func localLyricsStorage() -> LocalLyricsStorage {
        let path = settings.lyricsSavingPath
        return LocalLyricsStorage(baseDirectory: path.url, isSecurityScoped: path.securityScoped)
    }

    private func loadCachedLyricsForCurrentTrack(_ track: TrackIdentity) {
        do {
            if let local = try localLyricsStorage().loadLyrics(for: track) {
                useCachedLyrics(
                    local,
                    for: track,
                    persistLocal: false,
                    syncShared: settings.connectFullScreenPlaying && local.selectionState.cacheSource == .manual
                )
                return
            }

            // The bridge is an additional producer, not the only reader. A
            // restarted desktop app must immediately reuse lyrics that the
            // extension has already cached instead of waiting for another POST.
            if let shared = try sharedLyricsCache.loadDocument(for: track) {
                useCachedLyrics(shared, for: track, persistLocal: false, syncShared: false)
                return
            }

        } catch {
            lastError = error.localizedDescription
        }
    }

    private func useCachedLyrics(_ document: LyricsDocument, for track: TrackIdentity, persistLocal: Bool, syncShared: Bool) {
        let copy = settings.filter.apply(to: LyricsContentNormalizer.removingLeadingMetadata(from: document, track: track))
        applyDesktopLyricsColors(from: copy)
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
        if entry.hidden == true {
            guard playback.track?.id == entry.trackUri else { return }
            currentLyrics = nil
            currentLineIndex = nil
            searchTask?.cancel()
            activeSearchID = UUID()
            syncDesktopLyricsWindow()
            return
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
        refreshFullScreenPlayingPluginConnectionStatus()
        Task { await currentTrackChanged() }
    }

    private func syncFullScreenPlayingConnection() {
        if settings.connectFullScreenPlaying {
            sharedLyricsCacheServer.start()
        } else {
            sharedLyricsCacheServer.stop()
        }
    }

    private func refreshFullScreenPlayingPluginConnectionStatus() {
        isFullScreenPlayingPluginConnected = settings.connectFullScreenPlaying
            && sharedLyricsCacheServer.hasActiveConnection()
    }

    private func persistLocalLyrics(_ document: LyricsDocument, for track: TrackIdentity) {
        guard document.selectionState.cacheSource == .manual else { return }
        do {
            var copy = document
            if copy.desktopLyricsColors == nil {
                copy.desktopLyricsColors = currentDesktopLyricsColors()
            }
            _ = try localLyricsStorage().save(copy, for: track)
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
              conversion.convert(
                  track.title.trimmingCharacters(in: .whitespacesAndNewlines),
                  mode: .simplified
              ).caseInsensitiveCompare(request.title) == .orderedSame,
              conversion.convert(
                  track.artist.trimmingCharacters(in: .whitespacesAndNewlines),
                  mode: .simplified
              ).caseInsensitiveCompare(request.artist) == .orderedSame else {
            return nil
        }
        return try? sharedLyricsCache.loadDocument(for: track, kind: .spotify)
    }

}

enum DesktopLyricsVisibilityPolicy {
    private static let spotifyBundleIdentifier = "com.spotify.client"

    static func isSpotifyFrontmost(bundleIdentifier: String?) -> Bool {
        bundleIdentifier == spotifyBundleIdentifier
    }

    static func shouldShow(
        desktopLyricsEnabled: Bool,
        hasDisplayLines: Bool,
        hideWhenSpotifyIsFrontmost: Bool,
        isSpotifyFrontmost: Bool
    ) -> Bool {
        desktopLyricsEnabled
            && hasDisplayLines
            && !(hideWhenSpotifyIsFrontmost && isSpotifyFrontmost)
    }
}

private extension Color {
    var lrcsRGBAHex: String {
        guard let color = NSColor(self).usingColorSpace(.sRGB) else { return "#FFFFFFFF" }
        return String(
            format: "#%02X%02X%02X%02X",
            Int((color.redComponent * 255).rounded()),
            Int((color.greenComponent * 255).rounded()),
            Int((color.blueComponent * 255).rounded()),
            Int((color.alphaComponent * 255).rounded())
        )
    }

    init?(lrcsRGBAHex value: String) {
        let hex = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6 || hex.count == 8,
              let encoded = UInt64(hex, radix: 16) else { return nil }
        let alpha = hex.count == 8 ? Double(encoded & 0xFF) / 255 : 1
        let red = Double((encoded >> (hex.count == 8 ? 24 : 16)) & 0xFF) / 255
        let green = Double((encoded >> (hex.count == 8 ? 16 : 8)) & 0xFF) / 255
        let blue = Double((encoded >> (hex.count == 8 ? 8 : 0)) & 0xFF) / 255
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}
