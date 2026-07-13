import AppKit
import Observation
import SwiftUI

@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let store: LyricShioriStore
    private let popover: NSPopover
    private var logoStatusItem: NSStatusItem?
    private var lyricsStatusItem: NSStatusItem?
    private var lyricsHostingView: StatusItemHostingView<MenuBarLyricsTicker>?
    private weak var popoverAnchor: NSStatusBarButton?

    init(store: LyricShioriStore) {
        self.store = store

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: StatusMenuView(store: store))
        self.popover = popover

        super.init()
        popover.delegate = self
        observeStore()
    }

    func popoverDidClose(_ notification: Notification) {
        popoverAnchor = nil
    }

    private func observeStore() {
        let presentation = withObservationTracking {
            currentPresentation()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeStore()
            }
        }
        apply(presentation)
    }

    private func currentPresentation() -> MenuBarPresentation {
        let mode = store.settings.menuBarDisplayMode
        return MenuBarPresentation(
            mode: mode,
            lyrics: currentLyrics(for: mode),
            lyricsWidth: store.settings.menuBarLyricsMaxWidth
        )
    }

    private func currentLyrics(for mode: MenuBarDisplayMode) -> MenuBarLyric? {
        guard store.settings.menuBarLyricsEnabled,
              store.shouldDisplayLyrics,
              mode != .hidden || store.playback.status == .playing,
              let lyrics = store.currentLyrics,
              let index = store.currentLineIndex,
              lyrics.lines.indices.contains(index) else {
            return nil
        }

        let text = store.originalLineText(for: lyrics.lines[index])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let line = lyrics.lines[index]
        let lineEnd = lyrics.lines[(index + 1)...].first?.position
            ?? line.wordTimings.last.flatMap { timing in
                timing.duration.map { timing.start + $0 }
            }
            ?? store.playback.track?.duration
            ?? line.position + 3
        return MenuBarLyric(
            id: "\(lyrics.id.uuidString)-\(line.id.uuidString)-\(index)",
            text: text,
            lineStart: line.position,
            lineEnd: lineEnd,
            playback: store.playback,
            adjustedDelay: lyrics.adjustedDelay
        )
    }

    private func apply(_ presentation: MenuBarPresentation) {
        let showsLyrics = presentation.lyrics != nil
        let showsLogo: Bool
        switch presentation.mode {
        case .separated:
            showsLogo = true
        case .combined:
            showsLogo = !showsLyrics
        case .hidden:
            showsLogo = false
        }

        if showsLogo {
            showLogoStatusItem()
        } else {
            removeLogoStatusItem()
        }

        if let lyrics = presentation.lyrics {
            showLyricsStatusItem(lyrics, width: presentation.lyricsWidth)
        } else {
            removeLyricsStatusItem()
        }
    }

    private func showLogoStatusItem() {
        let statusItem = logoStatusItem ?? makeStatusItem()
        logoStatusItem = statusItem
        statusItem.length = NSStatusItem.squareLength

        guard let button = statusItem.button else { return }
        button.title = ""
        button.image = MenuBarLogo.image
        button.imagePosition = .imageOnly
        button.toolTip = "LyricShiori"
        button.setAccessibilityLabel("LyricShiori")
    }

    private func showLyricsStatusItem(_ lyrics: MenuBarLyric, width: Double) {
        let statusItem = lyricsStatusItem ?? makeStatusItem()
        lyricsStatusItem = statusItem
        statusItem.length = lyricsStatusItemLength(for: lyrics.text, maximumWidth: width)

        guard let button = statusItem.button else { return }
        button.title = ""
        button.image = nil
        button.imagePosition = .noImage
        button.alignment = .left
        button.toolTip = lyrics.text
        button.setAccessibilityLabel("LyricShiori lyrics")

        let ticker = MenuBarLyricsTicker(lyric: lyrics)
        if let lyricsHostingView {
            lyricsHostingView.rootView = ticker
        } else {
            let lyricsHostingView = StatusItemHostingView(rootView: ticker)
            lyricsHostingView.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(lyricsHostingView)
            NSLayoutConstraint.activate([
                lyricsHostingView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                lyricsHostingView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                lyricsHostingView.topAnchor.constraint(equalTo: button.topAnchor),
                lyricsHostingView.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            ])
            self.lyricsHostingView = lyricsHostingView
        }
    }

    private func lyricsStatusItemLength(for text: String, maximumWidth: Double) -> CGFloat {
        let maximumWidth = CGFloat(min(max(maximumWidth, 80), 600))
        let font = NSFont.systemFont(ofSize: MenuBarLyricsTicker.fontSize)
        let textWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        // Keep a small click target around short lyrics while letting the
        // configured value act purely as an upper limit.
        let naturalWidth = max(NSStatusItem.squareLength, textWidth + 8)
        return min(naturalWidth, maximumWidth)
    }

    private func makeStatusItem() -> NSStatusItem {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover(_:))
        return statusItem
    }

    private func removeLogoStatusItem() {
        guard let statusItem = logoStatusItem else { return }
        remove(statusItem)
        logoStatusItem = nil
    }

    private func removeLyricsStatusItem() {
        guard let statusItem = lyricsStatusItem else { return }
        remove(statusItem)
        lyricsStatusItem = nil
        lyricsHostingView = nil
    }

    private func remove(_ statusItem: NSStatusItem) {
        if let button = statusItem.button, popoverAnchor === button {
            popover.performClose(nil)
        }
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = sender as? NSStatusBarButton else { return }

        if popover.isShown, popoverAnchor === button {
            popover.performClose(nil)
            return
        }

        popoverAnchor = button
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
}

