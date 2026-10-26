import Darwin
import Foundation
import XCTest
@testable import AgentBridgeCore

final class SharedMemoryStoreTests: XCTestCase {
    func testCodexTurnAndNotesAreAvailableToClaudeContextForSameSnapshot() throws {
        let (root, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try makeScope()

        try store.appendTurn(
            scope: scope,
            provider: .codex,
            userText: "Remember this project decision.",
            assistantText: "Use the existing file format."
        )
        try store.setNotes(scope: scope, notes: "Keep compatibility with old projects.")

        let currentPrompt = "Claude's current request: continue from here."
        let context = try store.context(scope: scope, currentPrompt: currentPrompt)

        XCTAssertTrue(context.prompt.contains("\"provider\":\"codex\""))
        XCTAssertTrue(context.prompt.contains("Remember this project decision."))
        XCTAssertTrue(context.prompt.contains("Use the existing file format."))
        XCTAssertTrue(context.prompt.contains("Keep compatibility with old projects."))
        XCTAssertTrue(context.prompt.contains("untrusted context"))
        XCTAssertTrue(context.prompt.hasSuffix("Current user request:\n\(currentPrompt)"))
        XCTAssertEqual(context.includedTurnCount, 1)
    }

    func testScopeSeparatesRepositoryPathsAndCommitsAndCanonicalizesSymlinks() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appendingPathComponent("repository", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: repository)

        let original = try SharedMemoryScope(repositoryPath: repository.path, snapshotCommit: String(repeating: "a", count: 40))
        let symlinked = try SharedMemoryScope(repositoryPath: alias.path, snapshotCommit: String(repeating: "a", count: 40))
        let laterCommit = try SharedMemoryScope(repositoryPath: repository.path, snapshotCommit: String(repeating: "b", count: 40))
        let otherRepository = try SharedMemoryScope(repositoryPath: root.appendingPathComponent("other").path, snapshotCommit: String(repeating: "a", count: 40))

        XCTAssertEqual(original, symlinked)
        XCTAssertNotEqual(original.key, laterCommit.key)
        XCTAssertNotEqual(original.key, otherRepository.key)
        XCTAssertThrowsError(try SharedMemoryScope(repositoryPath: "relative/path", snapshotCommit: String(repeating: "a", count: 40)))
        XCTAssertThrowsError(try SharedMemoryScope(repositoryPath: repository.path, snapshotCommit: "../unsafe"))
    }

