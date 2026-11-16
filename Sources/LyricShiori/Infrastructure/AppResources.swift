import Foundation

extension Bundle {
    static let lyricShioriResources: Bundle =
        main.url(forResource: "LyricShiori_LyricShiori", withExtension: "bundle")
            .flatMap(Bundle.init(url:)) ?? module
}
