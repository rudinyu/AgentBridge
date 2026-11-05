import Foundation

public enum InteractiveTerminalCommand {
    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func script(executablePath: String, sessionID: UUID) throws -> String {
        guard executablePath.hasPrefix("/"), !executablePath.contains("\0") else {
            throw AgentBridgeError.invalidInput("The interactive CLI must use an absolute executable path.")
        }
        let binary = Self.shellQuote(executablePath)
        let id = Self.shellQuote(sessionID.uuidString.lowercased())
        return "#!/bin/sh\nexec \(binary) interactive \(id)\n"
    }
}
