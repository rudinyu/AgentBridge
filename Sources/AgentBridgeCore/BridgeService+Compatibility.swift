import Foundation

extension BridgeService {
    /// Asks the installed provider CLI for its version and help text, using the
    /// same sanitized environment as the sign-in check. Nothing here starts a
    /// model run or touches the account.
    public func cliCompatibility(provider: AgentProvider, profileID: UUID? = nil) async throws -> CLICompatibilityReport? {
        guard let profile = CLICompatibility.profile(for: provider) else { return nil }
        let account = try profileID.map(accountProfile(id:)) ?? selectedAccountProfile(provider: provider)
        let executable = try RuntimeEnvironment.resolveExecutable(
            provider: provider,
            configuredPath: try settings().binaryPath(for: provider)
        )
        let temp = try makePrivateTemporaryDirectory(label: "compat-\(account.id.uuidString.lowercased())-\(UUID().uuidString.lowercased())")
        defer { try? FileManager.default.removeItem(at: temp) }
        let environment = try providerEnvironment(profile: account, privateTemporaryDirectory: temp)

        func output(of arguments: [String]) async -> String? {
            let spec = ProcessSpec(
                executableURL: executable,
                arguments: arguments,
                environment: environment,
                workingDirectoryURL: URL(fileURLWithPath: temp.path, isDirectory: true),
                standardInput: Data(),
                timeout: 12,
                outputLimit: 256_000
            )
            guard let result = try? await runner.run(spec),
                  !result.wasCancelled, !result.timedOut, !result.outputWasTruncated, result.exitCode == 0
            else { return nil }
            return String(decoding: result.standardOutput + result.standardError, as: UTF8.self)
        }

        let versionOutput = await output(of: profile.versionArguments)
        var helpOutputs: [String?] = []
        for probe in profile.probes {
            helpOutputs.append(await output(of: probe.arguments))
        }
        return CLICompatibility.evaluate(provider: provider, versionOutput: versionOutput, helpOutputs: helpOutputs)
    }
}
