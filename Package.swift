// swift-tools-version:6.0
import PackageDescription

/// Embeds an Info.plist (usage descriptions) into a bare CLI binary.
func embedPlist(_ path: String) -> [LinkerSetting] {
    [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", path])]
}

let swift5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "MusicAmp",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
    ],
    targets: [
        .target(name: "AudioTap", swiftSettings: swift5),
        .target(name: "MusicControl", swiftSettings: swift5),
        .executableTarget(
            name: "MusicAmp",
            dependencies: ["AudioTap", "MusicControl", "ZIPFoundation"],
            swiftSettings: swift5,
            linkerSettings: embedPlist("Support/MusicAmp-Info.plist")
        ),
        .executableTarget(
            name: "TapSpike",
            dependencies: ["AudioTap"],
            swiftSettings: swift5,
            linkerSettings: embedPlist("Support/TapSpike-Info.plist")
        ),
        .executableTarget(
            name: "MusicCtl",
            dependencies: ["MusicControl"],
            swiftSettings: swift5,
            linkerSettings: embedPlist("Support/MusicCtl-Info.plist")
        ),
    ]
)
