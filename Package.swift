// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AgentDeck",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "DeckCore"),
        .executableTarget(name: "AgentDeck", dependencies: ["DeckCore"]),
        .testTarget(name: "DeckCoreTests", dependencies: ["DeckCore"]),
    ]
)
