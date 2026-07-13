import AppKit
import Foundation
import Observation
import SwiftUI

@Observable
final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var isLoading = false

    var desktopLyricsEnabled: Bool = true { didSet { save(desktopLyricsEnabled, Keys.desktopLyricsEnabled) } }
    var desktopLyricsFontSize: Double = 24 { didSet { save(desktopLyricsFontSize, Keys.desktopLyricsFontSize) } }
    var desktopLyricsVerticalLayout: Bool = false { didSet { save(desktopLyricsVerticalLayout, Keys.desktopLyricsVerticalLayout) } }
    var desktopLyricsVerticalDirection: DesktopLyricsVerticalDirection = .rightToLeft { didSet { save(desktopLyricsVerticalDirection.rawValue, Keys.desktopLyricsVerticalDirection) } }
    var desktopLyricsWidth: Double = 450 { didSet { save(desktopLyricsWidth, Keys.desktopLyricsWidth) } }
    var desktopLyricsPreviousLineCount: Int = 0 { didSet { save(desktopLyricsPreviousLineCount, Keys.desktopLyricsPreviousLineCount) } }
    var desktopLyricsNextLineCount: Int = 1 { didSet { save(desktopLyricsNextLineCount, Keys.desktopLyricsNextLineCount) } }
    var desktopLyricsAlignment: DesktopLyricsAlignment = .center { didSet { save(desktopLyricsAlignment.rawValue, Keys.desktopLyricsAlignment) } }
    var desktopLyricsXPositionFactor: Double = 0.5 { didSet { save(desktopLyricsXPositionFactor, Keys.desktopLyricsXPositionFactor) } }
    var desktopLyricsYPositionFactor: Double = 0.9 { didSet { save(desktopLyricsYPositionFactor, Keys.desktopLyricsYPositionFactor) } }
    var desktopLyricsColorPreset: DesktopLyricsColorPreset = .automatic { didSet { save(desktopLyricsColorPreset.rawValue, Keys.desktopLyricsColorPreset) } }
    var desktopLyricsColor: Color = .white { didSet { saveColor(desktopLyricsColor, Keys.desktopLyricsColor) } }
    var desktopLyricsProgressColor: Color = Color(red: 0.20, green: 1.00, blue: 0.87) { didSet { saveColor(desktopLyricsProgressColor, Keys.desktopLyricsProgressColor) } }
    var desktopLyricsShadowColor: Color = Color(red: 0.00, green: 1.00, blue: 0.83) { didSet { saveColor(desktopLyricsShadowColor, Keys.desktopLyricsShadowColor) } }
    var desktopLyricsDraggable: Bool = true { didSet { save(desktopLyricsDraggable, Keys.desktopLyricsDraggable) } }
    var desktopLyricsMousePassthrough: Bool = false { didSet { save(desktopLyricsMousePassthrough, Keys.desktopLyricsMousePassthrough) } }

    var menuBarLyricsEnabled: Bool = true { didSet { save(menuBarLyricsEnabled, Keys.menuBarLyricsEnabled) } }
    var menuBarDisplayMode: MenuBarDisplayMode = .combined { didSet { save(menuBarDisplayMode.rawValue, Keys.menuBarDisplayMode) } }
    var menuBarLyricsMaxWidth: Double = 260 { didSet { save(menuBarLyricsMaxWidth, Keys.menuBarLyricsMaxWidth) } }

    var disableLyricsWhenPaused: Bool = true { didSet { save(disableLyricsWhenPaused, Keys.disableLyricsWhenPaused) } }
    var disableLyricsWhenScreenShot: Bool = true { didSet { save(disableLyricsWhenScreenShot, Keys.disableLyricsWhenScreenShot) } }
    var hideLyricsWhenMousePassingBy: Bool = true { didSet { save(hideLyricsWhenMousePassingBy, Keys.hideLyricsWhenMousePassingBy) } }

    var lyricsFilterEnabled: Bool = true { didSet { save(lyricsFilterEnabled, Keys.lyricsFilterEnabled) } }
    var lyricsSmartFilterEnabled: Bool = true { didSet { save(lyricsSmartFilterEnabled, Keys.lyricsSmartFilterEnabled) } }
    var lyricsFilterKeys: [String] = Defaults.lyricsFilterKeys { didSet { save(lyricsFilterKeys, Keys.lyricsFilterKeys) } }

    var connectFullScreenPlaying: Bool = true { didSet { save(connectFullScreenPlaying, Keys.connectFullScreenPlaying) } }

    var useCustomLyricsSavingPath: Bool = false { didSet { save(useCustomLyricsSavingPath ? 1 : 0, Keys.lyricsSavingPathPopUpIndex) } }
    var customLyricsSavingPathBookmark: Data? { didSet { saveOptionalData(customLyricsSavingPathBookmark, Keys.lyricsCustomSavingPathBookmark) } }

    var enabledProviders: Set<LyricsProviderID> = [.netease, .qqMusic] { didSet { save(enabledProviders.map(\.rawValue).sorted(), Keys.enabledProviders) } }
    var noSearchingTrackIDs: Set<String> = [] { didSet { save(Array(noSearchingTrackIDs).sorted(), Keys.noSearchingTrackIDs) } }
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
        desktopLyricsFontSize = double(Keys.desktopLyricsFontSize, default: desktopLyricsFontSize)
        desktopLyricsVerticalLayout = bool(Keys.desktopLyricsVerticalLayout, default: desktopLyricsVerticalLayout)
        desktopLyricsVerticalDirection = DesktopLyricsVerticalDirection(
            rawValue: string(Keys.desktopLyricsVerticalDirection, default: desktopLyricsVerticalDirection.rawValue)
        ) ?? .rightToLeft
        desktopLyricsWidth = min(max(double(Keys.desktopLyricsWidth, default: desktopLyricsWidth), 280), 1_000)
        desktopLyricsPreviousLineCount = min(max(integer(Keys.desktopLyricsPreviousLineCount, default: desktopLyricsPreviousLineCount), 0), 3)
        desktopLyricsNextLineCount = min(max(integer(Keys.desktopLyricsNextLineCount, default: desktopLyricsNextLineCount), 0), 3)
        desktopLyricsAlignment = DesktopLyricsAlignment(rawValue: string(Keys.desktopLyricsAlignment, default: desktopLyricsAlignment.rawValue)) ?? .center
        desktopLyricsXPositionFactor = double(Keys.desktopLyricsXPositionFactor, default: desktopLyricsXPositionFactor)
        desktopLyricsYPositionFactor = double(Keys.desktopLyricsYPositionFactor, default: desktopLyricsYPositionFactor)
        if defaults.object(forKey: Keys.desktopLyricsColorPreset) != nil {
            desktopLyricsColorPreset = DesktopLyricsColorPreset(
                rawValue: string(Keys.desktopLyricsColorPreset, default: desktopLyricsColorPreset.rawValue)
            ) ?? .automatic
        } else if defaults.data(forKey: Keys.desktopLyricsColor) != nil ||
                    defaults.data(forKey: Keys.desktopLyricsProgressColor) != nil ||
                    defaults.data(forKey: Keys.desktopLyricsShadowColor) != nil {
            // Keep a person's existing hand-picked colours when they upgrade.
            desktopLyricsColorPreset = .custom
        }
        desktopLyricsColor = color(Keys.desktopLyricsColor, default: desktopLyricsColor)
        desktopLyricsProgressColor = color(Keys.desktopLyricsProgressColor, default: desktopLyricsProgressColor)
        desktopLyricsShadowColor = color(Keys.desktopLyricsShadowColor, default: desktopLyricsShadowColor)
        desktopLyricsDraggable = bool(Keys.desktopLyricsDraggable, default: desktopLyricsDraggable)
        desktopLyricsMousePassthrough = bool(Keys.desktopLyricsMousePassthrough, default: desktopLyricsMousePassthrough)

        menuBarLyricsEnabled = bool(Keys.menuBarLyricsEnabled, default: menuBarLyricsEnabled)
        menuBarDisplayMode = menuBarDisplayModeValue()
        menuBarLyricsMaxWidth = min(max(double(Keys.menuBarLyricsMaxWidth, default: menuBarLyricsMaxWidth), 80), 600)
        disableLyricsWhenPaused = bool(Keys.disableLyricsWhenPaused, default: disableLyricsWhenPaused)
        disableLyricsWhenScreenShot = bool(Keys.disableLyricsWhenScreenShot, default: disableLyricsWhenScreenShot)
        hideLyricsWhenMousePassingBy = bool(Keys.hideLyricsWhenMousePassingBy, default: hideLyricsWhenMousePassingBy)

        lyricsFilterEnabled = bool(Keys.lyricsFilterEnabled, default: lyricsFilterEnabled)
        lyricsSmartFilterEnabled = bool(Keys.lyricsSmartFilterEnabled, default: lyricsSmartFilterEnabled)
        lyricsFilterKeys = stringArray(Keys.lyricsFilterKeys, default: lyricsFilterKeys)
        connectFullScreenPlaying = bool(Keys.connectFullScreenPlaying, default: connectFullScreenPlaying)

        useCustomLyricsSavingPath = integer(Keys.lyricsSavingPathPopUpIndex, default: useCustomLyricsSavingPath ? 1 : 0) != 0
        customLyricsSavingPathBookmark = defaults.data(forKey: Keys.lyricsCustomSavingPathBookmark)

        enabledProviders = Set(providerArray(Keys.enabledProviders, default: Array(enabledProviders)))
        noSearchingTrackIDs = Set(stringArray(Keys.noSearchingTrackIDs, default: Array(noSearchingTrackIDs)))
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

    private func menuBarDisplayModeValue() -> MenuBarDisplayMode {
        if let rawValue = defaults.string(forKey: Keys.menuBarDisplayMode),
           let mode = MenuBarDisplayMode(rawValue: rawValue) {
            return mode
        }

        // Preserve the existing combined/separated preference for upgrades.
        return bool(Keys.menuBarLyricsCombined, default: true) ? .combined : .separated
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

enum MenuBarDisplayMode: String, CaseIterable, Identifiable {
    case separated
    case combined
    case hidden

    var id: Self { self }
}

enum DesktopLyricsAlignment: String, CaseIterable, Identifiable {
    case left = "Left"
    case center = "Center"
    case right = "Right"

    var id: String { rawValue }

    var horizontalAlignment: HorizontalAlignment {
        switch self {
        case .left:
            return .leading
        case .center:
            return .center
        case .right:
            return .trailing
        }
    }

    var frameAlignment: Alignment {
        switch self {
        case .left:
            return .leading
        case .center:
            return .center
        case .right:
            return .trailing
        }
    }

    var textAlignment: TextAlignment {
        switch self {
        case .left:
            return .leading
        case .center:
            return .center
        case .right:
            return .trailing
        }
    }

    var verticalFrameAlignment: Alignment {
        switch self {
        case .left: .top
        case .center: .center
        case .right: .bottom
        }
    }

    var verticalScaleAnchor: UnitPoint {
        switch self {
        case .left: .top
        case .center: .center
        case .right: .bottom
        }
    }

    var verticalDisplayName: String {
        switch self {
        case .left: "Top"
        case .center: "Centre"
        case .right: "Bottom"
        }
    }
}

enum DesktopLyricsVerticalDirection: String, CaseIterable, Identifiable {
    case leftToRight = "Left to Right"
    case rightToLeft = "Right to Left"

    var id: String { rawValue }
}

enum DesktopLyricsColorPreset: String, CaseIterable, Identifiable {
    /// Samples the album art and selects the closest readable preset.
    case automatic = "Automatic"
    case aurora = "Aurora"
    case orchid = "Orchid"
    case meadow = "Meadow"
    case sunset = "Sunset"
    case rose = "Rose"
    case custom = "Custom"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: "Match album cover"
        case .aurora: "Aurora"
        case .orchid: "Orchid"
        case .meadow: "Meadow"
        case .sunset: "Sunset"
        case .rose: "Rose"
        case .custom: "Custom"
        }
    }
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
    static let desktopLyricsFontSize = "DesktopLyricsFontSize"
    static let desktopLyricsVerticalLayout = "DesktopLyricsVerticalLayout"
    static let desktopLyricsVerticalDirection = "DesktopLyricsVerticalDirection"
    static let desktopLyricsWidth = "DesktopLyricsWidth"
    static let desktopLyricsPreviousLineCount = "DesktopLyricsPreviousLineCount"
    static let desktopLyricsNextLineCount = "DesktopLyricsNextLineCount"
    static let desktopLyricsAlignment = "DesktopLyricsAlignment"
    static let desktopLyricsXPositionFactor = "DesktopLyricsXPositionFactor"
    static let desktopLyricsYPositionFactor = "DesktopLyricsYPositionFactor"
    static let desktopLyricsColorPreset = "DesktopLyricsColorPreset"
    static let desktopLyricsColor = "DesktopLyricsColor"
    static let desktopLyricsProgressColor = "DesktopLyricsProgressColor"
    static let desktopLyricsShadowColor = "DesktopLyricsShadowColor"
    static let desktopLyricsDraggable = "DesktopLyricsDraggable"
    static let desktopLyricsMousePassthrough = "DesktopLyricsMousePassthrough"

    static let menuBarLyricsEnabled = "MenuBarLyricsEnabled"
    static let menuBarLyricsCombined = "CombinedMenubarLyrics"
    static let menuBarDisplayMode = "MenuBarDisplayMode"
    static let menuBarLyricsMaxWidth = "MenuBarLyricsMaxWidth"
    static let disableLyricsWhenPaused = "DisableLyricsWhenPaused"
    static let disableLyricsWhenScreenShot = "DisableLyricsWhenSreenShot"
    static let hideLyricsWhenMousePassingBy = "HideLyricsWhenMousePassingBy"

    static let lyricsFilterEnabled = "LyricsFilterEnabled"
    static let lyricsSmartFilterEnabled = "LyricsSmartFilterEnabled"
    static let lyricsFilterKeys = "LyricsFilterKeys"
    static let connectFullScreenPlaying = "ConnectFullScreenPlaying"

    static let lyricsSavingPathPopUpIndex = "LyricsSavingPathPopUpIndex"
    static let lyricsCustomSavingPathBookmark = "LyricsCustomSavingPathBookmark"

    static let enabledProviders = "EnabledProviders"
    static let noSearchingTrackIDs = "NoSearchingTrackIds"
    static let chineseConversionMode = "ChineseConversionMode"
}
