import SwiftUI

struct SearchLyricsView: View {
    @Bindable var store: LyricShioriStore
    var onDismiss: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SearchLyricsDraft
    @State private var selectedResultID: LyricsSearchResult.ID?
    @FocusState private var focusedField: Field?

    init(store: LyricShioriStore, onDismiss: (() -> Void)? = nil) {
        self.store = store
        self.onDismiss = onDismiss
        _draft = State(initialValue: SearchLyricsDraft(track: store.playback.track))
    }

    private enum Field {
        case title
        case artist
    }

    var body: some View {
        VStack(spacing: 0) {
            searchControls
            Divider()

            NavigationSplitView {
                List(store.searchResults, selection: $selectedResultID) { result in
                    SearchResultRow(result: result)
                        .tag(result.id)
                }
                .overlay {
                    if store.searchResults.isEmpty, !store.isSearching {
                        ContentUnavailableView(
                            "Search for lyrics",
                            systemImage: "text.magnifyingglass",
                            description: Text("All candidates are kept so you can choose the right version."))
                    }
                }
                .navigationTitle(resultCountTitle)
            } detail: {
                if let result = selectedResult {
                    LyricsSearchPreview(result: result) {
                        store.acceptLyrics(result.document, sourceName: result.provider.rawValue)
                        if let onDismiss {
                            onDismiss()
                        } else {
                            dismiss()
                        }
                    }
                } else if store.isSearching {
                    ContentUnavailableView("Searching…", systemImage: "magnifyingglass")
                } else {
                    ContentUnavailableView("Select a result", systemImage: "music.note.list")
                }
            }
            .navigationSplitViewStyle(.balanced)
        }
        .onAppear {
            draft.prefill(from: store.playback.track)
            focusedField = draft.title.isEmpty ? .title : .artist
        }
        .onChange(of: store.playback.track?.signature) { _, _ in
            // Playback may arrive just after the user opens the utility. Fill
            // fields that are still empty/auto-filled without overwriting edits.
            draft.prefill(from: store.playback.track)
        }
        .onChange(of: store.searchResults) { _, results in
            guard !results.contains(where: { $0.id == selectedResultID }) else { return }
            selectedResultID = results.first?.id
        }
        .alert("LyricShiori", isPresented: errorIsPresented) {
            Button("OK") { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
        }
    }

    private var searchControls: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Title")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Song title", text: $draft.title)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .title)
                    .onSubmit(beginSearch)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Artist")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Artist (optional)", text: $draft.artist)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .artist)
                    .onSubmit(beginSearch)
            }
            Button(action: beginSearch) {
                if store.isSearching {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Search", systemImage: "magnifyingglass")
                }
            }
            .disabled(isSearchEmpty || store.isSearching)
        }
        .padding(20)
    }

    private var selectedResult: LyricsSearchResult? {
        store.searchResults.first { $0.id == selectedResultID }
    }

    private var isSearchEmpty: Bool {
        draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draft.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var resultCountTitle: String {
        store.searchResults.isEmpty ? "Results" : "Results (\(store.searchResults.count))"
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } }
        )
    }

    private func beginSearch() {
        guard !isSearchEmpty, !store.isSearching else { return }
        selectedResultID = nil
        Task { await store.searchLyrics(title: draft.title, artist: draft.artist) }
    }
}

struct SearchLyricsDraft: Equatable {
    var title: String
    var artist: String
    private var lastAutomaticTitle: String?
    private var lastAutomaticArtist: String?

    init(track: TrackIdentity?) {
        title = track?.title ?? ""
        artist = track?.artist ?? ""
        lastAutomaticTitle = track?.title
        lastAutomaticArtist = track?.artist
    }

    mutating func prefill(from track: TrackIdentity?) {
        guard let track else { return }
        if title.isEmpty || title == lastAutomaticTitle {
            title = track.title
        }
        if artist.isEmpty || artist == lastAutomaticArtist {
            artist = track.artist
        }
        lastAutomaticTitle = track.title
        lastAutomaticArtist = track.artist
    }
}

private struct SearchResultRow: View {
    let result: LyricsSearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(result.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if result.isMatched {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .help("Strong match")
                }
            }
            Text(result.artist)
                .lineLimit(1)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(result.provider.rawValue)
                if let duration = result.duration, duration > 0 {
                    Text("• \(durationText(duration))")
                }
                if !result.isMatched {
                    Text("• Possible match")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 5)
    }
}

private struct LyricsSearchPreview: View {
    let result: LyricsSearchResult
    let useLyrics: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.title)
                        .font(.title3.weight(.semibold))
                    Text(result.artist)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Text(result.provider.rawValue)
                        if !result.isMatched {
                            Text("Possible match — check before using")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(result.isMatched ? Color.secondary : Color.orange)
                }
                Spacer()
                Button("Use Lyrics", action: useLyrics)
                    .buttonStyle(.borderedProminent)
            }
            .padding(20)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(result.document.lines) { line in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(line.content)
                            ForEach(line.translations.sorted(by: { $0.key < $1.key }), id: \.key) { _, translation in
                                Text(translation)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(20)
            }
        }
    }
}

private func durationText(_ duration: TimeInterval) -> String {
    let total = Int(duration.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}
