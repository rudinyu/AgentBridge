import CryptoKit
import Foundation

public enum DiscussionStatus: String, Codable, Sendable {
    case ready
    case running
    case transitioning
    case completed
    case failed
    case cancelled

    public var isInFlight: Bool { self == .running || self == .transitioning }
}

/// One user-visible turn in a project-independent discussion. The transcript
/// is retained regardless of `isShareable`; that flag controls whether the
/// completed turn may be included in a later provider prompt or project handoff.
public struct DiscussionTurn: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let provider: AgentProvider
    public let accountProfileID: UUID
    public let sourceSharedMemoryConsent: Bool
    public var isShareable: Bool
    public let userText: String
    public var assistantText: String?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        provider: AgentProvider,
        accountProfileID: UUID,
        sourceSharedMemoryConsent: Bool,
        isShareable: Bool,
        userText: String,
        assistantText: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.provider = provider
        self.accountProfileID = accountProfileID
        self.sourceSharedMemoryConsent = sourceSharedMemoryConsent
        self.isShareable = isShareable
        self.userText = userText
        self.assistantText = assistantText
    }
}

public enum DiscussionProjectMode: String, Codable, Sendable {
    case createNew
    case attachExisting
}

public struct DiscussionHandoffTurn: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let provider: AgentProvider
    public let sourceAccountProfileID: UUID
    public let userText: String
    public let assistantText: String

    init(turn: DiscussionTurn, assistantText: String) {
        id = turn.id
        timestamp = turn.timestamp
        provider = turn.provider
        sourceAccountProfileID = turn.accountProfileID
        userText = turn.userText
        self.assistantText = assistantText
    }

    init(
        id: UUID,
        timestamp: Date,
        provider: AgentProvider,
        sourceAccountProfileID: UUID,
        userText: String,
        assistantText: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.provider = provider
        self.sourceAccountProfileID = sourceAccountProfileID
        self.userText = userText
        self.assistantText = assistantText
    }
}

/// A frozen, reviewable set of discussion turns and destination details. The
/// digest is recomputed from the persisted value before project creation/linking.
public struct DiscussionProjectHandoff: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let discussionID: UUID
    public let discussionRevision: Int
    public let destinationPath: String
    public let mode: DiscussionProjectMode
    public let targetProvider: AgentProvider
    public let targetProfileID: UUID
    public let accessMode: AccessMode
    public let expectedRepositoryCommit: String?
    public let selectedTurns: [DiscussionHandoffTurn]
    public let reviewedDigest: String
    public var consumedSessionID: UUID?

    init(
        id: UUID = UUID(),
        discussionID: UUID,
        discussionRevision: Int,
        destinationPath: String,
        mode: DiscussionProjectMode,
        targetProvider: AgentProvider,
        targetProfileID: UUID,
        accessMode: AccessMode,
        expectedRepositoryCommit: String?,
        selectedTurns: [DiscussionHandoffTurn],
        consumedSessionID: UUID? = nil
    ) {
        self.id = id
        self.discussionID = discussionID
        self.discussionRevision = discussionRevision
        self.destinationPath = destinationPath
        self.mode = mode
        self.targetProvider = targetProvider
        self.targetProfileID = targetProfileID
        self.accessMode = accessMode
        let normalizedExpectedRepositoryCommit = expectedRepositoryCommit?.lowercased()
        self.expectedRepositoryCommit = normalizedExpectedRepositoryCommit
        self.selectedTurns = selectedTurns
        self.reviewedDigest = Self.makeDigest(
            id: id,
            discussionID: discussionID,
            discussionRevision: discussionRevision,
            destinationPath: destinationPath,
            mode: mode,
            targetProvider: targetProvider,
            targetProfileID: targetProfileID,
            accessMode: accessMode,
            expectedRepositoryCommit: normalizedExpectedRepositoryCommit,
            selectedTurns: selectedTurns
        )
        self.consumedSessionID = consumedSessionID
    }

    func hasValidDigest() -> Bool {
        reviewedDigest == Self.makeDigest(
            id: id,
            discussionID: discussionID,
            discussionRevision: discussionRevision,
            destinationPath: destinationPath,
            mode: mode,
            targetProvider: targetProvider,
            targetProfileID: targetProfileID,
            accessMode: accessMode,
            expectedRepositoryCommit: expectedRepositoryCommit,
            selectedTurns: selectedTurns
        )
    }

    private static func makeDigest(
        id: UUID,
        discussionID: UUID,
        discussionRevision: Int,
        destinationPath: String,
        mode: DiscussionProjectMode,
        targetProvider: AgentProvider,
        targetProfileID: UUID,
        accessMode: AccessMode,
        expectedRepositoryCommit: String?,
        selectedTurns: [DiscussionHandoffTurn]
    ) -> String {
        let header = [
            id.uuidString.lowercased(),
            discussionID.uuidString.lowercased(),
            String(discussionRevision),
            destinationPath,
            mode.rawValue,
            targetProvider.rawValue,
            targetProfileID.uuidString.lowercased(),
            accessMode.rawValue,
            expectedRepositoryCommit ?? ""
        ]
        let turnFields = selectedTurns.flatMap { turn in
            [
                turn.id.uuidString.lowercased(),
                String(Int64(turn.timestamp.timeIntervalSince1970.rounded(.towardZero))),
                turn.provider.rawValue,
                turn.sourceAccountProfileID.uuidString.lowercased(),
                turn.userText,
                turn.assistantText
            ]
        }
        let payload = (header + turnFields).map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(payload.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

public struct DiscussionRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public var updatedAt: Date
    public var revision: Int
    public var dataRootPath: String
    public var provider: AgentProvider
    public var accountProfileID: UUID
    public var usageProfileIDs: Set<UUID>
    public var turns: [DiscussionTurn]
    public var transcriptWasTruncated: Bool
    public var handoffs: [DiscussionProjectHandoff]
    public var linkedSessionIDs: [UUID]
    public var status: DiscussionStatus

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        revision: Int = 1,
        dataRootPath: String,
        provider: AgentProvider,
        accountProfileID: UUID,
        usageProfileIDs: Set<UUID> = [],
        turns: [DiscussionTurn] = [],
        transcriptWasTruncated: Bool = false,
        handoffs: [DiscussionProjectHandoff] = [],
        linkedSessionIDs: [UUID] = [],
        status: DiscussionStatus = .ready
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.revision = revision
        self.dataRootPath = dataRootPath
        self.provider = provider
        self.accountProfileID = accountProfileID
        self.usageProfileIDs = usageProfileIDs
        self.turns = turns
        self.transcriptWasTruncated = transcriptWasTruncated
        self.handoffs = handoffs
        self.linkedSessionIDs = linkedSessionIDs
        self.status = status
    }
}
