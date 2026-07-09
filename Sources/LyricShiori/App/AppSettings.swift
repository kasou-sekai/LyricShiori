import AppKit
import Foundation
import SwiftUI

@Observable
final class AppSettings {
    var desktopLyricsEnabled: Bool = true
    var desktopLyricsEnableFurigana: Bool = false
    var desktopLyricsFontName: String = "Optima-Regular"
    var desktopLyricsFontSize: Double = 24
    var desktopLyricsInsetBottom: Double = 20
    var desktopLyricsInsetBottomEnabled: Bool = true
    var desktopLyricsXPositionFactor: Double = 0.5
    var desktopLyricsYPositionFactor: Double = 0.9
    var desktopLyricsColor: Color = .white
    var desktopLyricsProgressColor: Color = Color(red: 0.20, green: 1.00, blue: 0.87)
    var desktopLyricsShadowColor: Color = Color(red: 0.00, green: 1.00, blue: 0.83)
    var desktopLyricsBackgroundColor: Color = .black.opacity(0.60)
    var desktopLyricsOneLineMode: Bool = false
    var desktopLyricsDraggable: Bool = true

    var menuBarLyricsEnabled: Bool = true
    var combinedMenuBarLyrics: Bool = false
    var hideMenuBarItems: Bool = false
    var showLyricsWindow: Bool = false

    var disableLyricsWhenPaused: Bool = true
    var disableLyricsWhenScreenShot: Bool = true
    var hideLyricsWhenMousePassingBy: Bool = true
    var globalLyricsOffset: Int = 0

    var lyricsFilterEnabled: Bool = true
    var lyricsSmartFilterEnabled: Bool = true
    var lyricsFilterKeys: [String] = Defaults.lyricsFilterKeys

    var lyricsSourcePriorityEnabled: Bool = true
    var lyricsSourcePriorityOrder: [LyricsProviderID] = [.netease, .qqMusic]
    var lyricsPriorityWindow: Double = 5
    var strictSearchEnabled: Bool = false
    var preferBilingualLyrics: Bool = Locale.preferredLanguages.first?.hasPrefix("zh") == true

    var loadLyricsBesideTrack: Bool = true
    var useCustomLyricsSavingPath: Bool = false
    var customLyricsSavingPathBookmark: Data?

    var preferredPlayer: PlayerKind = .spotify
    var enabledProviders: Set<LyricsProviderID> = [.netease, .qqMusic]
    var noSearchingTrackIDs: Set<String> = []
    var noSearchingAlbumNames: Set<String> = []
    var nowPlayingBundleAllowList: [String] = []

    var lyricsWindowFontName: String = "Helvetica"
    var lyricsWindowFontSize: Double = 13
    var lyricsWindowTextColor: Color = Color(white: 0.75)
    var lyricsWindowHighlightColor: Color = Color(red: 0.89, green: 1.00, blue: 0.80)

    var chineseConversionMode: ChineseConversionMode = .disabled

    var filter: LyricsFilter {
        LyricsFilter(enabled: lyricsFilterEnabled, smartFilterEnabled: lyricsSmartFilterEnabled, blockedPatterns: lyricsFilterKeys)
    }

    var lyricsSavingPath: (url: URL, securityScoped: Bool) {
        if useCustomLyricsSavingPath, let url = customLyricsSavingPath {
            return (url, true)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return (home.appendingPathComponent("Music/LyricsX", isDirectory: true), false)
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
}

enum ChineseConversionMode: String, CaseIterable, Identifiable {
    case disabled = "Disabled"
    case simplified = "Simplified"
    case traditional = "Traditional"

    var id: String { rawValue }
}

enum Defaults {
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
