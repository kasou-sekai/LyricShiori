import AppKit
import Foundation
import Observation
import SwiftUI

@Observable
final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var isLoading = false

    var desktopLyricsEnabled: Bool = true { didSet { save(desktopLyricsEnabled, Keys.desktopLyricsEnabled) } }
    var desktopLyricsEnableFurigana: Bool = false { didSet { save(desktopLyricsEnableFurigana, Keys.desktopLyricsEnableFurigana) } }
    var desktopLyricsFontName: String = "Optima-Regular" { didSet { save(desktopLyricsFontName, Keys.desktopLyricsFontName) } }
    var desktopLyricsFontSize: Double = 24 { didSet { save(desktopLyricsFontSize, Keys.desktopLyricsFontSize) } }
    var desktopLyricsInsetBottom: Double = 20
    var desktopLyricsInsetBottomEnabled: Bool = true
    var desktopLyricsXPositionFactor: Double = 0.5 { didSet { save(desktopLyricsXPositionFactor, Keys.desktopLyricsXPositionFactor) } }
    var desktopLyricsYPositionFactor: Double = 0.9 { didSet { save(desktopLyricsYPositionFactor, Keys.desktopLyricsYPositionFactor) } }
    var desktopLyricsColor: Color = .white { didSet { saveColor(desktopLyricsColor, Keys.desktopLyricsColor) } }
    var desktopLyricsProgressColor: Color = Color(red: 0.20, green: 1.00, blue: 0.87) { didSet { saveColor(desktopLyricsProgressColor, Keys.desktopLyricsProgressColor) } }
    var desktopLyricsShadowColor: Color = Color(red: 0.00, green: 1.00, blue: 0.83) { didSet { saveColor(desktopLyricsShadowColor, Keys.desktopLyricsShadowColor) } }
    var desktopLyricsBackgroundColor: Color = .black.opacity(0.60) { didSet { saveColor(desktopLyricsBackgroundColor, Keys.desktopLyricsBackgroundColor) } }
    var desktopLyricsOneLineMode: Bool = false { didSet { save(desktopLyricsOneLineMode, Keys.desktopLyricsOneLineMode) } }
    var desktopLyricsDraggable: Bool = true { didSet { save(desktopLyricsDraggable, Keys.desktopLyricsDraggable) } }

    var menuBarLyricsEnabled: Bool = true { didSet { save(menuBarLyricsEnabled, Keys.menuBarLyricsEnabled) } }
    var combinedMenuBarLyrics: Bool = false { didSet { save(combinedMenuBarLyrics, Keys.combinedMenuBarLyrics) } }
    var hideMenuBarItems: Bool = false { didSet { save(hideMenuBarItems, Keys.hideMenuBarItems) } }
    var showLyricsWindow: Bool = false

    var disableLyricsWhenPaused: Bool = true { didSet { save(disableLyricsWhenPaused, Keys.disableLyricsWhenPaused) } }
    var disableLyricsWhenScreenShot: Bool = true { didSet { save(disableLyricsWhenScreenShot, Keys.disableLyricsWhenScreenShot) } }
    var hideLyricsWhenMousePassingBy: Bool = true { didSet { save(hideLyricsWhenMousePassingBy, Keys.hideLyricsWhenMousePassingBy) } }
    var globalLyricsOffset: Int = 0 { didSet { save(globalLyricsOffset, Keys.globalLyricsOffset) } }

    var lyricsFilterEnabled: Bool = true { didSet { save(lyricsFilterEnabled, Keys.lyricsFilterEnabled) } }
    var lyricsSmartFilterEnabled: Bool = true { didSet { save(lyricsSmartFilterEnabled, Keys.lyricsSmartFilterEnabled) } }
    var lyricsFilterKeys: [String] = Defaults.lyricsFilterKeys { didSet { save(lyricsFilterKeys, Keys.lyricsFilterKeys) } }

    var lyricsSourcePriorityEnabled: Bool = true { didSet { save(lyricsSourcePriorityEnabled, Keys.lyricsSourcePriorityEnabled) } }
    var lyricsSourcePriorityOrder: [LyricsProviderID] = [.netease, .qqMusic] { didSet { save(lyricsSourcePriorityOrder.map(\.rawValue), Keys.lyricsSourcePriorityOrder) } }
    var lyricsPriorityWindow: Double = 5 { didSet { save(lyricsPriorityWindow, Keys.lyricsPriorityWindow) } }
    var strictSearchEnabled: Bool = false { didSet { save(strictSearchEnabled, Keys.strictSearchEnabled) } }
    var preferBilingualLyrics: Bool = Locale.preferredLanguages.first?.hasPrefix("zh") == true { didSet { save(preferBilingualLyrics, Keys.preferBilingualLyrics) } }

    var loadLyricsBesideTrack: Bool = true { didSet { save(loadLyricsBesideTrack, Keys.loadLyricsBesideTrack) } }
    var useCustomLyricsSavingPath: Bool = false { didSet { save(useCustomLyricsSavingPath ? 1 : 0, Keys.lyricsSavingPathPopUpIndex) } }
    var customLyricsSavingPathBookmark: Data? { didSet { saveOptionalData(customLyricsSavingPathBookmark, Keys.lyricsCustomSavingPathBookmark) } }

    var preferredPlayer: PlayerKind = .spotify
    var enabledProviders: Set<LyricsProviderID> = [.netease, .qqMusic] { didSet { save(enabledProviders.map(\.rawValue).sorted(), Keys.enabledProviders) } }
    var noSearchingTrackIDs: Set<String> = [] { didSet { save(Array(noSearchingTrackIDs).sorted(), Keys.noSearchingTrackIDs) } }
    var noSearchingAlbumNames: Set<String> = [] { didSet { save(Array(noSearchingAlbumNames).sorted(), Keys.noSearchingAlbumNames) } }
    var nowPlayingBundleAllowList: [String] = [] { didSet { save(nowPlayingBundleAllowList, Keys.nowPlayingBundleAllowList) } }

    var lyricsWindowFontName: String = "Helvetica" { didSet { save(lyricsWindowFontName, Keys.lyricsWindowFontName) } }
    var lyricsWindowFontSize: Double = 13 { didSet { save(lyricsWindowFontSize, Keys.lyricsWindowFontSize) } }
    var lyricsWindowTextColor: Color = Color(white: 0.75) { didSet { saveColor(lyricsWindowTextColor, Keys.lyricsWindowTextColor) } }
    var lyricsWindowHighlightColor: Color = Color(red: 0.89, green: 1.00, blue: 0.80) { didSet { saveColor(lyricsWindowHighlightColor, Keys.lyricsWindowHighlightColor) } }

    var chineseConversionMode: ChineseConversionMode = .disabled { didSet { save(chineseConversionMode.rawValue, Keys.chineseConversionMode) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isLoading = true
        load()
        isLoading = false
    }

    var filter: LyricsFilter {
        LyricsFilter(enabled: lyricsFilterEnabled, smartFilterEnabled: lyricsSmartFilterEnabled, blockedPatterns: lyricsFilterKeys)
    }

    var lyricsSavingPath: (url: URL, securityScoped: Bool) {
        if useCustomLyricsSavingPath, let url = customLyricsSavingPath {
            return (url, true)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return (home.appendingPathComponent("Music/\(Defaults.defaultLyricsDirectoryName)", isDirectory: true), false)
    }

    var customLyricsSavingPath: URL? {
        get {
            guard let customLyricsSavingPathBookmark else { return nil }
            var isStale = false
            return try? URL(
                resolvingBookmarkData: customLyricsSavingPathBookmark,
                options: [.withSecurityScope],
                bookmarkDataIsStale: &isStale
            )
        }
        set {
            customLyricsSavingPathBookmark = try? newValue?.bookmarkData(options: [.withSecurityScope])
            useCustomLyricsSavingPath = newValue != nil
        }
    }

    private func load() {
        desktopLyricsEnabled = bool(Keys.desktopLyricsEnabled, default: desktopLyricsEnabled)
        desktopLyricsEnableFurigana = bool(Keys.desktopLyricsEnableFurigana, default: desktopLyricsEnableFurigana)
        desktopLyricsFontName = string(Keys.desktopLyricsFontName, default: desktopLyricsFontName)
        desktopLyricsFontSize = double(Keys.desktopLyricsFontSize, default: desktopLyricsFontSize)
        desktopLyricsXPositionFactor = double(Keys.desktopLyricsXPositionFactor, default: desktopLyricsXPositionFactor)
        desktopLyricsYPositionFactor = double(Keys.desktopLyricsYPositionFactor, default: desktopLyricsYPositionFactor)
        desktopLyricsColor = color(Keys.desktopLyricsColor, default: desktopLyricsColor)
        desktopLyricsProgressColor = color(Keys.desktopLyricsProgressColor, default: desktopLyricsProgressColor)
        desktopLyricsShadowColor = color(Keys.desktopLyricsShadowColor, default: desktopLyricsShadowColor)
        desktopLyricsBackgroundColor = color(Keys.desktopLyricsBackgroundColor, default: desktopLyricsBackgroundColor)
        desktopLyricsOneLineMode = bool(Keys.desktopLyricsOneLineMode, default: desktopLyricsOneLineMode)
        desktopLyricsDraggable = bool(Keys.desktopLyricsDraggable, default: desktopLyricsDraggable)

        menuBarLyricsEnabled = bool(Keys.menuBarLyricsEnabled, default: menuBarLyricsEnabled)
        combinedMenuBarLyrics = bool(Keys.combinedMenuBarLyrics, default: combinedMenuBarLyrics)
        hideMenuBarItems = bool(Keys.hideMenuBarItems, default: hideMenuBarItems)
        disableLyricsWhenPaused = bool(Keys.disableLyricsWhenPaused, default: disableLyricsWhenPaused)
        disableLyricsWhenScreenShot = bool(Keys.disableLyricsWhenScreenShot, default: disableLyricsWhenScreenShot)
        hideLyricsWhenMousePassingBy = bool(Keys.hideLyricsWhenMousePassingBy, default: hideLyricsWhenMousePassingBy)
        globalLyricsOffset = integer(Keys.globalLyricsOffset, default: globalLyricsOffset)

        lyricsFilterEnabled = bool(Keys.lyricsFilterEnabled, default: lyricsFilterEnabled)
        lyricsSmartFilterEnabled = bool(Keys.lyricsSmartFilterEnabled, default: lyricsSmartFilterEnabled)
        lyricsFilterKeys = stringArray(Keys.lyricsFilterKeys, default: lyricsFilterKeys)
        lyricsSourcePriorityEnabled = bool(Keys.lyricsSourcePriorityEnabled, default: lyricsSourcePriorityEnabled)
        lyricsSourcePriorityOrder = providerArray(Keys.lyricsSourcePriorityOrder, default: lyricsSourcePriorityOrder)
        lyricsPriorityWindow = double(Keys.lyricsPriorityWindow, default: lyricsPriorityWindow)
        strictSearchEnabled = bool(Keys.strictSearchEnabled, default: strictSearchEnabled)
        preferBilingualLyrics = bool(Keys.preferBilingualLyrics, default: preferBilingualLyrics)

        loadLyricsBesideTrack = bool(Keys.loadLyricsBesideTrack, default: loadLyricsBesideTrack)
        useCustomLyricsSavingPath = integer(Keys.lyricsSavingPathPopUpIndex, default: useCustomLyricsSavingPath ? 1 : 0) != 0
        customLyricsSavingPathBookmark = defaults.data(forKey: Keys.lyricsCustomSavingPathBookmark)

        enabledProviders = Set(providerArray(Keys.enabledProviders, default: Array(enabledProviders)))
        noSearchingTrackIDs = Set(stringArray(Keys.noSearchingTrackIDs, default: Array(noSearchingTrackIDs)))
        noSearchingAlbumNames = Set(stringArray(Keys.noSearchingAlbumNames, default: Array(noSearchingAlbumNames)))
        nowPlayingBundleAllowList = stringArray(Keys.nowPlayingBundleAllowList, default: nowPlayingBundleAllowList)

        lyricsWindowFontName = string(Keys.lyricsWindowFontName, default: lyricsWindowFontName)
        lyricsWindowFontSize = double(Keys.lyricsWindowFontSize, default: lyricsWindowFontSize)
        lyricsWindowTextColor = color(Keys.lyricsWindowTextColor, default: lyricsWindowTextColor)
        lyricsWindowHighlightColor = color(Keys.lyricsWindowHighlightColor, default: lyricsWindowHighlightColor)
        chineseConversionMode = ChineseConversionMode(rawValue: string(Keys.chineseConversionMode, default: chineseConversionMode.rawValue)) ?? .disabled
    }

    private func save(_ value: Bool, _ key: String) {
        guard !isLoading else { return }
        defaults.set(value, forKey: key)
    }

    private func save(_ value: Int, _ key: String) {
        guard !isLoading else { return }
        defaults.set(value, forKey: key)
    }

    private func save(_ value: Double, _ key: String) {
        guard !isLoading else { return }
        defaults.set(value, forKey: key)
    }

    private func save(_ value: String, _ key: String) {
        guard !isLoading else { return }
        defaults.set(value, forKey: key)
    }

    private func save(_ value: [String], _ key: String) {
        guard !isLoading else { return }
        defaults.set(value, forKey: key)
    }

    private func saveOptionalData(_ value: Data?, _ key: String) {
        guard !isLoading else { return }
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func saveColor(_ color: Color, _ key: String) {
        guard !isLoading else { return }
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: NSColor(color), requiringSecureCoding: false) {
            defaults.set(data, forKey: key)
        }
    }

    private func bool(_ key: String, default defaultValue: Bool) -> Bool {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }

    private func integer(_ key: String, default defaultValue: Int) -> Int {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.integer(forKey: key)
    }

    private func double(_ key: String, default defaultValue: Double) -> Double {
        guard let value = defaults.object(forKey: key) else { return defaultValue }
        return (value as? NSNumber)?.doubleValue ?? defaultValue
    }

    private func string(_ key: String, default defaultValue: String) -> String {
        defaults.string(forKey: key) ?? defaultValue
    }

    private func stringArray(_ key: String, default defaultValue: [String]) -> [String] {
        defaults.stringArray(forKey: key) ?? defaultValue
    }

    private func providerArray(_ key: String, default defaultValue: [LyricsProviderID]) -> [LyricsProviderID] {
        let rawValues = stringArray(key, default: defaultValue.map(\.rawValue))
        let providers = rawValues.compactMap(LyricsProviderID.init(rawValue:))
        return providers.isEmpty ? defaultValue : providers
    }

    private func color(_ key: String, default defaultValue: Color) -> Color {
        guard let data = defaults.data(forKey: key),
              let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) else {
            return defaultValue
        }
        return Color(color)
    }
}

