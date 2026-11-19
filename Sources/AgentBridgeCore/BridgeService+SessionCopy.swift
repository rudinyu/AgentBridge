import Foundation

/// Which commit a session created from another session pins.
public enum SessionCommitChoice: String, Codable, Sendable, CaseIterable {
    /// The source session's pinned commit.
    case sameAsSource
    /// The source repository's HEAD when the new session is created.
    case sourceHead
}

/// A session created from another one, and whether its change plan came along.
public struct SessionCopyResult: Sendable {
    public let session: SessionRecord
    public let sourceSessionID: UUID
    /// The saved, unapproved copy of the source's change plan, if one was copied.
    public let copiedChangePlan: ChangePlan?
    /// Set when the source had a change plan that could not be saved on the new
    /// session. The new session exists either way.
    public let changePlanCopyError: String?
}

/// The options of `agentbridge session create --like SESSION-ID`, after `create`.
public struct SessionLikeArguments: Equatable, Sendable {
    public static let usage = "Usage: agentbridge session create --like SESSION-ID [--model NAME] [--effort LEVEL] [--latest-commit] [--profile PROFILE-ID]"

    public var sourceSessionID: UUID
    /// Nil keeps the source's model; an empty value means the CLI default.
    public var model: String?
    /// Nil keeps the source's effort; an empty value means the CLI default.
    public var effort: String?
    public var latestCommit = false
    public var profileID: UUID?

    public init(sourceSessionID: UUID, model: String? = nil, effort: String? = nil, latestCommit: Bool = false, profileID: UUID? = nil) {
        self.sourceSessionID = sourceSessionID
        self.model = model
        self.effort = effort
        self.latestCommit = latestCommit
        self.profileID = profileID
    }

    public var commit: SessionCommitChoice { latestCommit ? .sourceHead : .sameAsSource }

    /// The model choice to pass on, or nil to keep the source's. Only the value
    /// given is replaced; the other one stays the source's.
    public func modelChoice(source: SessionRecord) -> ProviderModelChoice? {
        guard model != nil || effort != nil else { return nil }
        return ProviderModelChoice(model: model ?? source.model, reasoningEffort: effort ?? source.reasoningEffort)
    }

    /// `--provider`, `--repo`, `--changes` and `--interactive` come from the
    /// source session, so giving one is an error.
    public static func parse(_ arguments: [String]) throws -> SessionLikeArguments {
        var sourceID: UUID?
        var model: String?
        var effort: String?
        var latestCommit = false
        var profileID: UUID?
        var index = 0
        func value(for option: String) throws -> String {
            guard index < arguments.count, !arguments[index].hasPrefix("--") else {
                throw AgentBridgeError.invalidInput("\(option) requires a value.")
            }
            defer { index += 1 }
            return arguments[index]
        }
        while index < arguments.count {
            let option = arguments[index]
            index += 1
            switch option {
            case "--like":
                guard sourceID == nil else { throw AgentBridgeError.invalidInput("\(option) cannot be repeated.") }
                guard let parsed = UUID(uuidString: try value(for: option)) else {
                    throw AgentBridgeError.invalidInput("The --like option needs a valid session UUID.")
                }
                sourceID = parsed
            case "--model":
                guard model == nil else { throw AgentBridgeError.invalidInput("\(option) cannot be repeated.") }
                model = try value(for: option)
            case "--effort":
                guard effort == nil else { throw AgentBridgeError.invalidInput("\(option) cannot be repeated.") }
                effort = try value(for: option)
            case "--latest-commit":
                latestCommit = true
            case "--profile":
                guard profileID == nil else { throw AgentBridgeError.invalidInput("\(option) cannot be repeated.") }
                guard let parsed = UUID(uuidString: try value(for: option)) else {
                    throw AgentBridgeError.invalidInput("--profile needs a valid profile UUID.")
                }
                profileID = parsed
            case "--provider", "--repo", "--changes", "--interactive":
                throw AgentBridgeError.invalidInput("The \(option) option cannot be used with --like; the new session takes it from the source session.")
            default:
                throw AgentBridgeError.invalidInput("Unknown session create option \(option).")
            }
        }
        guard let sourceID else { throw AgentBridgeError.invalidInput(usage) }
        return SessionLikeArguments(sourceSessionID: sourceID, model: model, effort: effort, latestCommit: latestCommit, profileID: profileID)
    }
}

extension BridgeService {
    /// The session to copy from. A removed, cancelled or failed session still
    /// works: only its record is read, never its workspace.
    public func sessionCopySource(_ sessionID: UUID) throws -> SessionRecord {
        if let session = try store.session(id: sessionID) { return session }
        guard let removed = try store.loadSessions(includingRemoved: true).first(where: { $0.id == sessionID }) else {
            throw AgentBridgeError.sessionNotFound(sessionID)
        }
        return removed
    }

    /// Creates a new session with the source session's provider, repository and
    /// access mode. The account defaults to the source's and must be for the same
    /// provider; the model and effort default to the source's. `createSession`
    /// checks all of them as it does for any new session.
    ///
    /// An isolated-changes source's plan is saved on the new session through
    /// `createChangePlan`, so it waits for a new approval. Approvals, verification,
    /// accepted or applied changes, workspace files, provider session IDs and
    /// enabled extensions are never copied.
    public func createSession(
        like sourceSessionID: UUID,
        modelChoice: ProviderModelChoice? = nil,
        accountProfileID: UUID? = nil,
        commit: SessionCommitChoice = .sameAsSource
    ) async throws -> SessionCopyResult {
        let source = try sessionCopySource(sourceSessionID)
        let accessMode = source.policy.accessMode
        if source.provider != .local, accessMode != .readOnly, try store.loadSettings().usageMode != .subscription {
            throw AgentBridgeError.sessionMismatch("Isolated changes and interactive terminal sessions need the official CLI subscription sign-in. Switch to subscription mode to create a session like this one.")
        }
        let session = try await createSession(
            sourcePath: source.sourceRepositoryPath,
            provider: source.provider,
            accessMode: accessMode,
            snapshotCommit: commit == .sameAsSource ? source.snapshotCommit : nil,
            accountProfileID: accountProfileID ?? source.accountProfileID,
            modelChoice: modelChoice ?? source.modelChoice
        )

        var copiedPlan: ChangePlan?
        var planError: String?
        if accessMode == .isolatedChanges, let plan = source.changePlan {
            do {
                copiedPlan = try createChangePlan(
                    sessionID: session.id,
                    title: plan.title,
                    summary: plan.summary,
                    steps: plan.steps,
                    includesSharedMemory: plan.includesSharedMemory
                )
            } catch {
                planError = "The new session was created, but the change plan was not copied: \(error.localizedDescription)"
            }
        }
        let sourceID = source.id.uuidString.lowercased()
        let message: String
        if copiedPlan != nil {
            message = "Created from session \(sourceID); its change plan was copied and must be approved again."
        } else if planError != nil {
            message = "Created from session \(sourceID); its change plan could not be copied."
        } else {
            message = "Created from session \(sourceID); there was no change plan to copy."
        }
        // The session exists by now, so a failed audit write must not hide it.
        // The message names the source and the plan outcome, never prompt text.
        try? store.appendEvent(AuditEvent(sessionID: session.id, kind: "session.created_like", message: message))
        return SessionCopyResult(
            session: (try? loadSession(session.id)) ?? session,
            sourceSessionID: source.id,
            copiedChangePlan: copiedPlan,
            changePlanCopyError: planError
        )
    }
}
