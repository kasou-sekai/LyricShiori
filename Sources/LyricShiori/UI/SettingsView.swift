import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable var store: LyricShioriStore
    @State private var selection: SettingsTab = .general

    var body: some View {
        TabView(selection: $selection) {
            GeneralSettingsView(store: store)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            DisplaySettingsView(store: store)
                .tabItem { Label("Desktop Lyrics", systemImage: "textformat") }
                .tag(SettingsTab.display)
            SourceSettingsView(store: store)
                .tabItem { Label("Sources", systemImage: "magnifyingglass") }
                .tag(SettingsTab.sources)
            CurrentLyricsSettingsView(store: store)
                .tabItem { Label("Lyrics", systemImage: "music.note.list") }
                .tag(SettingsTab.lyrics)
            FilterSettingsView(store: store)
                .tabItem { Label("Filter", systemImage: "line.3.horizontal.decrease.circle") }
                .tag(SettingsTab.filter)
        }
        .padding(20)
        .alert("LyricShiori", isPresented: errorIsPresented) {
            Button("OK") { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
        }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } }
        )
    }
}

private enum SettingsTab: Hashable {
    case lyrics
    case general
    case display
    case sources
    case filter
}

/// The live lyrics view belongs with the controls that affect it. Keeping it in
/// Settings avoids a second, competing utility window for a menu-bar app.
private struct CurrentLyricsSettingsView: View {
    @Bindable var store: LyricShioriStore
    @State private var importing = false
    @State private var exporting = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label("Current Lyrics", systemImage: "music.note.list")
                    .font(.headline)
                Spacer()
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
                    store.showSearchLyricsWindow()
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .disabled(store.playback.track == nil)
            }
            .padding(.bottom, 12)

            Divider()

            LyricsDetailView(store: store)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.lrcs]) { result in
            if case .success(let url) = result {
                store.importLyrics(from: url)
            }
        }
        .fileExporter(
            isPresented: $exporting,
            document: LyricsFileDocument(text: store.currentLyrics?.lrcs ?? ""),
            contentType: .lrcs,
            defaultFilename: store.playback.track?.title ?? "Lyrics"
        ) { _ in }
    }
}

private struct GeneralSettingsView: View {
    @Bindable var store: LyricShioriStore
    @State private var updateAlert: UpdateAlert?

