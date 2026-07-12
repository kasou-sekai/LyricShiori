import AppKit

/// SwiftUI creates windows asynchronously.  Activating the application again once
/// the window exists keeps menu-bar actions from leaving a new window behind the
/// currently focused app.
@MainActor
enum WindowActivator {
    static func bringToFront(titleContaining title: String) {
        NSApp.activate(ignoringOtherApps: true)

        for delay in [0.0, 0.08, 0.25] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let window = NSApp.windows.last(where: {
                    $0.title.localizedCaseInsensitiveContains(title)
                }) else {
                    return
                }
                window.deminiaturize(nil)
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}
