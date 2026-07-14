import AppKit
import SwiftUI

@main
struct LyricShioriApp: App {
    @State private var store: LyricShioriStore
    @State private var menuBarController: MenuBarController

    init() {
        let store = LyricShioriStore()
        store.start()
        _store = State(initialValue: store)
        _menuBarController = State(initialValue: MenuBarController(store: store))
    }

    var body: some Scene {
        // A value-based window group is created only through `openWindow`.
        // This keeps the menu-bar app from opening the search window at launch.
        WindowGroup("Search Lyrics", id: "search-lyrics", for: String.self) { _ in
            SearchLyricsView(store: store)
                .frame(minWidth: 640, minHeight: 440)
        }
        .defaultSize(width: 760, height: 520)

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
private struct LyricShioriCommands: Commands {
    let store: LyricShioriStore
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Search Lyrics") {
                openWindow(id: "search-lyrics", value: "manual-search")
                WindowActivator.bringToFront(titleContaining: "Search Lyrics")
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])

            Button("Mark Wrong Lyrics") {
                store.markWrongLyrics()
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
        }
        CommandMenu("Lyrics") {
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
