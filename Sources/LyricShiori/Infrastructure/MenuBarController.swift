import AppKit
import Observation
import SwiftUI

@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let store: LyricShioriStore
    private let popover: NSPopover
    private var logoStatusItem: NSStatusItem?
    private var lyricsStatusItem: NSStatusItem?
    private var lyricsTickerView: MenuBarLyricsTickerView?
    private weak var popoverAnchor: NSView?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?

    init(store: LyricShioriStore) {
        self.store = store

        let popover = NSPopover()
        popover.behavior = .transient
        let contentController = NSHostingController(rootView: StatusMenuView(store: store))
        // The current-track summary grows when lyrics are present. Let AppKit
        // observe SwiftUI's preferred size so the popover is remeasured instead
        // of retaining the shorter, no-lyrics height and clipping both ends.
        contentController.sizingOptions = [.preferredContentSize]
        popover.contentViewController = contentController
        self.popover = popover

        super.init()
        popover.delegate = self
        observeStore()
    }

    func popoverDidClose(_ notification: Notification) {
        stopOutsideClickMonitoring()
        popoverAnchor = nil
    }

    private func startOutsideClickMonitoring() {
        guard localMouseMonitor == nil, globalMouseMonitor == nil else { return }
        let mouseDownEvents: NSEvent.EventTypeMask = [
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
        ]
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseDownEvents) { [weak self] event in
            // Local monitors run on AppKit's main event loop. Keep the original
            // event so the clicked control/window still receives it.
            MainActor.assumeIsolated {
                self?.closePopoverIfClickIsOutside(at: NSEvent.mouseLocation)
            }
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseDownEvents) { [weak self] _ in
            let location = NSEvent.mouseLocation
            Task { @MainActor [weak self] in
                self?.closePopoverIfClickIsOutside(at: location)
            }
        }
    }

    private func stopOutsideClickMonitoring() {
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
    }

    private func closePopoverIfClickIsOutside(at location: NSPoint) {
        guard popover.isShown else {
            stopOutsideClickMonitoring()
            return
        }
        let popoverFrame = popover.contentViewController?.view.window?.frame
        let anchorFrame = popoverAnchor.flatMap { anchor -> NSRect? in
            guard let window = anchor.window else { return nil }
            return window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        }
        guard MenuBarPopoverDismissalPolicy.shouldDismiss(
            clickLocation: location,
            popoverFrame: popoverFrame,
            anchorFrame: anchorFrame
        ) else {
            return
        }
        popover.performClose(nil)
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

        if let lyricsTickerView {
            lyricsTickerView.lyric = lyrics
        } else {
            let lyricsTickerView = MenuBarLyricsTickerView(lyric: lyrics)
            lyricsTickerView.onClick = { [weak self] view in
                self?.togglePopover(view)
            }
            // NSStatusItem's custom-view path is the only AppKit API that
            // redirects drawing through each secondary menu bar's inactive
            // appearance. A subview added to `button` is cloned verbatim.
            statusItem.view = lyricsTickerView
            self.lyricsTickerView = lyricsTickerView
        }

        let tickerHeight = statusItem.statusBar?.thickness ?? NSStatusBar.system.thickness
        lyricsTickerView?.frame = NSRect(
            x: 0,
            y: 0,
            width: statusItem.length,
            height: tickerHeight
        )
        lyricsTickerView?.toolTip = lyrics.text
        lyricsTickerView?.setAccessibilityElement(true)
        lyricsTickerView?.setAccessibilityRole(.button)
        lyricsTickerView?.setAccessibilityLabel("LyricShiori lyrics")
    }

    private func lyricsStatusItemLength(for text: String, maximumWidth: Double) -> CGFloat {
        let maximumWidth = CGFloat(min(max(maximumWidth, 80), 600))
        let font = NSFont.systemFont(ofSize: MenuBarLyricsTickerLayout.fontSize)
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
        lyricsTickerView?.stopAnimating()
        remove(statusItem)
        lyricsStatusItem = nil
        lyricsTickerView = nil
    }

    private func remove(_ statusItem: NSStatusItem) {
        if popoverAnchor === statusItem.button || popoverAnchor === statusItem.view {
            popover.performClose(nil)
        }
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let anchor = sender as? NSView else { return }

        if popover.isShown, popoverAnchor === anchor {
            popover.performClose(nil)
            return
        }

        popoverAnchor = anchor
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        startOutsideClickMonitoring()
    }
}

