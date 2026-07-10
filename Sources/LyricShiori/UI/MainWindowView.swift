import SwiftUI
import UniformTypeIdentifiers

struct MainWindowView: View {
    @Bindable var store: LyricShioriStore
    @State private var importing = false
    @State private var exporting = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store)
        } detail: {
            LyricsDetailView(store: store)
                .toolbar {
                    ToolbarItemGroup {
                        Button {
                            importing = true
                        } label: {
                            Label("Import", systemImage: "square.and.arrow.down")
                        }

                        Button {
                            exporting = true
                        } label: {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                        .disabled(store.currentLyrics == nil)

                        Button {
                            Task { await store.searchLyricsForCurrentTrack() }
                        } label: {
                            Label("Search", systemImage: "magnifyingglass")
                        }
                        .disabled(store.playback.track == nil || store.isSearching)
                    }
                }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.init(filenameExtension: "lrcx")!]) { result in
            if case .success(let url) = result {
                store.importLyrics(from: url)
            }
        }
        .fileExporter(isPresented: $exporting, document: LyricsFileDocument(text: store.currentLyrics?.lrcx ?? ""), contentType: .plainText, defaultFilename: defaultExportName) { _ in }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            importDroppedFile(from: providers)
        }
        .onChange(of: store.showSearchWindow) { _, shouldOpen in
            if shouldOpen {
                openWindow(id: "search-lyrics")
                store.showSearchWindow = false
            }
        }
        .alert("LyricShiori", isPresented: Binding(get: { store.lastError != nil }, set: { if !$0 { store.lastError = nil } })) {
            Button("OK") { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
        }
    }

    private var defaultExportName: String {
        let title = store.playback.track?.title ?? "Lyrics"
        return "\(title).lrcx"
    }

    private func importDroppedFile(from providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else {
                url = item as? URL
            }
            if let url {
                Task { @MainActor in
                    store.importLyrics(from: url)
                }
            }
        }
        return true
    }
}

private struct SidebarView: View {
    @Bindable var store: LyricShioriStore

    var body: some View {
        List {
            Section("Now Playing") {
                LabeledContent("Player", value: "Spotify")
                LabeledContent("Status", value: store.playback.status.rawValue.capitalized)
                LabeledContent("Title", value: store.playback.track?.title ?? "-")
                LabeledContent("Artist", value: store.playback.track?.artist ?? "-")
                LabeledContent("Source", value: store.currentLyrics?.sourceName ?? "-")
            }

            Section("Features") {
                ForEach(FeatureCatalog.all) { item in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(item.title)
                            Text(item.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        Text(item.status.rawValue)
                            .font(.caption)
                            .foregroundStyle(item.status == .available ? .green : .orange)
                    }
                }
            }
        }
        .navigationTitle("LyricShiori")
    }
}

private struct LyricsDetailView: View {
    @Bindable var store: LyricShioriStore

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(store: store)
            Divider()
            if let lyrics = store.currentLyrics {
                ScrollLyricsList(store: store, lyrics: lyrics)
            } else {
                ContentUnavailableView("No Lyrics", systemImage: "text.quote", description: Text("Import a LRC/LRCX file or search from a lyrics source."))
            }
        }
    }
}

private struct HeaderBar: View {
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

private struct PlaybackControls: View {
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
    }
}

private struct ScrollLyricsList: View {
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
    static var readableContentTypes: [UTType] { [.plainText] }
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