enum ChineseConversionMode: String, CaseIterable, Identifiable {
    case disabled = "Disabled"
    case simplified = "Simplified"
    case traditional = "Traditional"

    var id: String { rawValue }
}

enum Defaults {
    static let defaultLyricsDirectoryName = "LyricShiori"
    static let legacyLyricsDirectoryName = "LyricsX"

    static let lyricsFilterKeys = [
        #"/(by|title|song|album|artist|singer|lyrics)\s*[:：∶]"#,
        #"/\w+(\.\w+){2}"#,
        #"/^\s*//\s*$"#,
        #"/\d{8}"#,
        #"/^\.$"#,
        "作詞", "作词", "作曲", "編曲", "编曲", "収録", "收录", "演唱", "歌手", "歌曲",
        "制作", "製作", "歌词", "歌詞", "翻譯", "翻译", "插曲", "插入歌", "主题歌", "主題歌",
        "片頭曲", "片头曲", "片尾曲", "SoundTrack", "アニメ",
    ]
}

private enum Keys {
    static let desktopLyricsEnabled = "DesktopLyricsEnabled"
    static let desktopLyricsEnableFurigana = "DesktopLyricsEnableFurigana"
    static let desktopLyricsFontName = "DesktopLyricsFontName"
    static let desktopLyricsFontSize = "DesktopLyricsFontSize"
    static let desktopLyricsXPositionFactor = "DesktopLyricsXPositionFactor"
    static let desktopLyricsYPositionFactor = "DesktopLyricsYPositionFactor"
    static let desktopLyricsColor = "DesktopLyricsColor"
    static let desktopLyricsProgressColor = "DesktopLyricsProgressColor"
    static let desktopLyricsShadowColor = "DesktopLyricsShadowColor"
    static let desktopLyricsBackgroundColor = "DesktopLyricsBackgroundColor"
    static let desktopLyricsOneLineMode = "DesktopLyricsOneLineMode"
    static let desktopLyricsDraggable = "DesktopLyricsDraggable"