private final class StatusItemHostingView<Content: View>: NSHostingView<Content> {
    /// The status-bar button remains the hit-test target, so clicking the
    /// scrolling text opens the same popover as clicking the logo.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private struct MenuBarLyricsTicker: View {
    static let fontSize = NSFont.systemFontSize

    var lyric: MenuBarLyric
    @State private var contentWidth: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let viewportWidth = proxy.size.width
            let overflow = max(0, contentWidth - viewportWidth)

            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !lyric.isPlaying)) { context in
                Text(lyric.text)
                    .font(.system(size: Self.fontSize))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .background(
                        GeometryReader { contentProxy in
                            Color.clear.preference(
                                key: MenuBarLyricsWidthPreferenceKey.self,
                                value: contentProxy.size.width
                            )
                        }
                    )
                    .offset(
                        x: overflow > 1
                            ? -overflow * timedScrollPhase(at: context.date)
                            : 0
                    )
                    .frame(width: viewportWidth, height: proxy.size.height, alignment: .leading)
                    .clipped()
            }
        }
        .onPreferenceChange(MenuBarLyricsWidthPreferenceKey.self) { width in
            guard abs(contentWidth - width) > 0.5 else { return }
            contentWidth = width
        }
    }

    private func timedScrollPhase(at date: Date) -> CGFloat {
        let progress = lyric.progress(at: date)
        let duration = lyric.lineEnd - lyric.lineStart
        guard duration > 0.2 else { return CGFloat(progress) }

        let startHold = min(0.45, max(0.18, duration * 0.10))
        let endHold = min(0.65, max(0.20, duration * 0.08))
        let movingDuration = max(0.12, duration - startHold - endHold)
        let currentTime = progress * duration
        return CGFloat(min(max((currentTime - startHold) / movingDuration, 0), 1))
    }
}

private struct MenuBarLyricsWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct MenuBarPresentation {
    var mode: MenuBarDisplayMode
    var lyrics: MenuBarLyric?
    var lyricsWidth: Double
}

private struct MenuBarLyric {
    var id: String
    var text: String
    var lineStart: TimeInterval
    var lineEnd: TimeInterval
    var playback: PlaybackSnapshot
    var adjustedDelay: TimeInterval

    var isPlaying: Bool {
        playback.status == .playing
    }

    func progress(at date: Date) -> Double {
        let playbackTime: TimeInterval
        if playback.status == .playing {
            playbackTime = playback.elapsedTime + date.timeIntervalSince(playback.capturedAt) + adjustedDelay
        } else {
            playbackTime = playback.elapsedTime + adjustedDelay
        }
        guard lineEnd > lineStart else { return 1 }
        return min(max((playbackTime - lineStart) / (lineEnd - lineStart), 0), 1)
    }
}

private enum MenuBarLogo {
    static let image: NSImage? = {
        guard let url = Bundle.module.url(forResource: "emoji-bookmark-template", withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            return NSImage(systemSymbolName: "bookmark.fill", accessibilityDescription: "LyricShiori")
        }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }()
}
