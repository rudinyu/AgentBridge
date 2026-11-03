import Darwin
import Foundation
import XCTest
@testable import AgentBridgeCore

final class ProjectMemoryStoreTests: XCTestCase {
    func testCanonicalRepositoryIdentityIsCommitIndependentAndIsolated() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appendingPathComponent("repository", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("repository-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: repository)
        let otherRepository = root.appendingPathComponent("other-repository", isDirectory: true)
        try FileManager.default.createDirectory(at: otherRepository, withIntermediateDirectories: true)

        let canonical = try ProjectMemoryRepositoryScope(repositoryPath: repository.path)
        let throughAlias = try ProjectMemoryRepositoryScope(repositoryPath: alias.path)
        XCTAssertEqual(canonical, throughAlias)

        let (_, store) = try makeStore(under: root)
        let first = try makeSnapshot(repositoryPath: repository.path, commit: commit("a"), turns: [
            makeTurn(id: UUID(), text: "first source")
        ])
        let second = try makeSnapshot(repositoryPath: repository.path, commit: commit("b"), turns: [
            makeTurn(id: UUID(), text: "second source")
        ])
        try store.carryForward(
            source: first,
            targetCommit: commit("c"),
            selectedTurnIDs: Set(first.turns.map(\.id)),
            includeNotes: false,
            provider: .codex
        )
        try store.carryForward(
            source: second,
            targetCommit: commit("d"),
            selectedTurnIDs: Set(second.turns.map(\.id)),
            includeNotes: false,
            provider: .claude
        )

        XCTAssertEqual(try store.list(repositoryPath: alias.path).count, 2)
        XCTAssertTrue(try store.list(repositoryPath: otherRepository.path).isEmpty)
    }

    func testCarryForwardCopiesOnlySelectedTurnsAndRetainsProvenance() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        let (_, store) = try makeStore(under: root)
        let turnA = makeTurn(id: UUID(), text: "unselected question")
        let turnB = makeTurn(id: UUID(), text: "selected question", provider: .claude)
        let turnC = makeTurn(id: UUID(), text: "also unselected")
        let source = try makeSnapshot(
            repositoryPath: repository.path,
            commit: commit("a"),
            turns: [turnA, turnB, turnC],
            notes: "not copied unless selected"
        )
        let accountID = UUID()
        let before = Date()

        let handoff = try store.carryForward(
            source: source,
            targetCommit: commit("b").uppercased(),
            selectedTurnIDs: [turnB.id],
            includeNotes: false,
            provider: .codex,
            accountProfileID: accountID
        )

        XCTAssertEqual(handoff.sourceCommit, commit("a"))
        XCTAssertEqual(handoff.targetCommit, commit("b"))
        XCTAssertEqual(handoff.provider, .codex)
        XCTAssertEqual(handoff.accountProfileID, accountID)
        XCTAssertGreaterThanOrEqual(handoff.createdAt, before)
        XCTAssertEqual(handoff.turns.map(\.id), [turnB.id])
        XCTAssertEqual(handoff.turns.first?.provider, .claude)
        XCTAssertEqual(handoff.turns.first?.userText, "selected question")
        XCTAssertNil(handoff.notes)

        let loaded = try XCTUnwrap(store.list(repositoryPath: repository.path).first)
        XCTAssertEqual(loaded.id, handoff.id)
        XCTAssertEqual(loaded.turns.map(\.id), [turnB.id])
        XCTAssertNil(loaded.notes)
    }

    func testSelectedNotesCanBeCopiedWithoutTurnsAndSearchIncludesProvenance() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        let (_, store) = try makeStore(under: root)
        let accountID = UUID()
        let source = try makeSnapshot(
            repositoryPath: repository.path,
            commit: commit("a"),
            turns: [makeTurn(id: UUID(), text: "not selected")],
            notes: "Keep the migration checklist."
        )

        let handoff = try store.carryForward(
            source: source,
            targetCommit: commit("b"),
            selectedTurnIDs: [],
            includeNotes: true,
            provider: .claude,
            accountProfileID: accountID
        )

