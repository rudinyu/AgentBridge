import Foundation

/// Runs `/usr/bin/git` for a test's own fixture repositories, cut off from this machine and the parent process:
/// no inherited `GIT_*` variables, no system or global config, no init templates, no hooks, and a fixed identity.
/// Product code under test runs its own Git and is not affected.
enum FixtureGit {
    struct Failure: LocalizedError {
        let arguments: [String]
        let status: Int32
        let output: String
        var errorDescription: String? { "git \(arguments.joined(separator: " ")) exited \(status): \(output)" }
    }

    /// Runs git and returns its trimmed standard output, throwing with git's output unless it exits 0.
    @discardableResult
    static func run(_ arguments: [String]) throws -> String {
        let result = try execute(arguments)
        guard result.status == 0 else {
            throw Failure(arguments: arguments, status: result.status, output: result.errors + result.output)
        }
        return result.output
    }

    /// Runs git and returns its exit status, for checks where a non-zero status is the expected answer.
    static func exitStatus(_ arguments: [String]) throws -> Int32 {
        try execute(arguments).status
    }

    private static func execute(_ arguments: [String]) throws -> (status: Int32, output: String, errors: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "core.hooksPath=/dev/null"] + arguments
        process.environment = [
            "HOME": NSTemporaryDirectory(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_TEMPLATE_DIR": "",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_AUTHOR_NAME": "AgentBridge Fixture",
            "GIT_AUTHOR_EMAIL": "agentbridge-fixture@example.invalid",
            "GIT_COMMITTER_NAME": "AgentBridge Fixture",
            "GIT_COMMITTER_EMAIL": "agentbridge-fixture@example.invalid"
        ]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
            String(decoding: stderr, as: UTF8.self)
        )
    }
}
