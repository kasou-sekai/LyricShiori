import AppKit
import SwiftUI

@MainActor
final class DesktopLyricsWindowController {
    private let store: LyricShioriStore
    private let panel: DesktopLyricsPanel
    private let hostingController: NSHostingController<DesktopLyricsView>
    private var pointerTrackingTask: Task<Void, Never>?

    init(store: LyricShioriStore) {
        self.store = store
        self.hostingController = NSHostingController(rootView: DesktopLyricsView(store: store))
        self.panel = DesktopLyricsPanel(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 150),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hostingController
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isOpaque = false
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.store = store
    }

    func show() {
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        updatePointerTracking()
    }

    func hide() {
        stopPointerTracking()
        setPointerOverLyrics(false)
        if panel.isVisible {
            panel.orderOut(nil)
        }
    }

    func update() {
        // The root view already observes `store`. Replacing it during each player
        // refresh resets TimelineView and interrupts lyric animations.
        let mousePassthrough = store.settings.desktopLyricsMousePassthrough
        panel.isDraggable = store.settings.desktopLyricsDraggable && !mousePassthrough
        panel.sharingType = store.settings.disableLyricsWhenScreenShot ? .none : .readOnly
        if !panel.isUserDragging {
            let targetFrame = frameForCurrentSettings()
            if panel.frame != targetFrame {
                panel.setFrame(targetFrame, display: true)
            }
        }
        updatePointerTracking()
        applyMouseEventPolicy()
    }

    private func updatePointerTracking() {
        guard panel.isVisible, store.settings.hideLyricsWhenMousePassingBy else {
            stopPointerTracking()
            setPointerOverLyrics(false)
            return
        }
        refreshPointerState()
        guard pointerTrackingTask == nil else { return }
        pointerTrackingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.refreshPointerState()
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private func stopPointerTracking() {
        pointerTrackingTask?.cancel()
        pointerTrackingTask = nil
    }

    private func refreshPointerState() {
        let isInside = panel.isVisible
            && store.settings.hideLyricsWhenMousePassingBy
            && panel.frame.contains(NSEvent.mouseLocation)
        setPointerOverLyrics(isInside)
    }

    private func setPointerOverLyrics(_ isInside: Bool) {
        guard store.isPointerOverDesktopLyrics != isInside else { return }
        store.isPointerOverDesktopLyrics = isInside
        applyMouseEventPolicy()
    }

    private func applyMouseEventPolicy() {
        panel.ignoresMouseEvents = DesktopLyricsMousePolicy.ignoresMouseEvents(
            mousePassthrough: store.settings.desktopLyricsMousePassthrough,
            draggable: store.settings.desktopLyricsDraggable,
            hideWhenPointerPasses: store.settings.hideLyricsWhenMousePassingBy,
            pointerIsInside: store.isPointerOverDesktopLyrics
        )
    }

    private func frameForCurrentSettings() -> NSRect {
        let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let fontSize = store.settings.desktopLyricsFontSize
        let displayLines = store.desktopLyricsDisplayLines()
        let lineCount = max(1, displayLines.count)
        let maxWidth = max(1, screenFrame.width - 64)
        let maxHeight = max(1, screenFrame.height - 64)
        let width: Double
        let height: Double
        if store.settings.desktopLyricsVerticalLayout {
            // Vertical lyrics transpose the horizontal layout: the configured
            // lyric width becomes the fixed reading height, while the window
            // width grows only with the number of visible lyric columns.
            width = min(DesktopLyricsLayout.verticalTotalWidth(for: fontSize, lineCount: lineCount), maxWidth)
            height = min(store.settings.desktopLyricsWidth, maxHeight)
        } else {
            width = min(store.settings.desktopLyricsWidth, max(280, maxWidth))
            height = min(DesktopLyricsLayout.totalHeight(for: fontSize, lineCount: lineCount), maxHeight)
        }
        let x = screenFrame.minX + screenFrame.width * store.settings.desktopLyricsXPositionFactor - width / 2
        let y = screenFrame.minY + screenFrame.height * (1 - store.settings.desktopLyricsYPositionFactor) - height / 2
        return NSRect(x: x, y: y, width: width, height: height)
    }
}

enum DesktopLyricsMousePolicy {
    static func ignoresMouseEvents(
        mousePassthrough: Bool,
        draggable: Bool,
        hideWhenPointerPasses: Bool,
        pointerIsInside: Bool
    ) -> Bool {
        mousePassthrough
            || (hideWhenPointerPasses && pointerIsInside)
            || (!draggable && !hideWhenPointerPasses)
    }
}

enum DesktopLyricsLayout {
    static func slotHeight(for fontSize: Double) -> Double {
        max(fontSize * 1.24, 28)
    }

    static func glyphStackHeight(for fontSize: Double, lineCount: Int) -> Double {
        let activeLineHeight = max(fontSize * 1.58, 30)
        return activeLineHeight + slotHeight(for: fontSize) * Double(max(0, lineCount - 1))
    }

    static func verticalPadding(for fontSize: Double) -> Double {
        max(4, fontSize * 0.16)
    }

    static func totalHeight(for fontSize: Double, lineCount: Int) -> Double {
        glyphStackHeight(for: fontSize, lineCount: lineCount) + verticalPadding(for: fontSize) * 2
    }

    static func horizontalPadding(for fontSize: Double) -> Double {
        max(8, fontSize * 0.35)
    }

    static func verticalColumnWidth(for fontSize: Double) -> Double {
        max(fontSize * 1.58, 30)
    }

    static func verticalColumnSlotWidth(for fontSize: Double) -> Double {
        max(fontSize * 1.24, 28)
    }

    static func verticalTotalWidth(for fontSize: Double, lineCount: Int) -> Double {
        verticalColumnWidth(for: fontSize)
            + verticalColumnSlotWidth(for: fontSize) * Double(max(0, lineCount - 1))
            + horizontalPadding(for: fontSize) * 2
    }
}

@MainActor
private final class DesktopLyricsPanel: NSPanel {
    weak var store: LyricShioriStore?
    var isDraggable = true
    var isUserDragging: Bool { dragStartMouseLocation != nil }
    private var dragStartMouseLocation: NSPoint?
    private var dragStartFrame: NSRect?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func mouseDown(with event: NSEvent) {
        guard isDraggable else {
            super.mouseDown(with: event)
            return
        }
        dragStartMouseLocation = NSEvent.mouseLocation
        dragStartFrame = frame
        store?.isDesktopLyricsDragging = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDraggable,
              let dragStartMouseLocation,
              let dragStartFrame else {
            super.mouseDragged(with: event)
            return
        }
        let mouse = NSEvent.mouseLocation
        let proposedOrigin = NSPoint(
            x: dragStartFrame.origin.x + mouse.x - dragStartMouseLocation.x,
            y: dragStartFrame.origin.y + mouse.y - dragStartMouseLocation.y
        )
        let screenFrame = (screen ?? NSScreen.main)?.frame ?? dragStartFrame
        setFrameOrigin(proposedOrigin)
        store?.setDesktopLyricsCenter(
            screenFrame: screenFrame,
            center: NSPoint(x: frame.midX, y: frame.midY)
        )
    }

    override func mouseUp(with event: NSEvent) {
        dragStartMouseLocation = nil
        dragStartFrame = nil
        store?.isDesktopLyricsDragging = false
        store?.syncDesktopLyricsWindow()
    }
}