        XCTAssertTrue(handoff.turns.isEmpty)
        XCTAssertEqual(handoff.notes, "Keep the migration checklist.")
        XCTAssertEqual(try store.search(repositoryPath: repository.path, query: "migration").map(\.id), [handoff.id])
        XCTAssertEqual(try store.search(repositoryPath: repository.path, query: commit("b")).map(\.id), [handoff.id])
        XCTAssertEqual(try store.search(repositoryPath: repository.path, query: accountID.uuidString).map(\.id), [handoff.id])
        XCTAssertThrowsError(try store.search(repositoryPath: repository.path, query: "  "))
    }

    func testOversizedHandoffIsRefusedWithoutDroppingOrShorteningHistory() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        let (storageRoot, store) = try makeStore(under: root)
        let knownSecret = "DoNotPersistThis-credential-987654"
        let oversizedTurn = SharedMemoryTurn(
            id: UUID(),
            provider: .codex,
            userText: String(repeating: "🧭", count: 10_000) + " \(knownSecret)",
            assistantText: "api_key=generic-secret-value-1234567890"
        )
        let source = try makeSnapshot(
            repositoryPath: repository.path,
            commit: commit("a"),
            turns: [oversizedTurn],
            notes: String(repeating: "🧭", count: 10_000) + " \(knownSecret)"
        )

        XCTAssertThrowsError(try store.carryForward(
            source: source,
            targetCommit: commit("b"),
            selectedTurnIDs: [oversizedTurn.id],
            includeNotes: true,
            provider: .codex,
            knownSecrets: [knownSecret]
        ))
        let oversizedNotes = try makeSnapshot(
            repositoryPath: repository.path,
            commit: commit("a"),
            turns: [],
            notes: String(repeating: "🧭", count: 10_000) + " \(knownSecret)"
        )
        XCTAssertThrowsError(try store.carryForward(
            source: oversizedNotes,
            targetCommit: commit("b"),
            selectedTurnIDs: [],
            includeNotes: true,
            provider: .codex,
            knownSecrets: [knownSecret]
        ))
        XCTAssertTrue(try store.list(repositoryPath: repository.path).isEmpty)

        let smallTurn = SharedMemoryTurn(
            id: UUID(),
            provider: .codex,
            userText: "selected \(knownSecret)",
            assistantText: "api_key=generic-secret-value-1234567890"
        )
        let smallSource = try makeSnapshot(
            repositoryPath: repository.path,
            commit: commit("a"),
            turns: [smallTurn],
            notes: "Keep the selected format."
        )
        let handoff = try store.carryForward(
            source: smallSource,
            targetCommit: commit("b"),
            selectedTurnIDs: [smallTurn.id],
            includeNotes: true,
            provider: .codex,
            knownSecrets: [knownSecret]
        )
        let data = try Data(contentsOf: storageRoot.appendingPathComponent("handoffs.json"))
        let persisted = try String(contentsOf: storageRoot.appendingPathComponent("handoffs.json"), encoding: .utf8)

        XCTAssertFalse(handoff.wasTruncated)
        XCTAssertFalse(handoff.turns[0].wasTruncated)
        XCTAssertTrue(handoff.turns[0].userText.contains("redacted"))
        XCTAssertTrue(handoff.turns[0].assistantText.contains("redacted"))
        XCTAssertLessThanOrEqual(try XCTUnwrap(handoff.notes).utf8.count, 12 * 1_024)
        XCTAssertFalse(persisted.contains(knownSecret))
        XCTAssertFalse(persisted.contains("generic-secret-value-1234567890"))
        XCTAssertTrue(persisted.contains("redacted"))
        XCTAssertLessThanOrEqual(data.count, ProjectMemoryStore.maximumStoredBytes)
    }

    func testPrivateDirectoryLockAndDocumentPermissions() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        let (storageRoot, store) = try makeStore(under: root)
        let source = try makeSnapshot(
            repositoryPath: repository.path,
            commit: commit("a"),
            turns: [makeTurn(id: UUID(), text: "private")]
        )
        try store.carryForward(
            source: source,
            targetCommit: commit("b"),
            selectedTurnIDs: Set(source.turns.map(\.id)),
            includeNotes: false,
            provider: .codex
        )

        XCTAssertEqual(try fileMode(at: storageRoot), 0o700)
        XCTAssertEqual(try fileMode(at: storageRoot.appendingPathComponent(".lock")), 0o600)
        XCTAssertEqual(try fileMode(at: storageRoot.appendingPathComponent("handoffs.json")), 0o600)
    }

    func testSeparateStoreInstancesSerializeWritesThroughTheFileLock() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        let (storageRoot, firstStore) = try makeStore(under: root)
        let secondStore = try ProjectMemoryStore(rootURL: storageRoot)
        let turn = makeTurn(id: UUID(), text: "shared")
        let source = try makeSnapshot(repositoryPath: repository.path, commit: commit("a"), turns: [turn])
        let stores = [firstStore, secondStore]
        let errorsLock = NSLock()
        var errors: [Error] = []

        DispatchQueue.concurrentPerform(iterations: 12) { index in
            do {
                try stores[index.isMultiple(of: 2) ? 0 : 1].carryForward(
                    source: source,
                    targetCommit: commit("b"),
                    selectedTurnIDs: [turn.id],
                    includeNotes: false,
                    provider: .codex
                )
            } catch {
                errorsLock.lock()
                errors.append(error)
                errorsLock.unlock()
            }
        }

        XCTAssertTrue(errors.isEmpty, "Concurrent writes failed: \(errors)")
        XCTAssertEqual(try firstStore.list(repositoryPath: repository.path).count, 12)
    }

    func testCorruptDocumentFailsClosedAndRemainsUnchanged() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (storageRoot, store) = try makeStore(under: root)
        let destination = storageRoot.appendingPathComponent("handoffs.json")
        let corrupt = Data([0xFF, 0xFE, 0x00])
        try corrupt.write(to: destination)

        XCTAssertThrowsError(try store.list(repositoryPath: "/tmp/project-memory-corrupt"))
        XCTAssertEqual(try Data(contentsOf: destination), corrupt)
    }

    func testSymbolicLinkDocumentAndStorageRootFailClosed() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (storageRoot, store) = try makeStore(under: root)
        let outside = root.appendingPathComponent("outside.json")
        let destination = storageRoot.appendingPathComponent("handoffs.json")
        try Data("{}".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: outside)

        XCTAssertThrowsError(try store.list(repositoryPath: "/tmp/project-memory-symlink"))
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "{}")

        let realDirectory = root.appendingPathComponent("real-storage", isDirectory: true)
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
        let rootAlias = root.appendingPathComponent("storage-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: rootAlias, withDestinationURL: realDirectory)
        XCTAssertThrowsError(try ProjectMemoryStore(rootURL: rootAlias))
    }

    func testSelectedTurnMustBelongToTheProvidedSourceSnapshot() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        let (_, store) = try makeStore(under: root)
        let source = try makeSnapshot(repositoryPath: repository.path, commit: commit("a"), turns: [])

        XCTAssertThrowsError(try store.carryForward(
            source: source,
            targetCommit: commit("b"),
            selectedTurnIDs: [UUID()],
            includeNotes: false,
            provider: .codex
        ))
        XCTAssertTrue(try store.list(repositoryPath: repository.path).isEmpty)
    }

    private func makeStore(under root: URL) throws -> (URL, ProjectMemoryStore) {
        let storageRoot = root.appendingPathComponent("project-memory", isDirectory: true)
        return (storageRoot, try ProjectMemoryStore(rootURL: storageRoot))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectMemoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeSnapshot(
        repositoryPath: String,
        commit: String,
        turns: [SharedMemoryTurn],
        notes: String = ""
    ) throws -> SharedMemorySnapshot {
        SharedMemorySnapshot(
            scope: try SharedMemoryScope(repositoryPath: repositoryPath, snapshotCommit: commit),
            turns: turns,
            notes: notes,
            revision: 1,
            wasTruncated: false
        )
    }

    private func makeTurn(id: UUID, text: String, provider: AgentProvider = .codex) -> SharedMemoryTurn {
        SharedMemoryTurn(
            id: id,
            provider: provider,
            userText: text,
            assistantText: "answer to \(text)",
            timestamp: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    private func commit(_ character: Character) -> String {
        String(repeating: String(character), count: 40)
    }

    private func fileMode(at url: URL) throws -> UInt16 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let number = attributes[.posixPermissions] as? NSNumber else {
            throw NSError(domain: "ProjectMemoryStoreTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not read file permissions."])
        }
        return number.uint16Value
    }
}
