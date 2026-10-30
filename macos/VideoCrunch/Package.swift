// swift-tools-version:5.9
// The macOS app. install_macos_quick_action.sh builds it with
// `swift build -c release` and wraps the binary in VideoCrunch.app;
// `swift test` runs the logic tests. Every file under Sources/ is part of
// the app — no list to keep in sync.
import PackageDescription

let package = Package(
    name: "VideoCrunch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "VideoCrunch",
            path: "Sources/VideoCrunch"
        ),
        .testTarget(
            name: "VideoCrunchTests",
            dependencies: ["VideoCrunch"],
            path: "Tests/VideoCrunchTests"
        ),
    ]
)
