// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "LyricShiori",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "LyricShiori", targets: ["LyricShiori"]),
    ],
    dependencies: [
        .package(url: "https://github.com/MxIris-LyricsX-Project/LyricsKit", from: "1.8.0"),
    ],
    targets: [
        .executableTarget(
            name: "LyricShiori",
            dependencies: [
                .product(name: "LyricsKit", package: "LyricsKit"),
            ],
            path: "Sources/LyricShiori",
            exclude: ["Supporting/Info.plist"]
        ),
    ]
)
