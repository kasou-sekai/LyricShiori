import AppKit
import SwiftUI

/// Search is an on-demand utility window. Keeping it out of the SwiftUI scene
/// list prevents macOS window restoration from opening it with the menu-bar app.
@MainActor
final class SearchLyricsWindowController {
    private var window: NSWindow?

    func show(store: LyricShioriStore) {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Search Lyrics"
            window.minSize = NSSize(width: 640, height: 440)
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.managed]
            window.contentViewController = NSHostingController(
                rootView: SearchLyricsView(store: store) { [weak self] in
                    self?.window?.orderOut(nil)
                }
            )
            self.window = window
        }

        window?.center()
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
