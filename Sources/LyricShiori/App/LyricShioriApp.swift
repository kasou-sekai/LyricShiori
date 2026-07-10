import SwiftUI

@main
struct LyricShioriApp: App {
    @State private var store: LyricShioriStore

    init() {
        AppDataMigrator.migrateIfNeeded()
        let store = LyricShioriStore()
        store.start()
        _store = State(initialValue: store)
    }

    var body: some Scene {
        MenuBarExtra {
            StatusMenuView(store: store)
        } label: {
            if store.settings.menuBarLyricsEnabled,
               store.shouldDisplayLyrics,
               let line = store.currentLineIndex.flatMap({ store.currentLyrics?.lines[$0] }) {
                Text(store.originalLineText(for: line))
            } else {
                Label("LyricShiori", systemImage: "music.note")
            }
        }
        .menuBarExtraStyle(.menu)

        WindowGroup("Search Lyrics", id: "search-lyrics") {
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
                openWindow(id: "search-lyrics")
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

            Button("Persist Lyrics") {
                store.persistIfNeeded()
            }
        }
    }
}
