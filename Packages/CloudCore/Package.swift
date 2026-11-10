// swift-tools-version: 6.2
// Apache 2 license - developer@infinitecontext.com
import PackageDescription

let package = Package(
    name: "CloudCore",
    defaultLocalization: "en",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "CloudCore", targets: ["CloudCore"]),
        .library(name: "RemoteEngine", targets: ["RemoteEngine"]),
        .library(name: "SyncCore", targets: ["SyncCore"]),
        .library(name: "MountKit", targets: ["MountKit"]),
        .library(name: "FileProviderShell", targets: ["FileProviderShell"]),
        .library(name: "CloudDesign", targets: ["CloudDesign"]),
    ],
    targets: [
        // Words a person sees, in English and Spanish. See Words.swift.
        .target(name: "CloudCore", resources: [.process("Resources")]),
        // Built by Engine/build.sh.
        .binaryTarget(name: "CEngine", path: "Binaries/CEngine.xcframework"),
        .target(
            name: "RemoteEngine",
            dependencies: ["CloudCore", "CEngine"],
            linkerSettings: [
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security"),
                .linkedLibrary("resolv"),
            ]
        ),
        .target(
            name: "SyncCore",
            dependencies: ["CloudCore"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(name: "MountKit", dependencies: ["CloudCore", "SyncCore"]),
        // What both File Provider extensions share. It was written as the Mac extension's own code,
        // in Swift 5 mode, and stays in that mode so moving it here changed nothing.
        .target(
            name: "FileProviderShell",
            dependencies: ["CloudCore", "SyncCore", "MountKit", "RemoteEngine"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(name: "FakeRemote", dependencies: ["CloudCore"]),
        .target(name: "CloudDesign"),
        .testTarget(name: "MountKitTests", dependencies: ["MountKit", "SyncCore", "FakeRemote"]),
        .testTarget(
            name: "FileProviderShellTests",
            dependencies: ["FileProviderShell", "MountKit", "SyncCore", "FakeRemote"]
        ),
        .testTarget(name: "CloudCoreTests", dependencies: ["CloudCore"]),
        .testTarget(name: "RemoteEngineTests", dependencies: ["RemoteEngine"]),
        .testTarget(name: "SyncCoreTests", dependencies: ["SyncCore", "FakeRemote"]),
    ]
)
