import Darwin
import Foundation
import AgentBridgeCore

extension AgentBridgeCLI {
    static func parseProvider(_ value: String) throws -> AgentProvider {
        guard let provider = AgentProvider(rawValue: value) else {
            throw AgentBridgeError.invalidInput("The provider must be codex, claude or local.")
        }
        return provider
    }

    static func readPromptFromStandardInput(maximumBytes: Int) throws -> String {
        try readBoundedStandardInput(maximumBytes: maximumBytes, label: "Prompt")
    }

    static func readBoundedStandardInput(maximumBytes: Int, label: String) throws -> String {
        guard maximumBytes > 0 else { throw AgentBridgeError.invalidInput("Input byte limit must be positive.") }
        var data = Data()
        while data.count <= maximumBytes {
            let amount = min(65_536, maximumBytes + 1 - data.count)
            guard amount > 0 else { break }
            let chunk = try FileHandle.standardInput.read(upToCount: amount) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        guard data.count <= maximumBytes else { throw AgentBridgeError.invalidInput("\(label) exceeds its \(maximumBytes)-byte input limit.") }
        guard let text = String(data: data, encoding: .utf8) else { throw AgentBridgeError.invalidInput("\(label) must be UTF-8 text.") }
        return text
    }
}