    var body: some View {
        Form {
            Section("Playback") {
                HStack {
                    Text("Spotify access")
                    Button {
                        Task { await store.requestSpotifyAccess() }
                    } label: {
                        Label("Authorize Spotify", systemImage: "lock.open")
                    }
                    Spacer()
                    ConnectionStatusIndicator(
                        text: store.spotifyAccessMessage,
                        color: spotifyAccessStatusColor
                    )
                }
                HStack {
                    Toggle("Connect to Fullscape plugin", isOn: Binding(
                        get: { store.settings.connectFullscape },
                        set: { store.setFullscapeConnectionEnabled($0) }
                    ))
                    Spacer()
                    ConnectionStatusIndicator(
                        text: pluginConnectionStatusText,
                        color: pluginConnectionStatusColor
                    )
                }
            }

            Section("Menu bar") {
                Toggle("Show lyrics in the menu bar", isOn: $store.settings.menuBarLyricsEnabled)
                Picker("Menu bar display", selection: $store.settings.menuBarDisplayMode) {
                    Text("Separated").tag(MenuBarDisplayMode.separated)
                    Text("Combined").tag(MenuBarDisplayMode.combined)
                    Text("Hidden").tag(MenuBarDisplayMode.hidden)
                }
                .pickerStyle(.segmented)
                .disabled(!store.settings.menuBarLyricsEnabled)
                Slider(value: $store.settings.menuBarLyricsMaxWidth, in: 80...600, step: 10) {
                    Text("Lyrics maximum width: \(Int(store.settings.menuBarLyricsMaxWidth)) pt")
                } minimumValueLabel: {
                    Text("80")
                } maximumValueLabel: {
                    Text("600")
                }
                .disabled(!store.settings.menuBarLyricsEnabled)
            }

            Section("Storage") {
                LabeledContent("Lyrics folder") {
                    Text(store.settings.lyricsSavingPath.url.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Button {
                    chooseLyricsFolder()
                } label: {
                    Label("Choose Folder…", systemImage: "folder")
                }
                Button("Use Default Folder") {
                    store.settings.customLyricsSavingPath = nil
                }
                .disabled(store.settings.customLyricsSavingPath == nil)
            }

            Section("Text") {
                Picker("Chinese conversion", selection: $store.settings.chineseConversionMode) {
                    ForEach(ChineseConversionMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
            }

            Section("Updates") {
                Toggle("Automatically check for updates", isOn: $store.settings.automaticallyCheckForUpdates)

                LabeledContent("Current version") {
                    Text(store.updateService.currentVersion)
                        .textSelection(.enabled)
                }

                HStack {
                    Button("Check for Updates…") {
                        Task {
                            await store.checkForUpdates()
                            presentUpdateResult()
                        }
                    }
                    .disabled(store.updateService.isBusy)
                }
            }
        }
        .formStyle(.grouped)
        .alert(item: $updateAlert, content: updateAlertContent)
    }

    private func chooseLyricsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                store.settings.customLyricsSavingPath = url
            }
        }
    }

    private var spotifyAccessStatusColor: Color {
        switch store.spotifyAccessPresentationState {
        case .granted:
            .green
        case .denied, .error:
            .red
        case .notRequested:
            .orange
        case .spotifyNotRunning:
            .gray
        case .checking:
            .blue
        }
    }

    private var pluginConnectionStatusColor: Color {
        guard store.settings.connectFullscape else { return .gray }
        return store.isFullscapePluginConnected ? .green : .orange
    }

    private var pluginConnectionStatusText: String {
        guard store.settings.connectFullscape else { return "Disabled" }
        return store.isFullscapePluginConnected ? "Plugin connected" : "Waiting for plugin"
    }

    private func presentUpdateResult() {
        switch store.updateService.status {
        case .failed:
            updateAlert = .failure(store.updateService.status.message)
        case .updateAvailable:
            guard let update = store.updateService.availableUpdate else { return }
            updateAlert = .available(update, releaseNotes: store.updateService.releaseNotes)
        case .upToDate:
            updateAlert = .upToDate
        default:
            break
        }
    }

    private func presentInstallationFailureIfNeeded() {
        if case .failed = store.updateService.status {
            updateAlert = .failure(store.updateService.status.message)
        }
    }

    private func updateAlertContent(_ alert: UpdateAlert) -> Alert {
        switch alert {
        case .upToDate:
            return Alert(
                title: Text("No Update Available"),
                message: Text("You’re already running the latest version."),
                dismissButton: .default(Text("OK"))
            )
        case .available(let update, let releaseNotes):
            let notes = releaseNotes.map { "\n\n\($0)" } ?? ""
            return Alert(
                title: Text("Update Available"),
                message: Text("LyricShiori \(update.version) is available. The app will quit while it installs.\(notes)"),
                primaryButton: .default(Text("Download and Install")) {
                    Task {
                        await store.installAvailableUpdate()
                        presentInstallationFailureIfNeeded()
                    }
                },
                secondaryButton: .cancel()
            )
        case .failure(let message):
            return Alert(
                title: Text("Update Check Failed"),
                message: Text(message),
                dismissButton: .default(Text("OK"))
            )
        }
    }
}

private enum UpdateAlert: Identifiable {
    case upToDate
    case available(AvailableUpdate, releaseNotes: String?)
    case failure(String)

    var id: String {
        switch self {
        case .upToDate:
            "up-to-date"
        case .available(let update, _):
            "available-\(update.version)"
        case .failure(let message):
            "failure-\(message)"
        }
    }
}

private struct ConnectionStatusIndicator: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 160, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}

private struct DisplaySettingsView: View {
    @Bindable var store: LyricShioriStore

