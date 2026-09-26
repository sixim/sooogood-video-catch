// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MediaFetch",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MediaFetch", targets: ["MediaFetch"]),
        .library(name: "MediaFetchCore", targets: ["MediaFetchCore"]),
        .library(name: "MediaFetchVideo", targets: ["MediaFetchVideo"]),
        .library(name: "MediaFetchMusic", targets: ["MediaFetchMusic"]),
        .library(name: "MediaFetchTorrent", targets: ["MediaFetchTorrent"])
    ],
    targets: [
        .target(
            name: "MediaFetchCore",
            path: "Sources/MediaFetchCore"
        ),
        .target(
            name: "MediaFetchVideo",
            dependencies: ["MediaFetchCore"],
            path: "Sources/MediaFetchVideo"
        ),
        .target(
            name: "MediaFetchMusic",
            dependencies: ["MediaFetchCore"],
            path: "Sources/MediaFetchMusic",
            linkerSettings: [
                .linkedFramework("AVFoundation")
            ]
        ),
        .target(
            name: "MediaFetchTorrent",
            dependencies: ["MediaFetchCore"],
            path: "Sources/MediaFetchTorrent"
        ),
        .executableTarget(
            name: "MediaFetch",
            dependencies: ["MediaFetchCore", "MediaFetchVideo", "MediaFetchMusic", "MediaFetchTorrent"],
            path: "Sources/MediaFetch"
        ),
        .testTarget(
            name: "MediaFetchTests",
            dependencies: ["MediaFetch", "MediaFetchCore", "MediaFetchVideo", "MediaFetchMusic", "MediaFetchTorrent"],
            path: "Tests/MediaFetchTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
