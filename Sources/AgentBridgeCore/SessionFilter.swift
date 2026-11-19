import Foundation

/// Which sessions a list shows. Every criterion left empty matches every
/// session, and a session must match all criteria that are set.
public struct SessionFilter: Equatable, Sendable {
    /// Text searched, case-insensitively, in the source repository folder name,
    /// the model, the reasoning effort, the change plan title, any extra text
    /// the caller passes (such as the shown model label), and as a prefix of the
    /// pinned commit.
    public var query: String
    public var provider: AgentProvider?
    public var status: SessionStatus?
    public var accessMode: AccessMode?
    /// The source repository, compared after resolving symbolic links.
    public var repositoryPath: String?

    public init(
        query: String = "",
        provider: AgentProvider? = nil,
        status: SessionStatus? = nil,
        accessMode: AccessMode? = nil,
        repositoryPath: String? = nil
    ) {
        self.query = query
        self.provider = provider
        self.status = status
        self.accessMode = accessMode
        self.repositoryPath = repositoryPath
    }

    /// Whether any criterion is set.
    public var isActive: Bool {
        !trimmedQuery.isEmpty || provider != nil || status != nil || accessMode != nil || repositoryPath != nil
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Whether `session` passes every criterion that is set. `extraText` is also
    /// searched by the query, for labels only the caller can make.
    public func matches(_ session: SessionRecord, extraText: [String] = []) -> Bool {
        if let provider, session.provider != provider { return false }
        if let status, session.status != status { return false }
        if let accessMode, session.policy.accessMode != accessMode { return false }
        if let repositoryPath, Self.canonicalPath(repositoryPath) != Self.canonicalPath(session.sourceRepositoryPath) {
            return false
        }
        let needle = trimmedQuery
        guard !needle.isEmpty else { return true }
        if session.snapshotCommit.lowercased().hasPrefix(needle.lowercased()) { return true }
        let haystacks = [
            URL(fileURLWithPath: session.sourceRepositoryPath).lastPathComponent,
            session.model,
            session.reasoningEffort,
            session.changePlan?.title
        ].compactMap { $0 } + extraText
        return haystacks.contains { $0.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// `sessions` that match, in their order.
    public func apply(to sessions: [SessionRecord]) -> [SessionRecord] {
        sessions.filter { matches($0) }
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath().path
    }

    // MARK: Command line

    /// The names `agentbridge sessions --mode` takes for each access mode.
    public static func commandLineName(of mode: AccessMode) -> String {
        switch mode {
        case .readOnly: "read-only"
        case .isolatedChanges: "changes"
        case .interactiveManualApproval: "interactive"
        }
    }

    public static let commandLineUsage =
        "Usage: agentbridge sessions [--provider codex|claude|local] [--status created|running|completed|failed|cancelled] [--mode read-only|changes|interactive] [--repo PATH]"

    /// The filter for `agentbridge sessions` options. A relative `--repo` is
    /// resolved against the current directory.
    public static func parseCommandLine(_ arguments: [String]) throws -> SessionFilter {
        var filter = SessionFilter()
        var index = 0
        func value(for option: String) throws -> String {
            index += 1
            guard index < arguments.count, !arguments[index].hasPrefix("--") else {
                throw AgentBridgeError.invalidInput("\(option) needs a value.\n\(commandLineUsage)")
            }
            return arguments[index]
        }
        while index < arguments.count {
            let option = arguments[index]
            switch option {
            case "--provider":
                let raw = try value(for: option)
                guard let provider = AgentProvider(rawValue: raw.lowercased()) else {
                    throw AgentBridgeError.invalidInput("--provider takes codex, claude or local.\n\(commandLineUsage)")
                }
                filter.provider = provider
            case "--status":
                let raw = try value(for: option)
                guard let status = SessionStatus(rawValue: raw.lowercased()) else {
                    throw AgentBridgeError.invalidInput("--status takes created, running, completed, failed or cancelled.\n\(commandLineUsage)")
                }
                filter.status = status
            case "--mode":
                let raw = try value(for: option).lowercased()
                guard let mode = [AccessMode.readOnly, .isolatedChanges, .interactiveManualApproval]
                    .first(where: { commandLineName(of: $0) == raw }) else {
                    throw AgentBridgeError.invalidInput("--mode takes read-only, changes or interactive.\n\(commandLineUsage)")
                }
                filter.accessMode = mode
            case "--repo":
                filter.repositoryPath = try value(for: option)
            default:
                throw AgentBridgeError.invalidInput("Unknown sessions option \(option).\n\(commandLineUsage)")
            }
            index += 1
        }
        return filter
    }
}