enum MenuBarPopoverDismissalPolicy {
    static func shouldDismiss(
        clickLocation: NSPoint,
        popoverFrame: NSRect?,
        anchorFrame: NSRect?
    ) -> Bool {
        if popoverFrame?.contains(clickLocation) == true {
            return false
        }
        if anchorFrame?.contains(clickLocation) == true {
            return false
        }
        return true
    }
}

private final class MenuBarLyricsTickerView: NSView {
    fileprivate var lyric: MenuBarLyric {
        didSet {
            updateAnimationTimer()
            needsDisplay = true
        }
    }

    private var animationTimer: Timer?
    fileprivate var onClick: ((NSView) -> Void)?

    init(lyric: MenuBarLyric) {
        self.lyric = lyric
        super.init(frame: .zero)
        // Secondary menu bars render a redirected clone of a status item's
        // drawing. Keeping this view non-layer-backed lets AppKit apply the
        // inactive-screen appearance to that clone instead of copying an
        // already composited SwiftUI layer.
        wantsLayer = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAnimationTimer()
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        self
    }

    override func mouseDown(with event: NSEvent) {
        onClick?(self)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard bounds.width > 0, bounds.height > 0 else { return }

        let font = NSFont.systemFont(ofSize: MenuBarLyricsTickerLayout.fontSize)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ]
        let text = lyric.text as NSString
        let textSize = text.size(withAttributes: attributes)
        let horizontalPadding: CGFloat = 4
        let contentWidth = textSize.width + horizontalPadding * 2
        let overflow = max(0, contentWidth - bounds.width)
        let x = horizontalPadding - overflow * timedScrollPhase(at: Date())
        let y = MenuBarLyricsTickerLayout.verticallyCenteredOrigin(
            contentHeight: textSize.height,
            viewportHeight: bounds.height
        )

        // NSView drawing is redirected separately for every menu bar clone.
        // Clip in the current drawing context so a clone uses its own viewport
        // and scale rather than the geometry of the focused screen's layer.
        NSGraphicsContext.saveGraphicsState()
        bounds.clip()
        text.draw(at: NSPoint(x: x, y: y), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateAnimationTimer()
    }

    private func updateAnimationTimer() {
        let width = (lyric.text as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: MenuBarLyricsTickerLayout.fontSize),
        ]).width + 8
        guard window != nil, lyric.isPlaying, width > bounds.width,
              timedScrollPhase(at: Date()) < 1 else { stopAnimating(); return }
        guard animationTimer == nil else { return }

        let timer = Timer(
            timeInterval: 1.0 / 60.0,
            target: self,
            selector: #selector(animationTimerDidFire(_:)),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    fileprivate func stopAnimating() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    @objc private func animationTimerDidFire(_ timer: Timer) {
        needsDisplay = true
        if timedScrollPhase(at: Date()) >= 1 { stopAnimating() }
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

enum MenuBarLyricsTickerLayout {
    static let fontSize = NSFont.systemFontSize

    static func verticallyCenteredOrigin(
        contentHeight: CGFloat,
        viewportHeight: CGFloat
    ) -> CGFloat {
        max(0, floor((viewportHeight - contentHeight) / 2))
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
        // Packaged apps keep resources in Contents/Resources. The SwiftPM
        // module bundle remains the fallback for command-line/dev builds.
        let url = Bundle.main.url(forResource: "emoji-bookmark-template", withExtension: "png")
            ?? Bundle.module.url(forResource: "emoji-bookmark-template", withExtension: "png")
        guard let url,
              let image = NSImage(contentsOf: url) else {
            return NSImage(systemSymbolName: "bookmark.fill", accessibilityDescription: "LyricShiori")
        }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }()
}
