// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacGameDock",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "MacGameDock", targets: ["MacGameDock"])],
    targets: [
        .executableTarget(name: "MacGameDock", resources: [.copy("Resources")]),
        .testTarget(name: "MacGameDockTests", dependencies: ["MacGameDock"])
    ]
)
