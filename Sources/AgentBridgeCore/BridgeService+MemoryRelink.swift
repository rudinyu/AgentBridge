import Foundation

/// Shared memory belongs to a repository path plus a commit. When a repository is
/// moved or renamed, its memory stays under the old path. These calls let the
/// user copy it across; nothing is ever linked automatically.
public struct MemoryRelinkCandidate: Equatable, Sendable {
    /// The earlier scope whose memory would be copied.
    public let source: SharedMemoryScope
    public let turnCount: Int
    public let hasNotes: Bool
}

extension BridgeService {
    /// Memory stored for the same commit under a path that no longer exists,
    /// offered only while the session's own memory is still empty. A second
    /// clone is not a candidate: its old path still exists, so nothing is
    /// ambiguous about which copy owns that memory.
    public func memoryRelinkCandidates(sessionID: UUID) throws -> [MemoryRelinkCandidate] {
        let session = try loadSession(sessionID)
        let destination = try memoryScope(for: session)
        guard try isEmptyMemory(sharedMemoryStore.snapshot(scope: destination)) else { return [] }
        return try sharedMemoryStore.knownScopes().compactMap { source in
            guard source.key != destination.key,
                  source.snapshotCommit == destination.snapshotCommit,
                  source.repositoryPath != destination.repositoryPath,
                  !FileManager.default.fileExists(atPath: source.repositoryPath)
            else { return nil }
            let snapshot = try sharedMemoryStore.snapshot(scope: source)
            guard !isEmptyMemory(snapshot) else { return nil }
            return MemoryRelinkCandidate(
                source: source,
                turnCount: snapshot.turns.count,
                hasNotes: !snapshot.notes.isEmpty
            )
        }
    }

    /// Copies the chosen earlier scope's turns and notes into the session's
    /// scope. The original is left unchanged. Retrying after an interruption is
    /// safe because turns keep their IDs and appending an identical turn is a
    /// no-op.
    @discardableResult
    public func relinkMemory(sessionID: UUID, sourceKey: String) throws -> MemoryRelinkCandidate {
        let session = try loadSession(sessionID)
        let destination = try memoryScope(for: session)
        let candidates = try memoryRelinkCandidates(sessionID: sessionID)
        guard let candidate = candidates.first(where: { $0.source.key == sourceKey }) else {
            throw AgentBridgeError.invalidInput("That memory is not a candidate for this session. It may already be linked, or its repository path still exists.")
        }
        let snapshot = try sharedMemoryStore.snapshot(scope: candidate.source)
        try sharedMemoryStore.appendTurns(scope: destination, turns: snapshot.turns)
        if !snapshot.notes.isEmpty {
            try sharedMemoryStore.setNotes(scope: destination, notes: snapshot.notes)
        }
        try store.appendEvent(AuditEvent(
            sessionID: sessionID,
            kind: "memory.relinked",
            message: "Copied \(snapshot.turns.count) memory turn(s) from scope \(candidate.source.key.prefix(12)) (earlier path \(candidate.source.repositoryPath)); the original was not changed."
        ))
        return candidate
    }

    private func isEmptyMemory(_ snapshot: SharedMemorySnapshot) -> Bool {
        snapshot.turns.isEmpty && snapshot.notes.isEmpty
    }
}
