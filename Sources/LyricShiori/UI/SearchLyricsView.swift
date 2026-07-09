import SwiftUI

struct SearchLyricsView: View {
    @Bindable var store: LyricShioriStore
    @State private var title = ""
    @State private var artist = ""
    @State private var didPrefill = false
    @State private var selectedResultID: LyricsSearchResult.ID?
    @FocusState private var focusedField: Field?

    private enum Field {
        case title
        case artist
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Title", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .title)
                TextField("Artist", text: $artist)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .artist)
                Button {
                    Task { await search() }
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isSearching)
            }
            .padding()

            Divider()

            HSplitView {
                List(store.searchResults, selection: $selectedResultID) { result in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(result.title)
                            .font(.headline)
                        Text("\(result.artist) - \(result.provider.rawValue)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                .frame(minWidth: 240)

                if let result = selectedResult {
                    VStack(alignment: .leading) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(result.title)
                                    .font(.title3.weight(.semibold))
                                Text(result.provider.rawValue)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Use Lyrics") {
                                store.acceptLyrics(result.document, sourceName: result.provider.rawValue)
                            }
                        }
                        .padding()

                        Divider()

                        List(result.document.lines) { line in
                            Text(line.content)
                                .padding(.vertical, 3)
                        }
                    }
                } else {
                    ContentUnavailableView("No Result Selected", systemImage: "text.magnifyingglass")
                }
            }
        }
        .onAppear {
            prefillFromCurrentTrackIfNeeded()
            if title.isEmpty {
                focusedField = .title
            } else if artist.isEmpty {
                focusedField = .artist
            }
        }
        .onChange(of: store.playback.track) { _, _ in
            prefillFromCurrentTrackIfNeeded()
        }
    }

    private var selectedResult: LyricsSearchResult? {
        store.searchResults.first { $0.id == selectedResultID }
    }

    private func search() async {
        await store.searchLyrics(title: title, artist: artist)
    }

    private func prefillFromCurrentTrackIfNeeded() {
        guard !didPrefill, let track = store.playback.track else { return }
        if title.isEmpty {
            title = track.title
        }
        if artist.isEmpty {
            artist = track.artist
        }
        didPrefill = true
    }
}
