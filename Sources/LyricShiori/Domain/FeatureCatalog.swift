import Foundation

struct FeatureCatalog {
    struct Item: Identifiable, Equatable {
        var id: String
        var title: String
        var detail: String
        var status: Status
    }

    enum Status: String {
        case available = "Available"
        case adapterRequired = "Adapter Required"
        case planned = "Planned"
    }

    static let all: [Item] = [
        .init(id: "spotify", title: "Spotify playback", detail: "Reads the current Spotify track and playback position through macOS Automation", status: .available),
        .init(id: "sources", title: "Lyrics sources", detail: "NetEase Cloud Music and QQ Music", status: .available),
        .init(id: "desktop", title: "Desktop lyrics", detail: "Floating, click-through-capable lyrics window with font, color, position and visibility settings", status: .available),
        .init(id: "menubar", title: "Menu bar lyrics", detail: "Status item, combined/separate modes, offset actions and quick commands", status: .available),
        .init(id: "offset", title: "Lyrics offset", detail: "Global and per-document offset adjustment", status: .available),
        .init(id: "seek", title: "Seek by lyric line", detail: "Double click or button action maps a lyric line to Spotify seek", status: .available),
        .init(id: "dragdrop", title: "Import and export", detail: "Drag LRC/LRCX into the app, export current lyrics beside a track or chosen folder", status: .available),
        .init(id: "filter", title: "Lyrics filters", detail: "Default LyricsX filter patterns and smart filtering", status: .available),
    ]
}