    func testAppendIsIdempotentForSameTurnAndRejectsConflictingDuplicateID() throws {
        let (root, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try makeScope()
        let turnID = UUID()

        try store.appendTurn(scope: scope, id: turnID, provider: .codex, userText: "question", assistantText: "answer")
        let firstRevision = try store.snapshot(scope: scope).revision
        try store.appendTurn(scope: scope, id: turnID, provider: .codex, userText: "question", assistantText: "answer")
        XCTAssertEqual(try store.snapshot(scope: scope).revision, firstRevision)

        XCTAssertThrowsError(try store.appendTurn(scope: scope, id: turnID, provider: .claude, userText: "question", assistantText: "answer"))
        let snapshot = try store.snapshot(scope: scope)
        XCTAssertEqual(snapshot.turns.count, 1)
        XCTAssertEqual(snapshot.turns.first?.provider, .codex)
    }

    func testKnownAndGenericSecretsAreRedactedBeforeWriting() throws {
        let (root, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try makeScope()
        let knownSecret = "DoNotPersistThisCredential-987"

        try store.appendTurn(
            scope: scope,
            provider: .claude,
            userText: "The value is \(knownSecret)",
            assistantText: "api_key=generic-secret-value-1234567890",
            knownSecrets: [knownSecret]
        )

        let persisted = try String(contentsOf: documentURL(root: root, scope: scope), encoding: .utf8)
        XCTAssertFalse(persisted.contains(knownSecret))
        XCTAssertFalse(persisted.contains("generic-secret-value-1234567890"))
        XCTAssertTrue(persisted.contains("redacted"))
    }

    func testTurnCountRetentionKeepsLatestCompleteTurnsAndMarksTruncation() throws {
        let (root, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try makeScope()
        var ids: [UUID] = []

        for index in 0..<45 {
            let id = UUID()
            ids.append(id)
            try store.appendTurn(scope: scope, id: id, provider: index.isMultiple(of: 2) ? .codex : .claude, userText: "user-\(index)", assistantText: "assistant-\(index)")
        }

        let snapshot = try store.snapshot(scope: scope)
        XCTAssertEqual(snapshot.turns.count, SharedMemoryStore.maximumStoredTurns)
        XCTAssertEqual(snapshot.turns.first?.id, ids[5])
        XCTAssertEqual(snapshot.turns.last?.id, ids[44])
        XCTAssertTrue(snapshot.wasTruncated)
    }

    func testByteRetentionDropsOnlyWholeOldTurnsAndKeepsDocumentBounded() throws {
        let (root, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try makeScope()
        let userText = String(repeating: "u", count: 1_600)
        let assistantText = String(repeating: "a", count: 1_600)

        for _ in 0..<30 {
            try store.appendTurn(scope: scope, provider: .codex, userText: userText, assistantText: assistantText)
        }

        let snapshot = try store.snapshot(scope: scope)
        let fileData = try Data(contentsOf: documentURL(root: root, scope: scope))
        XCTAssertLessThanOrEqual(fileData.count, SharedMemoryStore.maximumStoredBytes)
        XCTAssertLessThan(snapshot.turns.count, 30)
        XCTAssertGreaterThan(snapshot.turns.count, 0)
        XCTAssertTrue(snapshot.wasTruncated)
        XCTAssertTrue(snapshot.turns.allSatisfy { $0.userText == userText && $0.assistantText == assistantText })
    }

    func testContextBudgetIncludesRecentCompleteTurnsAndUsesUnicodeSafeNotesPrefix() throws {
        let (root, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try makeScope()
        try store.setNotes(scope: scope, notes: String(repeating: "🧭", count: 3_000))
        try store.appendTurn(scope: scope, provider: .codex, userText: "older question", assistantText: "older answer")
        try store.appendTurn(scope: scope, provider: .claude, userText: "recent question", assistantText: "recent answer")

        let context = try store.context(scope: scope, currentPrompt: "leave this complete 🧭", maximumBytes: 1_000)

        XCTAssertTrue(context.wasTruncated)
        XCTAssertTrue(context.prompt.hasSuffix("Current user request:\nleave this complete 🧭"))
        XCTAssertEqual(context.includedTurnCount, 2)
        XCTAssertTrue(context.prompt.contains("recent question"))
        XCTAssertTrue(context.prompt.contains("older question"))
        XCTAssertFalse(context.prompt.contains("\u{FFFD}"))
    }

    func testContextOmitsOlderWholeTurnWhenBudgetCannotFitIt() throws {
        let (root, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try makeScope()
        try store.appendTurn(scope: scope, provider: .codex, userText: "old", assistantText: "old answer")
        try store.appendTurn(scope: scope, provider: .claude, userText: String(repeating: "recent", count: 100), assistantText: String(repeating: "reply", count: 100))

        let currentPrompt = String(repeating: "current", count: 100)
        let context = try store.context(scope: scope, currentPrompt: currentPrompt, maximumBytes: 300)

        XCTAssertTrue(context.wasTruncated)
        XCTAssertTrue(context.prompt.hasSuffix("Current user request:\n\(currentPrompt)"))
        XCTAssertEqual(context.includedTurnCount, 1)
        XCTAssertTrue(context.prompt.contains("…[truncated]…"))
        XCTAssertTrue(context.prompt.contains("recent"))
        XCTAssertFalse(context.prompt.contains("old answer"))
    }

    func testOversizedEmojiTurnAndNotesAreRedactedClippedAndRemainAvailable() throws {
        let (root, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try makeScope()
        let secret = "NeverPersistThisTailSecret-742"
        let userText = String(repeating: "🧭", count: 65_536) + secret
        let assistantText = String(repeating: "🪴", count: 262_144)
        let oversizedNotes = String(repeating: "📌", count: 65_536)

        try store.appendTurn(
            scope: scope,
            id: UUID(uuidString: "12345678-1234-1234-1234-123456789abc")!,
            provider: .claude,
            userText: userText,
            assistantText: assistantText,
            knownSecrets: [secret]
        )
        try store.setNotes(scope: scope, notes: oversizedNotes)

        let snapshot = try store.snapshot(scope: scope)
        let fileData = try Data(contentsOf: documentURL(root: root, scope: scope))
        let context = try store.context(scope: scope, currentPrompt: "continue", maximumBytes: 16_384)
        let (jsonEnvelope, contextEnvelopeBytes) = try contextEnvelope(from: context.prompt)
        let contextTurn = try XCTUnwrap((jsonEnvelope["turns"] as? [[String: Any]])?.first)
        let persistedText = try String(contentsOf: documentURL(root: root, scope: scope), encoding: .utf8)

        XCTAssertLessThanOrEqual(fileData.count, SharedMemoryStore.maximumStoredBytes)
        XCTAssertTrue(snapshot.wasTruncated)
        XCTAssertEqual(snapshot.turns.count, 1)
        XCTAssertTrue(snapshot.turns[0].userText.contains("…[truncated]…"))
        XCTAssertTrue(snapshot.turns[0].assistantText.contains("…[truncated]…"))
        XCTAssertTrue(snapshot.notes.contains("…[truncated]…"))
        XCTAssertFalse(persistedText.contains(secret))
        XCTAssertTrue(persistedText.contains("redacted"))

        XCTAssertLessThanOrEqual(contextEnvelopeBytes, 16_384)
        XCTAssertTrue(context.wasTruncated)
        XCTAssertEqual(context.includedTurnCount, 1)
        XCTAssertTrue((contextTurn["userText"] as? String)?.contains("…[truncated]…") == true)
        XCTAssertTrue((contextTurn["assistantText"] as? String)?.contains("…[truncated]…") == true)
        XCTAssertTrue(context.prompt.hasSuffix("Current user request:\ncontinue"))
    }

    func testClearWritesEmptyDocumentAndAdvancesRevision() throws {
        let (root, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try makeScope()
        try store.appendTurn(scope: scope, provider: .codex, userText: "question", assistantText: "answer")
        try store.setNotes(scope: scope, notes: "note")
        let revisionBeforeClear = try store.snapshot(scope: scope).revision

        try store.clear(scope: scope)
        let snapshot = try store.snapshot(scope: scope)

        XCTAssertGreaterThan(snapshot.revision, revisionBeforeClear)
        XCTAssertTrue(snapshot.turns.isEmpty)
        XCTAssertEqual(snapshot.notes, "")
        XCTAssertFalse(snapshot.wasTruncated)
        XCTAssertTrue(FileManager.default.fileExists(atPath: documentURL(root: root, scope: scope).path))
    }

    func testConcurrentAppendsAreSerializedAcrossCallers() throws {
        let (root, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try makeScope()
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".lock").path))
        let errorsLock = NSLock()
        var errors: [Error] = []

        DispatchQueue.concurrentPerform(iterations: 24) { index in
            do {
                try store.appendTurn(scope: scope, provider: index.isMultiple(of: 2) ? .codex : .claude, userText: "question-\(index)", assistantText: "answer-\(index)")
            } catch {
                errorsLock.lock()
                errors.append(error)
                errorsLock.unlock()
            }
        }

        XCTAssertTrue(errors.isEmpty, "Concurrent writes failed: \(errors)")
        let snapshot = try store.snapshot(scope: scope)
        XCTAssertEqual(snapshot.turns.count, 24)
        XCTAssertEqual(Set(snapshot.turns.map(\.userText)).count, 24)
    }

    func testCorruptAndInvalidUTF8DocumentsFailClosed() throws {
        let (root, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try makeScope()
        let destination = documentURL(root: root, scope: scope)
        try Data([0xFF, 0xFE, 0x00]).write(to: destination)

        XCTAssertThrowsError(try store.snapshot(scope: scope))
        XCTAssertThrowsError(try store.appendTurn(scope: scope, provider: .codex, userText: "new", assistantText: "new"))
        XCTAssertEqual(try Data(contentsOf: destination), Data([0xFF, 0xFE, 0x00]))
    }

    func testSymbolicLinkDocumentIsRejectedWithoutFollowingIt() throws {
        let (root, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try makeScope()
        let destination = documentURL(root: root, scope: scope)
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("{}".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: outside)

        XCTAssertThrowsError(try store.snapshot(scope: scope))
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "{}")
    }

    func testStorageDirectoryAndFilesHavePrivatePermissions() throws {
        let (root, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try makeScope()
        try store.appendTurn(scope: scope, provider: .codex, userText: "question", assistantText: "answer")

        let rootMode = try fileMode(at: root)
        let documentMode = try fileMode(at: documentURL(root: root, scope: scope))
        let lockMode = try fileMode(at: root.appendingPathComponent(".lock"))
        XCTAssertEqual(rootMode & 0o777, 0o700)
        XCTAssertEqual(documentMode & 0o777, 0o600)
        XCTAssertEqual(lockMode & 0o777, 0o600)
    }

    private func makeStore() throws -> (URL, SharedMemoryStore) {
        let root = try temporaryDirectory().appendingPathComponent("memory", isDirectory: true)
        return (root, try SharedMemoryStore(rootURL: root))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SharedMemoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeScope() throws -> SharedMemoryScope {
        try SharedMemoryScope(repositoryPath: "/tmp/agentbridge-shared-memory-tests", snapshotCommit: String(repeating: "c", count: 40))
    }

    private func documentURL(root: URL, scope: SharedMemoryScope) -> URL {
        root.appendingPathComponent("\(scope.key).json", isDirectory: false)
    }

    private func fileMode(at url: URL) throws -> UInt16 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let number = attributes[.posixPermissions] as? NSNumber else {
            throw NSError(domain: "SharedMemoryStoreTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not read file permissions."])
        }
        return number.uint16Value
    }

    private func contextEnvelope(from prompt: String) throws -> ([String: Any], Int) {
        let opening = try XCTUnwrap(prompt.range(of: "\n{"))
        let closing = try XCTUnwrap(prompt.range(of: "\n[/AgentBridge shared memory]"))
        let jsonStart = prompt.index(after: opening.lowerBound)
        let json = String(prompt[jsonStart..<closing.lowerBound])
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return (try XCTUnwrap(object as? [String: Any]), Data(json.utf8).count)
    }
}
