import Foundation

enum AppDataMigrator {
    private static let migrationKey = "Migration.LyricsXToLyricShiori.v1"

    static func migrateIfNeeded(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        guard !defaults.bool(forKey: migrationKey) else { return }
        migrateLyricsDirectory(fileManager: fileManager)
        migrateLegacyPreferences(defaults: defaults, fileManager: fileManager)
        defaults.set(true, forKey: migrationKey)
    }

    private static func migrateLyricsDirectory(fileManager: FileManager) {
        let musicDirectory = fileManager.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Music", isDirectory: true)
        let source = musicDirectory.appendingPathComponent(Defaults.legacyLyricsDirectoryName, isDirectory: true)
        let destination = musicDirectory.appendingPathComponent(Defaults.defaultLyricsDirectoryName, isDirectory: true)
        guard fileManager.fileExists(atPath: source.path) else { return }

        do {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            let files = try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
            for sourceURL in files {
                let destinationURL = destination.appendingPathComponent(sourceURL.lastPathComponent)
                guard !fileManager.fileExists(atPath: destinationURL.path) else { continue }
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
            }
        } catch {
            NSLog("LyricShiori migration failed while copying lyrics: \(error.localizedDescription)")
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
