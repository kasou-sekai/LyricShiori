import SwiftUI
import UniformTypeIdentifiers

struct LyricsDetailView: View {
    @Bindable var store: LyricShioriStore

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(store: store)
            Divider()
            OffsetControls(store: store)
            Divider()
            if let lyrics = store.currentLyrics {
                ScrollLyricsList(store: store, lyrics: lyrics)
            } else {
                ContentUnavailableView("No Lyrics", systemImage: "text.quote", description: Text("Import an LRCS file or search for lyrics."))
            }
        }
    }
}

struct HeaderBar: View {
    @Bindable var store: LyricShioriStore

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading) {
                Text(store.playback.track?.title ?? "No Track")
                    .font(.title3.weight(.semibold))
                Text(store.playback.track?.artist ?? "Waiting for a player adapter")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            PlaybackControls(store: store)
            VStack(alignment: .trailing) {
                Text(timeText(store.playback.effectiveElapsedTime))
                    .monospacedDigit()
                Text("Offset \(store.currentLyrics?.offsetMilliseconds ?? 0) ms")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    private func timeText(_ time: TimeInterval) -> String {
        let minutes = Int(time / 60)
        let seconds = Int(time.truncatingRemainder(dividingBy: 60))
        return String(format: "%02d:%02d", minutes, seconds)
    }

}

struct OffsetControls: View {
    @Bindable var store: LyricShioriStore

    var body: some View {
        HStack(spacing: 8) {
            Text("Offset")
                .font(.subheadline.weight(.medium))
            TextField("Milliseconds", value: offsetBinding, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 110)
                .disabled(store.currentLyrics == nil)
            Text("ms")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button {
                store.adjustOffset(by: -100)
            } label: {
                Image(systemName: "minus")
            }
            .help("Decrease offset by 100 ms")
            .disabled(store.currentLyrics == nil)

            Button {
                store.resetOffset()
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .help("Reset offset to 0 ms")
            .disabled(store.currentLyrics == nil)

            Button {
                store.adjustOffset(by: 100)
            } label: {
                Image(systemName: "plus")
            }
            .help("Increase offset by 100 ms")
            .disabled(store.currentLyrics == nil)

            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var offsetBinding: Binding<Int> {
        Binding(
            get: { store.currentLyrics?.offsetMilliseconds ?? 0 },
            set: { store.setOffset($0) }
        )
    }
}

struct PlaybackControls: View {
    @Bindable var store: LyricShioriStore

    var body: some View {
        HStack {
            Button {
                Task { await store.previousTrack() }
            } label: {
                Label("Previous", systemImage: "backward.fill")
            }
            Button {
                Task { await store.playPause() }
            } label: {
                Label("Play/Pause", systemImage: store.playback.status == .playing ? "pause.fill" : "play.fill")
            }
            Button {
                Task { await store.nextTrack() }
            } label: {
                Label("Next", systemImage: "forward.fill")
            }
        }
        .labelStyle(.iconOnly)
        .disabled(store.playback.track == nil)
    }
}

struct ScrollLyricsList: View {
    @Bindable var store: LyricShioriStore
    var lyrics: LyricsDocument

    var body: some View {
        ScrollViewReader { proxy in
            List(Array(lyrics.lines.enumerated()), id: \.element.id) { index, line in
                Button {
                    Task { await store.seek(to: line) }
                } label: {
                    HStack(alignment: .firstTextBaseline) {
                        Text(LyricsDocument.formatTimestamp(line.position))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 64, alignment: .leading)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(store.displayedLineText(for: line))
                                .font(index == store.currentLineIndex ? .title3.weight(.semibold) : .body)
                            ForEach(line.translations.sorted(by: { $0.key < $1.key }), id: \.key) { _, value in
                                Text(value)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
                .id(line.id)
                .listRowBackground(index == store.currentLineIndex ? Color.accentColor.opacity(0.12) : Color.clear)
            }
            .onChange(of: store.currentLineIndex) { _, newValue in
                if let newValue, lyrics.lines.indices.contains(newValue) {
                    withAnimation(.snappy) {
                        proxy.scrollTo(lyrics.lines[newValue].id, anchor: .center)
                    }
                }
            }
        }
    }
}

struct LyricsFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.lrcs] }
    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents {
            text = String(decoding: data, as: UTF8.self)
        } else {
            text = ""
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

extension UTType {
    static let lrcs = UTType(exportedAs: "com.lyricshiori.lrcs", conformingTo: .plainText)
}
