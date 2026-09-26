// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MediaFetch",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MediaFetch", targets: ["MediaFetch"]),
        .library(name: "MediaFetchCore", targets: ["MediaFetchCore"]),
        .library(name: "MediaFetchVideo", targets: ["MediaFetchVideo"]),
        .library(name: "MediaFetchMusic", targets: ["MediaFetchMusic"])
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
        .executableTarget(
            name: "MediaFetch",
            dependencies: ["MediaFetchCore", "MediaFetchVideo", "MediaFetchMusic"],
            path: "Sources/MediaFetch"
        ),
        .testTarget(
            name: "MediaFetchTests",
            dependencies: ["MediaFetch", "MediaFetchCore", "MediaFetchVideo", "MediaFetchMusic"],
            path: "Tests/MediaFetchTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
