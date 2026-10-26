import Foundation

public enum InteractiveTerminalCommand {
    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func script(executablePath: String, sessionID: UUID) throws -> String {
        guard executablePath.hasPrefix("/"), !executablePath.contains("\0") else {
            throw AgentBridgeError.invalidInput("互動 CLI 必須使用絕對執行檔路徑。")
        }
        let binary = Self.shellQuote(executablePath)
        let id = Self.shellQuote(sessionID.uuidString.lowercased())
        return "#!/bin/sh\nexec \(binary) interactive \(id)\n"
    }
}
