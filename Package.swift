// swift-tools-version: 6.0
import PackageDescription

// Complete concurrency checking for product code while staying in the Swift 5 language mode.
let strictConcurrency: [SwiftSetting] = [.enableExperimentalFeature("StrictConcurrency")]

let package = Package(
    name: "AgentBridge",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentBridgeCore", targets: ["AgentBridgeCore"]),
        .executable(name: "agentbridge", targets: ["AgentBridgeCLI"]),
        .executable(name: "AgentBridgeApp", targets: ["AgentBridgeApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0")
    ],
    targets: [
        .target(name: "AgentBridgeCore", swiftSettings: strictConcurrency),
        .executableTarget(name: "AgentBridgeCLI", dependencies: ["AgentBridgeCore"], swiftSettings: strictConcurrency),
        .executableTarget(
            name: "AgentBridgeApp",
            dependencies: ["AgentBridgeCore", .product(name: "SwiftTerm", package: "SwiftTerm")],
            resources: [.process("Resources")],
            swiftSettings: strictConcurrency
        ),
        .testTarget(name: "AgentBridgeCoreTests", dependencies: ["AgentBridgeCore"], resources: [.process("Fixtures")])
    ],
    swiftLanguageModes: [.v5]
)
