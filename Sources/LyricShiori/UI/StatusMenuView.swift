import SwiftUI

struct StatusMenuView: View {
    @Bindable var store: LyricShioriStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack {
            CurrentTrackSummary(store: store)

            Divider()

            Toggle("Menu Bar Lyrics", isOn: $store.settings.menuBarLyricsEnabled)
            Toggle("Desktop Lyrics", isOn: $store.settings.desktopLyricsEnabled)
                .onChange(of: store.settings.desktopLyricsEnabled) { _, _ in
                    store.syncDesktopLyricsWindow()
                }

            Button("Show Desktop Lyrics") {
                store.settings.desktopLyricsEnabled = true
                store.syncDesktopLyricsWindow()
            }

            Button("Search Lyrics") {
                openWindow(id: "search-lyrics")
                WindowActivator.bringToFront(titleContaining: "Search Lyrics")
            }

            Divider()

            Stepper("Offset: \(store.currentLyrics?.offsetMilliseconds ?? 0) ms", value: offsetBinding, in: -10_000...10_000, step: 100)

            Button("Increase Offset") {
                store.adjustOffset(by: 100)
            }

            Button("Decrease Offset") {
                store.adjustOffset(by: -100)
            }

            Button("Reset Offset") {
                store.resetOffset()
            }

            Divider()

            Button("Mark Wrong Lyrics") {
                store.markWrongLyrics()
            }
            .disabled(store.playback.track == nil)

            Button("Do Not Search This Album") {
                store.doNotSearchCurrentAlbum()
            }
            .disabled(store.playback.track?.album == nil)

            Divider()

            Button("Settings") {
                openSettings()
                WindowActivator.bringToFront(titleContaining: "Settings")
            }

            Button("Quit LyricShiori") {
                store.persistIfNeeded()
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.vertical, 4)
    }

    private var offsetBinding: Binding<Int> {
        Binding(
            get: { store.currentLyrics?.offsetMilliseconds ?? 0 },
            set: { store.setOffset($0) }
        )
    }
}

private struct CurrentTrackSummary: View {
    @Bindable var store: LyricShioriStore

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(store.playback.track?.title ?? "No Track")
                .font(.headline)
            Text(store.playback.track?.artist ?? store.playback.status.rawValue.capitalized)
                .foregroundStyle(.secondary)
            if store.shouldDisplayLyrics,
               let line = store.currentLineIndex.flatMap({ store.currentLyrics?.lines[$0] }) {
                Text(store.originalLineText(for: line))
                    .lineLimit(2)
            }
        }
        .frame(width: 260, alignment: .leading)
        .padding(.horizontal, 8)
    }
}