    var body: some View {
        Form {
            Section("Visibility") {
                Toggle("Show desktop lyrics", isOn: $store.settings.desktopLyricsEnabled)
                    .onChange(of: store.settings.desktopLyricsEnabled) { _, _ in
                        store.syncDesktopLyricsWindow()
                    }
                Toggle("Hide lyrics while paused", isOn: $store.settings.disableLyricsWhenPaused)
                Toggle("Hide from screenshots", isOn: $store.settings.disableLyricsWhenScreenShot)
                Toggle(
                    "Hide desktop lyrics when Spotify is in the foreground",
                    isOn: $store.settings.hideDesktopLyricsWhenSpotifyIsFrontmost
                )
                .onChange(of: store.settings.hideDesktopLyricsWhenSpotifyIsFrontmost) { _, _ in
                    store.syncDesktopLyricsWindow()
                }
            }

            Section("Interaction") {
                Toggle("Allow dragging", isOn: draggingBinding)
                Toggle("Hide when the pointer passes over", isOn: hideWhenPointerPassingBinding)
                Toggle("Mouse click-through", isOn: mousePassthroughBinding)
            }

            Section("Layout") {
                Stepper("Previous lines: \(store.settings.desktopLyricsPreviousLineCount)", value: $store.settings.desktopLyricsPreviousLineCount, in: 0...3)
                Stepper("Next lines: \(store.settings.desktopLyricsNextLineCount)", value: $store.settings.desktopLyricsNextLineCount, in: 0...3)
                Slider(value: $store.settings.desktopLyricsWidth, in: 280...1_000, step: 10) {
                    Text(store.settings.desktopLyricsVerticalLayout
                        ? "Lyrics height: \(Int(store.settings.desktopLyricsWidth)) pt"
                        : "Lyrics width: \(Int(store.settings.desktopLyricsWidth)) pt")
                } minimumValueLabel: {
                    Text("280")
                } maximumValueLabel: {
                    Text("1000")
                }
            }

            Section("Typography") {
                Slider(value: $store.settings.desktopLyricsFontSize, in: 12...72, step: 1) {
                    Text("Font size")
                } minimumValueLabel: {
                    Text("12")
                } maximumValueLabel: {
                    Text("72")
                }
                Toggle("Vertical lyrics", isOn: $store.settings.desktopLyricsVerticalLayout)
                if store.settings.desktopLyricsVerticalLayout {
                    Picker("Column direction", selection: $store.settings.desktopLyricsVerticalDirection) {
                        ForEach(DesktopLyricsVerticalDirection.allCases) { direction in
                            Text(direction.rawValue).tag(direction)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Picker("Alignment", selection: $store.settings.desktopLyricsAlignment) {
                    ForEach(DesktopLyricsAlignment.allCases) { alignment in
                        Text(store.settings.desktopLyricsVerticalLayout
                            ? alignment.verticalDisplayName
                            : alignment.rawValue)
                            .tag(alignment)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Appearance") {
                Picker("Colour preset", selection: $store.settings.desktopLyricsColorPreset) {
                    ForEach(DesktopLyricsColorPreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                DesktopLyricsPresetPreview(preset: store.settings.desktopLyricsColorPreset, store: store)
                if store.settings.desktopLyricsColorPreset == .custom {
                    ColorPicker("Unplayed colour", selection: $store.settings.desktopLyricsColor)
                    ColorPicker("Played colour", selection: $store.settings.desktopLyricsProgressColor)
                    ColorPicker("Outline colour", selection: $store.settings.desktopLyricsShadowColor)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: store.settings.desktopLyricsColorPreset) { _, _ in
            store.persistDesktopLyricsColors()
        }
        .onChange(of: store.settings.desktopLyricsColor) { _, _ in
            store.persistDesktopLyricsColors()
        }
        .onChange(of: store.settings.desktopLyricsProgressColor) { _, _ in
            store.persistDesktopLyricsColors()
        }
        .onChange(of: store.settings.desktopLyricsShadowColor) { _, _ in
            store.persistDesktopLyricsColors()
        }
        .onChange(of: store.settings.desktopLyricsFontSize) { _, _ in
            store.syncDesktopLyricsWindow()
        }
        .onChange(of: store.settings.desktopLyricsVerticalLayout) { _, _ in
            store.syncDesktopLyricsWindow()
        }
        .onChange(of: store.settings.desktopLyricsVerticalDirection) { _, _ in
            store.syncDesktopLyricsWindow()
        }
        .onChange(of: store.settings.desktopLyricsWidth) { _, _ in
            store.syncDesktopLyricsWindow()
        }
        .onChange(of: store.settings.desktopLyricsPreviousLineCount) { _, _ in
            store.syncDesktopLyricsWindow()
        }
        .onChange(of: store.settings.desktopLyricsNextLineCount) { _, _ in
            store.syncDesktopLyricsWindow()
        }
    }

    private var mousePassthroughBinding: Binding<Bool> {
        Binding(
            get: { store.settings.desktopLyricsMousePassthrough },
            set: { isEnabled in
                store.settings.desktopLyricsMousePassthrough = isEnabled
                if isEnabled {
                    store.settings.desktopLyricsDraggable = false
                    store.settings.hideLyricsWhenMousePassingBy = false
                }
                store.syncDesktopLyricsWindow()
            }
        )
    }

    private var draggingBinding: Binding<Bool> {
        Binding(
            get: { store.settings.desktopLyricsDraggable },
            set: { isEnabled in
                store.settings.desktopLyricsDraggable = isEnabled
                if isEnabled {
                    store.settings.desktopLyricsMousePassthrough = false
                    store.settings.hideLyricsWhenMousePassingBy = false
                }
                store.syncDesktopLyricsWindow()
            }
        )
    }

    private var hideWhenPointerPassingBinding: Binding<Bool> {
        Binding(
            get: { store.settings.hideLyricsWhenMousePassingBy },
            set: { isEnabled in
                store.settings.hideLyricsWhenMousePassingBy = isEnabled
                if isEnabled {
                    store.settings.desktopLyricsMousePassthrough = false
                    store.settings.desktopLyricsDraggable = false
                }
                store.syncDesktopLyricsWindow()
            }
        )
    }
}

private struct DesktopLyricsPresetPreview: View {
    var preset: DesktopLyricsColorPreset
    var store: LyricShioriStore

    private var palette: DesktopLyricsPalette {
        preset == .custom
            ? .custom(using: store.settings)
            : preset.previewPalette
    }

    var body: some View {
        HStack(spacing: 10) {
            Text("Unplayed")
                .foregroundStyle(palette.pending)
            Text("Played")
                .foregroundStyle(palette.played)
            Text("Inactive")
                .foregroundStyle(palette.secondary)
        }
        .font(.system(.body, weight: .semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.82), in: Capsule())
        .overlay(Capsule().stroke(palette.shadow.opacity(0.9), lineWidth: 1))
        .accessibilityLabel("Lyrics colour preview")
    }
}

private struct SourceSettingsView: View {
    @Bindable var store: LyricShioriStore

    var body: some View {
        Form {
            Section("Lyrics sources") {
                if store.settings.connectFullscape {
                    Label("Fullscape plugin", systemImage: "puzzlepiece.extension.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Fullscape plugin source is enabled")
                }
                ForEach([LyricsProviderID.netease, .qqMusic]) { provider in
                    Toggle(provider.rawValue, isOn: Binding(
                        get: { store.settings.enabledProviders.contains(provider) },
                        set: { enabled in
                            if enabled {
                                store.settings.enabledProviders.insert(provider)
                            } else {
                                store.settings.enabledProviders.remove(provider)
                            }
                        }
                    ))
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct FilterSettingsView: View {
    @Bindable var store: LyricShioriStore
    @State private var newPattern = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Enable lyrics filter", isOn: $store.settings.lyricsFilterEnabled)
            Toggle("Enable smart filter", isOn: $store.settings.lyricsSmartFilterEnabled)

            HStack {
                TextField("Pattern or keyword", text: $newPattern)
                Button {
                    let pattern = newPattern.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !pattern.isEmpty else { return }
                    store.settings.lyricsFilterKeys.append(pattern)
                    newPattern = ""
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .disabled(newPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            List {
                ForEach(store.settings.lyricsFilterKeys, id: \.self) { pattern in
                    Text(pattern)
                }
                .onDelete { indexSet in
                    store.settings.lyricsFilterKeys.remove(atOffsets: indexSet)
                }
            }
            .overlay {
                if store.settings.lyricsFilterKeys.isEmpty {
                    ContentUnavailableView("No filter patterns", systemImage: "line.3.horizontal.decrease.circle")
                }
            }
        }
    }
}
