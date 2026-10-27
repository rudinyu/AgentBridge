// swift-tools-version: 6.0
import PackageDescription

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
        .target(name: "AgentBridgeCore"),
        .executableTarget(name: "AgentBridgeCLI", dependencies: ["AgentBridgeCore"]),
        .executableTarget(
            name: "AgentBridgeApp",
            dependencies: ["AgentBridgeCore", .product(name: "SwiftTerm", package: "SwiftTerm")],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "AgentBridgeCoreTests", dependencies: ["AgentBridgeCore"], resources: [.process("Fixtures")])
    ],
    swiftLanguageModes: [.v5]
)