    static let menuBarLyricsEnabled = "MenuBarLyricsEnabled"
    static let combinedMenuBarLyrics = "CombinedMenubarLyrics"
    static let hideMenuBarItems = "HideMenuBarItems"
    static let disableLyricsWhenPaused = "DisableLyricsWhenPaused"
    static let disableLyricsWhenScreenShot = "DisableLyricsWhenSreenShot"
    static let hideLyricsWhenMousePassingBy = "HideLyricsWhenMousePassingBy"
    static let globalLyricsOffset = "GlobalLyricsOffset"

    static let lyricsFilterEnabled = "LyricsFilterEnabled"
    static let lyricsSmartFilterEnabled = "LyricsSmartFilterEnabled"
    static let lyricsFilterKeys = "LyricsFilterKeys"
    static let lyricsSourcePriorityEnabled = "LyricsSourcePriorityEnabled"
    static let lyricsSourcePriorityOrder = "LyricsSourcePriorityOrder"
    static let lyricsPriorityWindow = "LyricsPriorityWindow"
    static let strictSearchEnabled = "StrictSearchEnabled"
    static let preferBilingualLyrics = "PreferBilingualLyrics"

    static let loadLyricsBesideTrack = "LoadLyricsBesideTrack"
    static let lyricsSavingPathPopUpIndex = "LyricsSavingPathPopUpIndex"
    static let lyricsCustomSavingPathBookmark = "LyricsCustomSavingPathBookmark"

    static let enabledProviders = "EnabledProviders"
    static let noSearchingTrackIDs = "NoSearchingTrackIds"
    static let noSearchingAlbumNames = "NoSearchingAlbumNames"
    static let nowPlayingBundleAllowList = "SystemWideNowPlayingAppList"

    static let lyricsWindowFontName = "LyricsWindowFontName"
    static let lyricsWindowFontSize = "LyricsWindowFontSize"
    static let lyricsWindowTextColor = "LyricsWindowTextColor"
    static let lyricsWindowHighlightColor = "LyricsWindowHighlightColor"
    static let chineseConversionMode = "ChineseConversionMode"
}
