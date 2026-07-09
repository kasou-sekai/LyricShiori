import AppKit
import SwiftUI

@MainActor
final class PanelController<Content: View> {
    private var panel: NSPanel?
    private let title: String
    private let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    func show(size: CGSize = CGSize(width: 720, height: 420), floating: Bool = false) {
        if panel == nil {
            let hosting = NSHostingController(rootView: content)
            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.title = title
            panel.contentViewController = hosting
            panel.isReleasedWhenClosed = false
            panel.level = floating ? .floating : .normal
            panel.collectionBehavior = floating ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.managed]
            self.panel = panel
        }
        panel?.center()
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        panel?.close()
    }
}

