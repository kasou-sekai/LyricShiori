import SwiftUI

struct StatusMenuView: View {
    @Bindable var store: LyricShioriStore
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 5) {
            CurrentTrackSummary(store: store)

            Divider()

            Toggle("Menu Bar Lyrics", isOn: $store.settings.menuBarLyricsEnabled)
            Toggle("Desktop Lyrics", isOn: $store.settings.desktopLyricsEnabled)
                .onChange(of: store.settings.desktopLyricsEnabled) { _, _ in
                    store.syncDesktopLyricsWindow()
                }

            Button("Search Lyrics") {
                store.showSearchLyricsWindow()
                dismiss()
            }

            Divider()

            Stepper("Offset: \(store.currentLyrics?.offsetMilliseconds ?? 0) ms", value: offsetBinding, in: -10_000...10_000, step: 100)
                .disabled(store.currentLyrics == nil)

            Button("Reset Offset") {
                store.resetOffset()
            }
            .disabled(store.currentLyrics == nil)

            Divider()

            Button("Mark Wrong Lyrics") {
                store.markWrongLyrics()
            }
            .disabled(store.playback.track == nil)

            Divider()

            Button("Settings") {
                openSettings()
                WindowActivator.bringToFront(titleContaining: "Settings")
                dismiss()
            }

            Button("Quit LyricShiori") {
                store.persistIfNeeded()
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.vertical, 4)
        .fixedSize(horizontal: false, vertical: true)
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
            if let source = store.currentLyrics?.sourceName, !source.isEmpty {
                Label("Lyrics: \(source)", systemImage: "shippingbox")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
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
