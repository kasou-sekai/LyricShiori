import SwiftUI

struct StatusMenuView: View {
    @Bindable var store: LyricShioriStore
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            CurrentTrackSummary(store: store)
                .padding(16)

            Divider()

            VStack(alignment: .leading, spacing: 18) {
                displaySection
                lyricsSection
            }
            .padding(16)

            Divider()

            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            PopoverSectionTitle("Display")

            Toggle("Menu Bar Lyrics", isOn: $store.settings.menuBarLyricsEnabled)
            Toggle("Desktop Lyrics", isOn: $store.settings.desktopLyricsEnabled)
                .onChange(of: store.settings.desktopLyricsEnabled) { _, _ in
                    store.syncDesktopLyricsWindow()
                }

            Button {
                store.showSearchLyricsWindow()
                dismiss()
            } label: {
                Label("Search Lyrics", systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private var lyricsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            PopoverSectionTitle("Lyrics")

            HStack(spacing: 10) {
                Text("Timing Offset")
                Spacer(minLength: 8)
                Text("\(store.currentLyrics?.offsetMilliseconds ?? 0) ms")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .disabled(store.currentLyrics == nil)

            HStack(spacing: 10) {
                Button {
                    store.adjustOffset(by: -100)
                } label: {
                    Label("Decrease Offset", systemImage: "minus")
                        .labelStyle(.iconOnly)
                        .frame(maxWidth: .infinity)
                }

                Button {
                    store.resetOffset()
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }

                Button {
                    store.adjustOffset(by: 100)
                } label: {
                    Label("Increase Offset", systemImage: "plus")
                        .labelStyle(.iconOnly)
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .disabled(store.currentLyrics == nil)

            HStack(spacing: 10) {
                Button {
                    Task { await store.resetManualLyricsSelection() }
                } label: {
                    Label("Use Automatic Lyrics", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!store.hasManualLyricsSelection)
                .help("Forget the manually selected lyrics for this track and choose lyrics automatically")

                Button {
                    store.markWrongLyrics()
                } label: {
                    Label("Wrong Lyrics", systemImage: "exclamationmark.triangle")
                        .frame(maxWidth: .infinity)
                }
                .disabled(store.playback.track == nil)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Button {
                openSettings()
                WindowActivator.bringToFront(titleContaining: "Settings")
                dismiss()
            } label: {
                Label("Settings", systemImage: "gearshape")
            }

            Spacer(minLength: 12)

            Button(role: .destructive) {
                store.persistIfNeeded()
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
        }
        .buttonStyle(.borderless)
    }

}

private struct PopoverSectionTitle: View {
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}

private struct CurrentTrackSummary: View {
    @Bindable var store: LyricShioriStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(store.playback.track?.title ?? "No Track")
                .font(.headline)
                .lineLimit(1)
            Text(store.playback.track?.artist ?? store.playback.status.rawValue.capitalized)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let lyrics = store.currentLyrics,
               let source = lyrics.sourceName,
               !source.isEmpty {
                Label(
                    "Lyrics: \(source) · \(lyrics.selectionState.acquisitionLabel)",
                    systemImage: "shippingbox"
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if store.shouldDisplayLyrics,
               let line = store.currentLineIndex.flatMap({ store.currentLyrics?.lines[$0] }) {
                Text(store.originalLineText(for: line))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
