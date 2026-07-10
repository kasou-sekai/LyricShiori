import Foundation

enum AppDataMigrator {
    private static let migrationKey = "Migration.LyricShioriCacheReset.v2"

    static func migrateIfNeeded(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        guard !defaults.bool(forKey: migrationKey) else { return }
        purgeLyricsCaches(fileManager: fileManager)
        migrateLegacyPreferences(defaults: defaults, fileManager: fileManager)
        defaults.set(true, forKey: migrationKey)
    }

    private static func purgeLyricsCaches(fileManager: FileManager) {
        let musicDirectory = fileManager.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Music", isDirectory: true)
        do {
            let directories = [
                musicDirectory.appendingPathComponent(Defaults.defaultLyricsDirectoryName, isDirectory: true),
                musicDirectory.appendingPathComponent(Defaults.legacyLyricsDirectoryName, isDirectory: true),
            ]
            for directory in directories where fileManager.fileExists(atPath: directory.path) {
                let files = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                for file in files where file.pathExtension.lowercased() == "lrcx" || file.lastPathComponent.hasPrefix("full-screen-lyrics-cache-") {
                    try fileManager.removeItem(at: file)
                }
            }
        } catch {
            NSLog("LyricShiori cache reset failed: \(error.localizedDescription)")
        }
    }

    private static func migrateLegacyPreferences(defaults: UserDefaults, fileManager: FileManager) {
        guard let legacy = legacyPreferences(fileManager: fileManager) else { return }
        for key in migratedPreferenceKeys where defaults.object(forKey: key) == nil {
            if let value = legacy[key] {
                defaults.set(value, forKey: key)
            }
        }
    }

    private static func legacyPreferences(fileManager: FileManager) -> [String: Any]? {
        for url in legacyPreferenceURLs(fileManager: fileManager) where fileManager.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url),
                  let preferences = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
                continue
            }
            return preferences
        }
        return nil
    }

    private static func legacyPreferenceURLs(fileManager: FileManager) -> [URL] {
        let home = fileManager.homeDirectoryForCurrentUser
        let identifiers = ["com.JH.LyricsX", "dev.JH.LyricsX"]
        var urls: [URL] = identifiers.map {
            home.appendingPathComponent("Library/Preferences/\($0).plist")
        }
        urls += identifiers.map {
            home.appendingPathComponent("Library/Containers/\($0)/Data/Library/Preferences/\($0).plist")
        }
        return urls
    }

    private static let migratedPreferenceKeys = [
        "DesktopLyricsEnabled",
        "DesktopLyricsEnableFurigana",
        "DesktopLyricsFontName",
        "DesktopLyricsFontSize",
        "DesktopLyricsXPositionFactor",
        "DesktopLyricsYPositionFactor",
        "DesktopLyricsColor",
        "DesktopLyricsProgressColor",
        "DesktopLyricsShadowColor",
        "DesktopLyricsBackgroundColor",
        "DesktopLyricsOneLineMode",
        "DesktopLyricsDraggable",
        "MenuBarLyricsEnabled",
        "CombinedMenubarLyrics",
        "HideMenuBarItems",
        "DisableLyricsWhenPaused",
        "DisableLyricsWhenSreenShot",
        "HideLyricsWhenMousePassingBy",
        "GlobalLyricsOffset",
        "LyricsFilterEnabled",
        "LyricsSmartFilterEnabled",
        "LyricsFilterKeys",
        "StrictSearchEnabled",
        "PreferBilingualLyrics",
        "LoadLyricsBesideTrack",
        "LyricsSavingPathPopUpIndex",
        "LyricsCustomSavingPathBookmark",
        "NoSearchingTrackIds",
        "NoSearchingAlbumNames",
        "SystemWideNowPlayingAppList",
        "LyricsWindowFontName",
        "LyricsWindowFontSize",
        "LyricsWindowTextColor",
        "LyricsWindowHighlightColor",
    ]
}
