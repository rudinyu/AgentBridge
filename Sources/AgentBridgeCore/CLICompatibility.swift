import Foundation

/// What AgentBridge learned about an installed provider CLI: its version and
/// whether the flags AgentBridge passes are still advertised by `--help`.
/// It is advisory. AgentBridge still fails closed on output it cannot parse,
/// so a report never blocks a run.
public struct CLICompatibilityReport: Equatable, Sendable {
    public enum VersionStatus: Equatable, Sendable {
        case matchesTested
        case newerThanTested
        case olderThanTested
        case unreadable
    }

    public let provider: AgentProvider
    public let version: String?
    public let testedVersion: String
    public let versionStatus: VersionStatus
    /// Flags AgentBridge relies on that the CLI's help no longer mentions.
    public let missingFlags: [String]
    /// False when the help text could not be read, so `missingFlags` says nothing.
    public let flagsWereChecked: Bool

    public init(
        provider: AgentProvider,
        version: String?,
        testedVersion: String,
        versionStatus: VersionStatus,
        missingFlags: [String],
        flagsWereChecked: Bool
    ) {
        self.provider = provider
        self.version = version
        self.testedVersion = testedVersion
        self.versionStatus = versionStatus
        self.missingFlags = missingFlags
        self.flagsWereChecked = flagsWereChecked
    }

    /// Anything the user should look at before trusting a run.
    public var needsAttention: Bool {
        versionStatus == .olderThanTested || versionStatus == .unreadable || !missingFlags.isEmpty || !flagsWereChecked
    }
}

public enum CLICompatibility {
    /// The CLI versions AgentBridge was last checked against, and the flags it passes.
    struct Profile {
        let testedVersion: String
        let versionArguments: [String]
        /// Each probe runs `arguments` and looks for `flags` in the output.
        let probes: [(arguments: [String], flags: [String])]
    }

    static func profile(for provider: AgentProvider) -> Profile? {
        switch provider {
        case .claude:
            return Profile(
                testedVersion: "2.1.311",
                versionArguments: ["--version"],
                // `--append-system-prompt-file` is listed as `--append-system-prompt[-file]`.
                probes: [(["--help"], [
                    "--print", "--output-format", "--verbose", "--include-partial-messages",
                    "--permission-mode", "--permission-prompts", "--restricted", "--safe-mode",
                    "--tools", "--no-session-persistence", "--input-format", "--add-dir",
                    "--setting-sources", "--settings", "--append-system-prompt",
                    "--disable-slash-commands", "--max-budget-usd", "--mcp-config",
                    "--no-chrome", "--resume", "--session-id", "--strict-mcp-config"
                ])]
            )
        case .codex:
            return Profile(
                testedVersion: "0.166.0",
                versionArguments: ["--version"],
                probes: [
                    (["--help"], ["--sandbox", "--cd", "--ask-for-approval", "--no-daemon", "--disable"]),
                    (["exec", "--help"], ["--json", "--ignore-user-config", "--ignore-rules", "--ephemeral", "--skip-git-repo-check"])
                ]
            )
        case .local:
            return nil
        }
    }

    /// Flags AgentBridge passes that the CLI does not list in its help, so they
    /// cannot be probed. `--max-turns` is only used on the paid Claude API path and
    /// is not advertised by `claude --help`; whether the CLI still accepts it can
    /// only be confirmed by a real run.
    static let flagsThatCannotBeProbed: Set<String> = ["--max-turns"]

    /// Every flag the probes check, across providers.
    static var probedFlags: Set<String> {
        var flags: Set<String> = []
        for provider in AgentProvider.allCases {
            for probe in profile(for: provider)?.probes ?? [] { flags.formUnion(probe.flags) }
        }
        return flags
    }

    /// First `major.minor.patch` found in a `--version` line, for example
    /// "2.1.311 (Claude Code)" or "codex-cli 0.166.0".
    static func parseVersion(_ output: String) -> String? {
        guard let range = output.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) else { return nil }
        return String(output[range])
    }

    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = lhs.split(separator: ".").compactMap { Int($0) }
        let right = rhs.split(separator: ".").compactMap { Int($0) }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// Pure evaluation of the CLI's answers; `helpOutputs` holds one entry per
    /// probe, or `nil` where that probe could not be read.
    static func evaluate(
        provider: AgentProvider,
        versionOutput: String?,
        helpOutputs: [String?]
    ) -> CLICompatibilityReport? {
        guard let profile = profile(for: provider) else { return nil }
        let version = versionOutput.flatMap(parseVersion)
        let status: CLICompatibilityReport.VersionStatus
        if let version {
            switch compare(version, profile.testedVersion) {
            case .orderedSame: status = .matchesTested
            case .orderedDescending: status = .newerThanTested
            case .orderedAscending: status = .olderThanTested
            }
        } else {
            status = .unreadable
        }
        var missing: [String] = []
        var checked = true
        for (index, probe) in profile.probes.enumerated() {
            guard index < helpOutputs.count, let help = helpOutputs[index] else {
                checked = false
                continue
            }
            missing += probe.flags.filter { !help.contains($0) }
        }
        return CLICompatibilityReport(
            provider: provider,
            version: version,
            testedVersion: profile.testedVersion,
            versionStatus: status,
            missingFlags: missing,
            flagsWereChecked: checked
        )
    }
}
