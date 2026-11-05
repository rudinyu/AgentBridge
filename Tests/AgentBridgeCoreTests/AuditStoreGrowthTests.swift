import XCTest
@testable import AgentBridgeCore

/// The session index and each audit file only ever grew and then failed at their
/// size limit: after about 21,400 saves no session could be saved at all.
final class AuditStoreGrowthTests: XCTestCase {
    private func makeStore() throws -> (URL, AuditStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuditGrowth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("data"), withIntermediateDirectories: true)
        return (root, try AuditStore(rootURL: root.appendingPathComponent("state"), workspaceRootURL: root.appendingPathComponent("data"), managedWorkspaceRoots: []))
    }

    private func makeSession(_ index: Int = 0, updatedAt: Date = Date()) -> SessionRecord {
        SessionRecord(
            updatedAt: updatedAt,
            provider: .codex,
            sourceRepositoryPath: "/Users/someone/projects/repository-\(index)",
            workspacePath: "/Users/someone/AgentWorkspace/workspaces/\(UUID().uuidString.lowercased())",
            snapshotCommit: String(repeating: "a", count: 40),
            sourceWasDirty: false
        )
    }

    private func indexSize(_ root: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("state/sessions.jsonl").path)[.size] as! NSNumber).intValue
    }

    // MARK: Session index

    func testSavingPastTheOldLimitKeepsWorkingAndTheIndexStaysSmall() throws {
        let (root, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        var sessions = (0..<3).map { makeSession($0) }
        // The old index failed on the 21,400th save of records this size.
        let saves = 25_000
        for save in 0..<saves {
            let index = save % sessions.count
            sessions[index].updatedAt = Date(timeIntervalSince1970: 1_700_000_000 + Double(save))
            try store.saveSession(sessions[index])
        }
        XCTAssertLessThan(try indexSize(root), 4 * 1_024 * 1_024, "The index must be compacted instead of growing to its limit.")

        let loaded = try store.loadSessions()
        XCTAssertEqual(loaded.count, 3)
        for session in sessions {
            let stored = try XCTUnwrap(store.session(id: session.id))
            XCTAssertEqual(stored.updatedAt.timeIntervalSince1970, session.updatedAt.timeIntervalSince1970, accuracy: 1, "The newest record must survive compaction.")
        }
        XCTAssertEqual(loaded.map(\.updatedAt), loaded.map(\.updatedAt).sorted(by: >), "Sessions are listed newest first.")
    }

    func testCompactionKeepsTheLaterRecordWhenTimestampsTie() throws {
        let (root, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let moment = Date(timeIntervalSince1970: 1_700_000_000)
        var first = makeSession(updatedAt: moment)
        first.workspacePath = "/first"
        var second = first
        second.workspacePath = "/second"
        try store.saveSession(first)
        try store.saveSession(second)

        try store.compactSessionIndex()
        XCTAssertEqual(try store.session(id: first.id)?.workspacePath, "/second", "The record appended later wins a tie, as before compaction.")
        XCTAssertEqual(try store.loadSessions().count, 1)
    }

    func testCompactionLeavesNoTemporaryFileAndKeepsTheFilePrivate() throws {
        let (root, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<50 { try store.saveSession(makeSession(index)) }
        try store.compactSessionIndex()

        let names = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("state").path)
        XCTAssertTrue(names.filter { $0.contains(".compact-") }.isEmpty, "A temporary file was left behind: \(names)")
        let mode = (try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("state/sessions.jsonl").path)[.posixPermissions] as! NSNumber).intValue
        XCTAssertEqual(mode & 0o777, 0o600)
        XCTAssertEqual(try store.loadSessions().count, 50)
    }

    func testLookupReusesTheDecodedIndexUntilAnotherProcessChangesIt() throws {
        let (root, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = makeSession()
        try store.saveSession(session)
        // Many history lines for one session, written without compaction.
        var history = Data()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var record = session
        for step in 0..<15_000 {
            record.updatedAt = Date(timeIntervalSince1970: 1_700_000_000 + Double(step))
            history.append(try encoder.encode(record)); history.append(0x0A)
        }
        let file = root.appendingPathComponent("state/sessions.jsonl")
        try history.write(to: file)
        XCTAssertLessThan(history.count, 10 * 1_024 * 1_024)

        let firstStarted = Date()
        XCTAssertNotNil(try store.session(id: session.id))
        let firstCall = Date().timeIntervalSince(firstStarted)
        let secondStarted = Date()
        for _ in 0..<200 { XCTAssertNotNil(try store.session(id: session.id)) }
        let eachAfter = Date().timeIntervalSince(secondStarted) / 200
        XCTAssertLessThan(eachAfter, firstCall / 10, "Lookups must reuse the decoded index, not parse the file again.")

        // Another process (here another store over the same files) saves a newer record.
        let other = try AuditStore(rootURL: root.appendingPathComponent("state"), workspaceRootURL: root.appendingPathComponent("data"), managedWorkspaceRoots: [])
        var newer = session
        newer.workspacePath = "/changed-elsewhere"
        newer.updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try other.saveSession(newer)
        XCTAssertEqual(try store.session(id: session.id)?.workspacePath, "/changed-elsewhere", "A change made by another process must be seen.")
    }

    // MARK: Audit files

    func testAFullEventFileTrimsOldOutputsInsteadOfFailingTheRun() throws {
        let (root, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID()
        let big = String(repeating: "x", count: 190_000)
        // 70 outputs of about 190 KB is far more than the 10 MiB limit of the file.
        for index in 0..<70 {
            try store.appendEvent(AuditEvent(sessionID: sessionID, kind: "run.started", message: "Started run \(index)."))
            try store.appendEvent(AuditEvent(sessionID: sessionID, kind: "run.output", message: "output \(index) " + big))
            try store.appendEvent(AuditEvent(sessionID: sessionID, kind: "run.completed", message: "Finished run \(index)."))
        }
        let events = try store.events(sessionID: sessionID)
        XCTAssertEqual(events.count, 210, "Every event is kept; the usage counters read their kinds and times.")
        XCTAssertEqual(events.filter { $0.kind == "run.started" }.count, 70)
        let outputs = events.filter { $0.kind == "run.output" }
        XCTAssertEqual(outputs.last?.message.hasPrefix("output 69 "), true)
        XCTAssertEqual(outputs.last?.message.count, "output 69 ".count + big.count, "The newest output must stay complete.")
        XCTAssertTrue(outputs.dropLast().contains { $0.message.count < 2_000 && $0.message.contains("trimmed") }, "Older outputs are shortened.")
        let size = (try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("state/events/\(sessionID.uuidString.lowercased()).jsonl").path)[.size] as! NSNumber).intValue
        XCTAssertLessThan(size, 10 * 1_024 * 1_024)
    }

    func testEventsKeepTheirContentWhenNothingNeedsTrimming() throws {
        let (root, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID()
        let output = AuditEvent(sessionID: sessionID, kind: "run.output", message: "A complete answer. " + String(repeating: "y", count: 5_000))
        try store.appendEvent(output)
        try store.appendEvent(AuditEvent(sessionID: sessionID, kind: "run.completed", message: "Finished."))
        XCTAssertEqual(try store.events(sessionID: sessionID).first?.message, output.message)
    }

    func testEventReadsSeeAppendsMadeAfterTheyWereCached() throws {
        let (root, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID()
        try store.appendEvent(AuditEvent(sessionID: sessionID, kind: "run.started", message: "one"))
        XCTAssertEqual(try store.events(sessionID: sessionID).count, 1)
        XCTAssertEqual(try store.events(sessionID: sessionID).count, 1)
        try store.appendEvent(AuditEvent(sessionID: sessionID, kind: "run.completed", message: "two"))
        XCTAssertEqual(try store.events(sessionID: sessionID).map(\.message), ["one", "two"])
    }

    func testAnEventFileFullOfSmallEventsStillFailsClearly() throws {
        let (root, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID()
        let filler = String(repeating: "z", count: 9_000)
        var failure: Error?
        for index in 0..<2_000 {
            do { try store.appendEvent(AuditEvent(sessionID: sessionID, kind: "run.progress", message: "\(index) " + filler)) } catch { failure = error; break }
        }
        let error = try XCTUnwrap(failure, "Nothing in this file can be trimmed, so it must eventually refuse.")
        XCTAssertTrue(error.localizedDescription.contains("size limit"), error.localizedDescription)
    }
}
