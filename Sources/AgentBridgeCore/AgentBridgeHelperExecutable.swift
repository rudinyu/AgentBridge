import Foundation

enum AgentBridgeHelperExecutable {
    static let installedMacControlHelperPath = "/Applications/MacControl.app/Contents/Helpers/MacControlHelper.app/Contents/MacOS/mac-control-mcp"

    static func resolve(
        bundleURL: URL = Bundle.main.bundleURL,
        argumentZero: String? = CommandLine.arguments.first,
        fileManager: FileManager = .default
    ) throws -> URL {
        var candidates: [URL] = [
            bundleURL.appendingPathComponent("Contents/Helpers/agentbridge", isDirectory: false)
        ]
        candidates.append(bundleURL.deletingLastPathComponent().appendingPathComponent("agentbridge", isDirectory: false))
        if let argumentZero, !argumentZero.contains("\0") {
            let rawLaunchURL = URL(fileURLWithPath: argumentZero, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
            let launchedURL = rawLaunchURL.standardizedFileURL
            if launchedURL.lastPathComponent == "agentbridge" {
                candidates.append(launchedURL)
            }
        }
        for candidate in candidates {
            let standardized = candidate.standardizedFileURL
            guard standardized.path.hasPrefix("/"),
                  fileManager.isExecutableFile(atPath: standardized.path) else { continue }
            let resolved = standardized.resolvingSymlinksInPath().standardizedFileURL
            guard fileManager.isExecutableFile(atPath: resolved.path) else { continue }
            return resolved
        }
        throw ActiveExtensionRuntimeError.invalidConfiguration("The bundled AgentBridge MCP proxy executable is missing.")
    }
}
