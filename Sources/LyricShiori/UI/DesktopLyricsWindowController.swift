import AppKit
import Darwin
import SwiftUI

@MainActor
final class DesktopLyricsWindowController {
    private static var allSpacesBehavior: NSWindow.CollectionBehavior {
        var behavior: NSWindow.CollectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
        ]
        if #available(macOS 26.0, *) {
            behavior.insert(.canJoinAllApplications)
        } else {
            behavior.insert(.fullScreenAuxiliary)
        }
        return behavior
    }

    private let store: LyricShioriStore
    private let membershipRepairer = DesktopLyricsSpaceMembershipRepairer()
    private let panel: DesktopLyricsPanel
    private let hostingController: NSHostingController<DesktopLyricsView>
    private var localPointerMonitor: Any?
    private var globalPointerMonitor: Any?
    private var spaceRepairTask: Task<Void, Never>?
    private var activeSpaceObserver: NSObjectProtocol?
    private var shouldBeVisible = false

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
        panel.acceptsMouseMovedEvents = true
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isOpaque = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = Self.allSpacesBehavior
        panel.store = store

        activeSpaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.activeSpaceDidChange()
            }
        }
    }

    isolated deinit {
        stopPointerTracking()
        if let activeSpaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activeSpaceObserver)
        }
    }

    func show() {
        shouldBeVisible = true
        if !panel.isVisible {
            panel.orderFrontRegardless()
            repairSpaceMembership()
        }
        updatePointerTracking()
    }

    func hide() {
        shouldBeVisible = false
        spaceRepairTask?.cancel()
        spaceRepairTask = nil
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

    private func activeSpaceDidChange() {
        guard shouldBeVisible else { return }

        // WindowServer rebuilds Space membership during the switching
        // animation. Match Butai's approach: wait until that transition has
        // settled, then explicitly restore this panel's membership in every
        // current Space. A second pass covers longer full-screen transitions.
        spaceRepairTask?.cancel()
        spaceRepairTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(420))
            guard !Task.isCancelled, let self, self.shouldBeVisible else { return }
            self.repairSpaceMembership()
            self.panel.orderFrontRegardless()
            self.updatePointerTracking()

            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled, self.shouldBeVisible else { return }
            if !self.panel.isOnActiveSpace {
                self.repairSpaceMembership()
            }
            self.panel.orderFrontRegardless()
            self.updatePointerTracking()
        }
    }

    private func repairSpaceMembership() {
        panel.collectionBehavior = Self.allSpacesBehavior
        _ = membershipRepairer.addWindowToAllSpaces(windowNumber: panel.windowNumber)
    }

    private func updatePointerTracking() {
        guard panel.isVisible, store.settings.hideLyricsWhenMousePassingBy else {
            stopPointerTracking()
            setPointerOverLyrics(false)
            return
        }
        refreshPointerState()
        guard localPointerMonitor == nil, globalPointerMonitor == nil else { return }
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        localPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            MainActor.assumeIsolated { self?.refreshPointerState() }
            return event
        }
        globalPointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshPointerState() }
        }
    }

    private func stopPointerTracking() {
        if let localPointerMonitor { NSEvent.removeMonitor(localPointerMonitor) }
        if let globalPointerMonitor { NSEvent.removeMonitor(globalPointerMonitor) }
        localPointerMonitor = nil
        globalPointerMonitor = nil
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

/// Repairs the WindowServer membership that macOS can discard while switching
/// Spaces. This runtime-only fallback mirrors Butai's isolated SkyLight
/// adapter; no private identifiers are persisted.
private struct DesktopLyricsSpaceMembershipRepairer {
    func addWindowToAllSpaces(windowNumber: Int) -> Bool {
        guard windowNumber > 0,
              let symbols = DesktopLyricsSkyLightSymbols.shared,
              let rawDisplays = symbols.copyManagedDisplaySpaces(symbols.defaultConnection())?
                .takeRetainedValue() as? [[String: Any]] else {
            return false
        }

        let spaceIDs = rawDisplays.flatMap { display -> [Int] in
            guard let spaces = display["Spaces"] as? [[String: Any]] else { return [] }
            return spaces.compactMap { $0["ManagedSpaceID"] as? Int }
        }
        guard !spaceIDs.isEmpty else { return false }

        let windows = [NSNumber(value: windowNumber)] as CFArray
        let spaces = Array(Set(spaceIDs)).map(NSNumber.init(value:)) as CFArray
        return symbols.addWindowsToSpaces(
            symbols.defaultConnection(),
            windows,
            spaces
        ) == .success
    }
}

private final class DesktopLyricsSkyLightSymbols: @unchecked Sendable {
    typealias DefaultConnection = @convention(c) () -> Int32
    typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    typealias AddWindowsToSpaces = @convention(c) (Int32, CFArray, CFArray) -> CGError

    static let shared: DesktopLyricsSkyLightSymbols? = DesktopLyricsSkyLightSymbols()

    let defaultConnection: DefaultConnection
    let copyManagedDisplaySpaces: CopyManagedDisplaySpaces
    let addWindowsToSpaces: AddWindowsToSpaces
    private let handle: UnsafeMutableRawPointer

    private init?() {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        guard let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL) else { return nil }
        guard let defaultConnectionSymbol = dlsym(handle, "_CGSDefaultConnection"),
              let managedSpacesSymbol = dlsym(handle, "CGSCopyManagedDisplaySpaces"),
              let addWindowsSymbol = dlsym(handle, "CGSAddWindowsToSpaces") else {
            dlclose(handle)
            return nil
        }

        self.handle = handle
        defaultConnection = unsafeBitCast(defaultConnectionSymbol, to: DefaultConnection.self)
        copyManagedDisplaySpaces = unsafeBitCast(
            managedSpacesSymbol,
            to: CopyManagedDisplaySpaces.self
        )
        addWindowsToSpaces = unsafeBitCast(addWindowsSymbol, to: AddWindowsToSpaces.self)
    }

    deinit {
        dlclose(handle)
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
