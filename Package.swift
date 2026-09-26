// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MediaFetch",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MediaFetch", targets: ["MediaFetch"]),
        .executable(name: "sooogood-mcp", targets: ["SooogoodMCP"]),
        .library(name: "MediaFetchCore", targets: ["MediaFetchCore"]),
        .library(name: "MediaFetchVideo", targets: ["MediaFetchVideo"]),
        .library(name: "MediaFetchMusic", targets: ["MediaFetchMusic"]),
        .library(name: "MediaFetchTorrent", targets: ["MediaFetchTorrent"]),
        .library(name: "MediaFetchResolve", targets: ["MediaFetchResolve"]),
        .library(name: "MediaFetchTools", targets: ["MediaFetchTools"]),
        .library(name: "MediaFetchControl", targets: ["MediaFetchControl"])
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
        .target(
            name: "MediaFetchResolve",
            dependencies: ["MediaFetchCore"],
            path: "Sources/MediaFetchResolve"
        ),
        .target(
            name: "MediaFetchTools",
            dependencies: ["MediaFetchCore"],
            path: "Sources/MediaFetchTools"
        ),
        .target(
            name: "MediaFetchControl",
            dependencies: ["MediaFetchCore"],
            path: "Sources/MediaFetchControl"
        ),
        .executableTarget(
            name: "SooogoodMCP",
            dependencies: ["MediaFetchCore", "MediaFetchControl"],
            path: "Sources/SooogoodMCP"
        ),
        .executableTarget(
            name: "MediaFetch",
            dependencies: ["MediaFetchCore", "MediaFetchVideo", "MediaFetchMusic", "MediaFetchTorrent", "MediaFetchResolve", "MediaFetchTools", "MediaFetchControl"],
            path: "Sources/MediaFetch"
        ),
        .testTarget(
            name: "MediaFetchTests",
            dependencies: ["MediaFetch", "MediaFetchCore", "MediaFetchVideo", "MediaFetchMusic", "MediaFetchTorrent", "MediaFetchResolve", "MediaFetchTools", "MediaFetchControl"],
            path: "Tests/MediaFetchTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
