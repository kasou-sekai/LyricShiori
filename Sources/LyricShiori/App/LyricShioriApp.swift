import AppKit
import SwiftUI

@main
struct LyricShioriApp: App {
    @NSApplicationDelegateAdaptor(LyricShioriAppDelegate.self) private var appDelegate
    @State private var store: LyricShioriStore
    @State private var menuBarController: MenuBarController

    init() {
        let store = LyricShioriStore()
        store.start()
        _store = State(initialValue: store)
        _menuBarController = State(initialValue: MenuBarController(store: store))
    }

    var body: some Scene {
        Settings {
            SettingsView(store: store)
                .frame(width: 860, height: 640)
        }
        .commands {
            LyricShioriCommands(store: store)
        }
    }
}

@MainActor
private final class LyricShioriAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A SwiftUI app whose only scene is Settings opens that scene as its
        // initial window, even though this app is an LSUIElement menu-bar app.
        // Close only the windows created during the launch cycle; windows the
        // user opens later from the status item are unaffected.
        suppressInitialWindows()
        DispatchQueue.main.async { [weak self] in
            self?.suppressInitialWindows()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.suppressInitialWindows()
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldRestoreApplicationState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationShouldSaveApplicationState(_ app: NSApplication) -> Bool {
        false
    }

    private func suppressInitialWindows() {
        NSApplication.shared.windows
            .filter { $0.isVisible && $0.level == .normal }
            .forEach { $0.close() }
    }
}

@MainActor
private struct LyricShioriCommands: Commands {
    let store: LyricShioriStore

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Search Lyrics") {
                store.showSearchLyricsWindow()
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])

            Button("Mark Wrong Lyrics") {
                store.markWrongLyrics()
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])

        }
        CommandMenu("Lyrics") {
            Button("Use Automatic Lyrics") {
                Task { await store.resetManualLyricsSelection() }
            }
            .disabled(!store.hasManualLyricsSelection)

            Divider()

            Button("Increase Offset") {
                store.adjustOffset(by: 100)
            }
            .keyboardShortcut(.upArrow, modifiers: [.command, .option])

            Button("Decrease Offset") {
                store.adjustOffset(by: -100)
            }
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])
        }
    }
}
