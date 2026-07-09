import AppKit
import SwiftUI

@MainActor
final class DesktopLyricsWindowController {
    private let store: LyricShioriStore
    private let panel: DesktopLyricsPanel
    private let hostingController: NSHostingController<DesktopLyricsView>

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
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    func update() {
        hostingController.rootView = DesktopLyricsView(store: store)
        panel.isDraggable = store.settings.desktopLyricsDraggable
        panel.sharingType = store.settings.disableLyricsWhenScreenShot ? .none : .readOnly
        panel.ignoresMouseEvents = !store.settings.desktopLyricsDraggable && !store.settings.hideLyricsWhenMousePassingBy
        panel.setFrame(frameForCurrentSettings(), display: true)
    }

    private func frameForCurrentSettings() -> NSRect {
        let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first
        let screenFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let fontSize = store.settings.desktopLyricsFontSize
        let hasSecondLine = !store.desktopLyricsLines().second.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let width = min(max(620, fontSize * 24), max(320, screenFrame.width - 48))
        let lineCountFactor = hasSecondLine ? 3.35 : 2.35
        let height = min(max(92, fontSize * lineCountFactor), max(92, screenFrame.height * 0.28))
        let x = screenFrame.minX + screenFrame.width * store.settings.desktopLyricsXPositionFactor - width / 2
        let y = screenFrame.minY + screenFrame.height * (1 - store.settings.desktopLyricsYPositionFactor) - height / 2
        let clampedX = x.clamped(to: screenFrame.minX ... max(screenFrame.minX, screenFrame.maxX - width))
        let clampedY = y.clamped(to: screenFrame.minY ... max(screenFrame.minY, screenFrame.maxY - height))
        return NSRect(x: clampedX, y: clampedY, width: width, height: height)
    }
}

@MainActor
private final class DesktopLyricsPanel: NSPanel {
    weak var store: LyricShioriStore?
    var isDraggable = true
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
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDraggable,
              let dragStartMouseLocation,
              let dragStartFrame else {
            super.mouseDragged(with: event)
            return
        }
        let mouse = NSEvent.mouseLocation
        let origin = NSPoint(
            x: dragStartFrame.origin.x + mouse.x - dragStartMouseLocation.x,
            y: dragStartFrame.origin.y + mouse.y - dragStartMouseLocation.y
        )
        setFrameOrigin(origin)
        let screenFrame = (screen ?? NSScreen.main)?.visibleFrame ?? dragStartFrame
        store?.setDesktopLyricsCenter(
            screenFrame: screenFrame,
            center: NSPoint(x: frame.midX, y: frame.midY)
        )
    }

    override func mouseUp(with event: NSEvent) {
        dragStartMouseLocation = nil
        dragStartFrame = nil
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
