// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MediaFetch",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MediaFetch", targets: ["MediaFetch"])
    ],
    targets: [
        .executableTarget(
            name: "MediaFetch",
            path: "Sources/MediaFetch"
        ),
        .testTarget(
            name: "MediaFetchTests",
            dependencies: ["MediaFetch"],
            path: "Tests/MediaFetchTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
