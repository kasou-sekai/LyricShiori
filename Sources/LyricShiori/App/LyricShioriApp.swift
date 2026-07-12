import AppKit
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
            if let lyrics = currentMenuBarLyrics,
               store.settings.menuBarLyricsCombined {
                HStack(spacing: 4) {
                    EmojiBookmarkIcon()
                        .frame(width: 18, height: 18)
                    MenuBarLyricsLabel(text: lyrics, maxWidth: store.settings.menuBarLyricsMaxWidth)
                }
            } else {
                EmojiBookmarkIcon()
                    .frame(width: 18, height: 18)
            }
        }
        .menuBarExtraStyle(.window)

        MenuBarExtra {
            StatusMenuView(store: store)
        } label: {
            if let lyrics = currentMenuBarLyrics,
               !store.settings.menuBarLyricsCombined {
                MenuBarLyricsLabel(text: lyrics, maxWidth: store.settings.menuBarLyricsMaxWidth)
                    .accessibilityLabel("LyricShiori lyrics")
            } else {
                Color.clear
                    .frame(width: 0, height: 0)
            }
        }
        .menuBarExtraStyle(.window)

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

    private var currentMenuBarLyrics: String? {
        guard store.settings.menuBarLyricsEnabled,
              store.shouldDisplayLyrics,
              let line = store.currentLineIndex.flatMap({ store.currentLyrics?.lines[$0] }) else {
            return nil
        }
        return store.originalLineText(for: line)
    }
}

private struct MenuBarLyricsLabel: View {
    var text: String
    var maxWidth: Double

    var body: some View {
        Text(text)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: maxWidth, alignment: .leading)
    }
}

private struct EmojiBookmarkIcon: View {
    private static let image: NSImage? = {
        guard let url = Bundle.module.url(forResource: "emoji-bookmark-template", withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            return nil
        }
        // Keep the bitmap's high pixel density while giving AppKit the small
        // point size expected of a menu-bar status image.
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }()

    var body: some View {
        Group {
            if let image = Self.image {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.template)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "bookmark.fill")
            }
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
        }
    }
}
