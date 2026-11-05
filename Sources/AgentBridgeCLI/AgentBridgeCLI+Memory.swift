import Darwin
import Foundation
import AgentBridgeCore

extension AgentBridgeCLI {
    static func memoryCommand(_ arguments: [String], service: BridgeService) throws {
        guard let action = arguments.first, arguments.count >= 2,
              let sessionID = UUID(uuidString: arguments[1]) else {
            throw AgentBridgeError.invalidInput("Usage: agentbridge memory show|notes|clear|relink-candidates|relink SESSION-ID [--confirm]")
        }
        switch action {
        case "show":
            guard arguments.count == 2 else { throw AgentBridgeError.invalidInput("Usage: agentbridge memory show SESSION-ID") }
            let snapshot = try service.sharedMemory(sessionID: sessionID)
            print("Scope: \(snapshot.scope.repositoryPath) @ \(snapshot.scope.snapshotCommit.prefix(12))")
            print("Revision: \(snapshot.revision); turns: \(snapshot.turns.count); content truncated: \(snapshot.wasTruncated ? "yes" : "no")")
            print("\n[Notes]\n\(snapshot.notes)")
            for turn in snapshot.turns {
                print("\n[\(turn.id.uuidString.lowercased()) · \(turn.provider.rawValue) \(turn.timestamp)]\nUser: \(turn.userText)\nAssistant: \(turn.assistantText)")
            }
        case "notes":
            guard arguments.count == 2 else { throw AgentBridgeError.invalidInput("Usage: agentbridge memory notes SESSION-ID < notes.txt") }
            let notes = try readPromptFromStandardInput(maximumBytes: 64 * 1_024)
            try service.setSharedMemoryNotes(sessionID: sessionID, notes: notes)
            print("Updated the shared-memory notes for this isolated workspace.")
        case "clear":
            guard arguments.count == 3, arguments[2] == "--confirm" else {
                throw AgentBridgeError.invalidInput("Clearing cannot be undone; run agentbridge memory clear SESSION-ID --confirm explicitly.")
            }
            try service.clearSharedMemory(sessionID: sessionID)
            print("Cleared the shared memory for this isolated workspace.")
        case "relink-candidates":
            guard arguments.count == 2 else { throw AgentBridgeError.invalidInput("Usage: agentbridge memory relink-candidates SESSION-ID") }
            let candidates = try service.memoryRelinkCandidates(sessionID: sessionID)
            for candidate in candidates {
                print("\(candidate.source.key)  earlier path: \(candidate.source.repositoryPath)  turns: \(candidate.turnCount)  notes=\(candidate.hasNotes ? "yes" : "no")")
            }
            if candidates.isEmpty { print("No earlier memory can be linked.") }
            else { print("\nTo copy one of them: agentbridge memory relink SESSION-ID KEY --confirm (the original memory is not changed)") }
        case "relink":
            guard arguments.count == 4, arguments[3] == "--confirm" else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge memory relink SESSION-ID KEY --confirm; use relink-candidates first to see the KEY.")
            }
            let candidate = try service.relinkMemory(sessionID: sessionID, sourceKey: arguments[2])
            print("Copied \(candidate.turnCount) turn(s) from \(candidate.source.repositoryPath) into this workspace's memory; the original memory was not changed.")
        case "handoffs":
            guard arguments.count == 2 else { throw AgentBridgeError.invalidInput("Usage: agentbridge memory handoffs SESSION-ID") }
            let handoffs = try service.projectMemoryHandoffs(sessionID: sessionID)
            for handoff in handoffs {
                print("\(handoff.id.uuidString.lowercased())  \(handoff.sourceCommit) -> \(handoff.targetCommit)  \(handoff.turns.count) selected turns  notes=\(handoff.notes == nil ? "no" : "yes")")
            }
            if handoffs.isEmpty { print("This repository has no explicit memory handoffs yet.") }
        case "carry-forward":
            try memoryCarryForward(arguments, service: service)
        default:
            throw AgentBridgeError.invalidInput("Unknown memory subcommand.")
        }
    }

    static func memoryCarryForward(_ arguments: [String], service: BridgeService) throws {
        guard arguments.count >= 3,
              let sourceID = UUID(uuidString: arguments[1]),
              let targetID = UUID(uuidString: arguments[2]) else {
            throw AgentBridgeError.invalidInput("Usage: agentbridge memory carry-forward SOURCE-SESSION TARGET-SESSION [--turn TURN-ID ...] [--notes]")
        }
        var selectedTurnIDs = Set<UUID>()
        var includeNotes = false
        var index = 3
        while index < arguments.count {
            switch arguments[index] {
            case "--turn":
                index += 1
                guard index < arguments.count, let id = UUID(uuidString: arguments[index]) else {
                    throw AgentBridgeError.invalidInput("--turn needs a valid turn UUID.")
                }
                selectedTurnIDs.insert(id)
            case "--notes": includeNotes = true
            default: throw AgentBridgeError.invalidInput("Unknown memory carry-forward option \(arguments[index]).")
            }
            index += 1
        }
        let handoff = try service.carryForwardProjectMemory(
            sourceSessionID: sourceID,
            targetSessionID: targetID,
            selectedTurnIDs: selectedTurnIDs,
            includeNotes: includeNotes
        )
        print("Created explicit handoff \(handoff.id.uuidString.lowercased()): \(handoff.sourceCommit) -> \(handoff.targetCommit).")
        print("Only the selected App memory is copied; the next shared-memory prompt allowed at the target commit receives it as untrusted, size-bounded history.")
    }
}
