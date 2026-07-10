import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var store: LyricShioriStore

    var body: some View {
        TabView {
            GeneralSettingsView(store: store)
                .tabItem { Label("General", systemImage: "gearshape") }
            DisplaySettingsView(store: store)
                .tabItem { Label("Display", systemImage: "textformat") }
            SourceSettingsView(store: store)
                .tabItem { Label("Sources", systemImage: "network") }
            FilterSettingsView(store: store)
                .tabItem { Label("Filter", systemImage: "line.3.horizontal.decrease.circle") }
        }
        .padding()
    }
}

private struct GeneralSettingsView: View {
    @Bindable var store: LyricShioriStore

    var body: some View {
        Form {
            LabeledContent("Player", value: "Spotify")
            LabeledContent("Spotify Access", value: store.spotifyAccessMessage)
            Button {
                Task { await store.requestSpotifyAccess() }
            } label: {
                Label("Authorize Spotify", systemImage: "lock.open")
            }
            Toggle("Load lyrics beside track", isOn: $store.settings.loadLyricsBesideTrack)
            Toggle("Disable lyrics when paused", isOn: $store.settings.disableLyricsWhenPaused)

            Section("Lyrics Folder") {
                LabeledContent("Current Folder", value: store.settings.lyricsSavingPath.url.path)
                Toggle("Use Custom Folder", isOn: $store.settings.useCustomLyricsSavingPath)
                Button {
                    chooseLyricsFolder()
                } label: {
                    Label("Choose Folder", systemImage: "folder")
                }
            }

            Picker("Chinese Conversion", selection: $store.settings.chineseConversionMode) {
                ForEach(ChineseConversionMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
        }
        .formStyle(.grouped)
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
}

private struct DisplaySettingsView: View {
    @Bindable var store: LyricShioriStore

    var body: some View {
        Form {
            Section("Desktop Lyrics") {
                Toggle("Enabled", isOn: $store.settings.desktopLyricsEnabled)
                Slider(value: $store.settings.desktopLyricsFontSize, in: 12...72, step: 1) {
                    Text("Font Size")
                } minimumValueLabel: {
                    Text("12")
                } maximumValueLabel: {
                    Text("72")
                }
                ColorPicker("Text Color", selection: $store.settings.desktopLyricsColor)
                ColorPicker("Progress Color", selection: $store.settings.desktopLyricsProgressColor)
                ColorPicker("Shadow Color", selection: $store.settings.desktopLyricsShadowColor)
                Picker("Alignment", selection: $store.settings.desktopLyricsAlignment) {
                    ForEach(DesktopLyricsAlignment.allCases) { alignment in
                        Text(alignment.rawValue).tag(alignment)
                    }
                }
                .pickerStyle(.segmented)
                Stepper("Previous lines: \(store.settings.desktopLyricsPreviousLineCount)", value: $store.settings.desktopLyricsPreviousLineCount, in: 0...3)
                Stepper("Next lines: \(store.settings.desktopLyricsNextLineCount)", value: $store.settings.desktopLyricsNextLineCount, in: 0...3)
                Toggle("Draggable", isOn: $store.settings.desktopLyricsDraggable)
                Toggle("Hide lyrics when mouse passes by", isOn: $store.settings.hideLyricsWhenMousePassingBy)
                Toggle("Disable lyrics during screenshots", isOn: $store.settings.disableLyricsWhenScreenShot)
                Toggle("Enable furigana", isOn: $store.settings.desktopLyricsEnableFurigana)
                Slider(value: $store.settings.desktopLyricsXPositionFactor, in: 0...1) {
                    Text("Horizontal Position")
                }
                Slider(value: $store.settings.desktopLyricsYPositionFactor, in: 0...1) {
                    Text("Vertical Position")
                }
            }

            Section("Menu Bar") {
                Toggle("Show menu bar lyrics", isOn: $store.settings.menuBarLyricsEnabled)
                Toggle("Combined menu bar item", isOn: $store.settings.combinedMenuBarLyrics)
                Toggle("Hide menu bar items", isOn: $store.settings.hideMenuBarItems)
            }

            Section("Lyrics Window") {
                TextField("Font Name", text: $store.settings.lyricsWindowFontName)
                Slider(value: $store.settings.lyricsWindowFontSize, in: 10...32, step: 1) {
                    Text("Font Size")
                }
                ColorPicker("Text Color", selection: $store.settings.lyricsWindowTextColor)
                ColorPicker("Highlight Color", selection: $store.settings.lyricsWindowHighlightColor)
            }
        }
        .formStyle(.grouped)
    }
}

private struct SourceSettingsView: View {
    @Bindable var store: LyricShioriStore

    var body: some View {
        Form {
            Toggle("Use source priority order", isOn: $store.settings.lyricsSourcePriorityEnabled)
            Stepper("Priority window: \(Int(store.settings.lyricsPriorityWindow)) s", value: $store.settings.lyricsPriorityWindow, in: 0...30, step: 1)
            Toggle("Strict search matching", isOn: $store.settings.strictSearchEnabled)
            Toggle("Prefer bilingual lyrics", isOn: $store.settings.preferBilingualLyrics)
            Toggle("Connect Full-Screen Playing", isOn: Binding(
                get: { store.settings.connectFullScreenPlaying },
                set: { store.setFullScreenPlayingConnectionEnabled($0) }
            ))

            Section("Enabled Sources") {
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
        VStack(alignment: .leading) {
            Toggle("Enable lyrics filter", isOn: $store.settings.lyricsFilterEnabled)
            Toggle("Enable smart filter", isOn: $store.settings.lyricsSmartFilterEnabled)

            HStack {
                TextField("Pattern or keyword", text: $newPattern)
                Button {
                    guard !newPattern.isEmpty else { return }
                    store.settings.lyricsFilterKeys.append(newPattern)
                    newPattern = ""
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }

            List {
                ForEach(store.settings.lyricsFilterKeys, id: \.self) { pattern in
                    Text(pattern)
                }
                .onDelete { indexSet in
                    store.settings.lyricsFilterKeys.remove(atOffsets: indexSet)
                }
            }
        }
    }
}
