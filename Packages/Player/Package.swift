// swift-tools-version: 6.2
// Apache 2 license - developer@infinitecontext.com
import PackageDescription

/// VLCKit, for the formats Apple's player can't open, and a small SwiftUI wrapper around it.
/// iPhone only: the Mac app never links it. Run fetch-vlckit.sh once before building, which
/// downloads VideoLAN's own build and checks it against VideoLAN's checksum.
let package = Package(
    name: "Player",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "VLCPlayback", targets: ["VLCPlayback"]),
    ],
    targets: [
        // VideoLAN's MobileVLCKit, LGPL 2.1, linked dynamically. See fetch-vlckit.sh.
        .binaryTarget(name: "MobileVLCKit", path: "Binaries/MobileVLCKit.xcframework"),
        // VLCKit's delegate is Objective-C and predates Swift's checked concurrency.
        .target(
            name: "VLCPlayback",
            dependencies: ["MobileVLCKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
