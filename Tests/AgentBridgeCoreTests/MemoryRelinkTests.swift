import XCTest
@testable import AgentBridgeCore

final class MemoryRelinkTests: XCTestCase {
    func testKnownScopesListsStoredDocumentsAndSkipsStrangers() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SharedMemoryStore(rootURL: root.appendingPathComponent("memory", isDirectory: true))
        let scope = try SharedMemoryScope(repositoryPath: "/tmp/ab-known-scope", snapshotCommit: String(repeating: "a", count: 40))
        try store.appendTurn(scope: scope, provider: .codex, userText: "hi", assistantText: "hello")
        try Data("{}".utf8).write(to: root.appendingPathComponent("memory/\(String(repeating: "0", count: 64)).json"))
        try Data("x".utf8).write(to: root.appendingPathComponent("memory/notes.json"))

        XCTAssertEqual(try store.knownScopes(), [scope])
    }

    func testMovedRepositoryMemoryIsOfferedAndCopiedOnlyOnRequest() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let gone = try goneScope(commit: fixture.session.snapshotCommit)
        try seed(fixture.service, scope: gone, text: "before the move", notes: "keep me")

        XCTAssertEqual(try fixture.service.sharedMemory(sessionID: fixture.session.id).turns.count, 0)
        let candidates = try fixture.service.memoryRelinkCandidates(sessionID: fixture.session.id)
        XCTAssertEqual(candidates.map(\.source), [gone])
        XCTAssertEqual(candidates.first?.turnCount, 1)
        XCTAssertEqual(candidates.first?.hasNotes, true)

        try fixture.service.relinkMemory(sessionID: fixture.session.id, sourceKey: gone.key)
        let copied = try fixture.service.sharedMemory(sessionID: fixture.session.id)
        XCTAssertEqual(copied.turns.map(\.userText), ["before the move"])
        XCTAssertEqual(copied.notes, "keep me")

        let original = try fixture.service.sharedMemoryStore.snapshot(scope: gone)
        XCTAssertEqual(original.turns.count, 1, "The earlier memory must be left unchanged.")
        let events = try fixture.service.events(sessionID: fixture.session.id)
        XCTAssertTrue(events.contains { $0.kind == "memory.relinked" })

        XCTAssertTrue(try fixture.service.memoryRelinkCandidates(sessionID: fixture.session.id).isEmpty)
        XCTAssertThrowsError(try fixture.service.relinkMemory(sessionID: fixture.session.id, sourceKey: gone.key))
    }

    func testMemoryWhoseRepositoryStillExistsOrWhoseCommitDiffersIsNotOffered() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let otherClone = fixture.root.appendingPathComponent("other-clone", isDirectory: true)
        try FileManager.default.createDirectory(at: otherClone, withIntermediateDirectories: true)
        let stillThere = try SharedMemoryScope(repositoryPath: otherClone.path, snapshotCommit: fixture.session.snapshotCommit)
        let otherCommit = try SharedMemoryScope(
            repositoryPath: "/tmp/ab-gone-\(UUID().uuidString.lowercased())",
            snapshotCommit: String(repeating: "b", count: 40)
        )
        try seed(fixture.service, scope: stillThere, text: "second clone", notes: "")
        try seed(fixture.service, scope: otherCommit, text: "other commit", notes: "")

        XCTAssertTrue(try fixture.service.memoryRelinkCandidates(sessionID: fixture.session.id).isEmpty)
    }

    func testNothingIsOfferedOnceTheSessionAlreadyHasMemory() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try seed(fixture.service, scope: try goneScope(commit: fixture.session.snapshotCommit), text: "old", notes: "")
        try fixture.service.setSharedMemoryNotes(sessionID: fixture.session.id, notes: "already here")

        XCTAssertTrue(try fixture.service.memoryRelinkCandidates(sessionID: fixture.session.id).isEmpty)
    }

    // MARK: Helpers

    private struct Fixture {
        let root: URL
        let service: BridgeService
        let session: SessionRecord
    }

    private func makeFixture() async throws -> Fixture {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FixtureGit.run(["init", "-q", source.path])
        try FixtureGit.run(["-C", source.path, "config", "user.name", "AgentBridge Test"])
        try FixtureGit.run(["-C", source.path, "config", "user.email", "agentbridge@example.invalid"])
        try Data("committed\n".utf8).write(to: source.appendingPathComponent("tracked.txt"))
        try FixtureGit.run(["-C", source.path, "add", "tracked.txt"])
        try FixtureGit.run(["-C", source.path, "commit", "-q", "-m", "snapshot"])
        let store = try AuditStore(rootURL: root.appendingPathComponent("state", isDirectory: true))
        let service = try BridgeService(store: store, baseEnvironment: ["HOME": root.path, "USER": "fixture"])
        let session = try await service.createSession(sourcePath: source.path, provider: .codex)
        return Fixture(root: root, service: service, session: session)
    }

    private func goneScope(commit: String) throws -> SharedMemoryScope {
        try SharedMemoryScope(repositoryPath: "/tmp/ab-gone-\(UUID().uuidString.lowercased())", snapshotCommit: commit)
    }

    private func seed(_ service: BridgeService, scope: SharedMemoryScope, text: String, notes: String) throws {
        try service.sharedMemoryStore.appendTurn(scope: scope, provider: .codex, userText: text, assistantText: "answer")
        if !notes.isEmpty { try service.sharedMemoryStore.setNotes(scope: scope, notes: notes) }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MemoryRelinkTests-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
