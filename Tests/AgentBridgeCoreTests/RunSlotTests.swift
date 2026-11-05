import XCTest
@testable import AgentBridgeCore

final class RunSlotTests: XCTestCase {
    private func makeStore() throws -> (URL, AuditStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RunSlotTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("data"), withIntermediateDirectories: true)
        return (root, try AuditStore(rootURL: root.appendingPathComponent("state"), workspaceRootURL: root.appendingPathComponent("data"), managedWorkspaceRoots: []))
    }

    func testOnlyTheMaximumNumberOfRunsCanHoldALeaseAtOnce() throws {
        let (root, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        var held: [SessionRunLease] = []
        for _ in 0..<AuditStore.maximumConcurrentRuns { held.append(try store.acquireRunLease(for: UUID())) }

        let extra = UUID()
        XCTAssertThrowsError(try store.acquireRunLease(for: extra)) { error in
            XCTAssertTrue(error.localizedDescription.contains("tasks can run at once"), error.localizedDescription)
        }

        held.removeFirst()
        XCTAssertNoThrow(try store.acquireRunLease(for: extra), "A finished run must free its slot.")
    }

    func testARefusedRunDoesNotKeepItsSessionLocked() throws {
        let (root, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        var held: [SessionRunLease] = []
        for _ in 0..<AuditStore.maximumConcurrentRuns { held.append(try store.acquireRunLease(for: UUID())) }
        let refused = UUID()
        XCTAssertThrowsError(try store.acquireRunLease(for: refused))

        held.removeAll()
        XCTAssertNoThrow(try store.acquireRunLease(for: refused), "The refused session must not stay locked.")
    }

    func testTheSameSessionCannotRunTwiceAndTheSlotCountIsSharedAcrossStoreInstances() throws {
        let (root, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = UUID()
        let first = try store.acquireRunLease(for: session)
        XCTAssertThrowsError(try store.acquireRunLease(for: session)) { error in
            XCTAssertTrue(error.localizedDescription.contains("already running"), error.localizedDescription)
        }

        // Another process (here, another store over the same root) sees the same slots.
        let other = try AuditStore(rootURL: root.appendingPathComponent("state"), workspaceRootURL: root.appendingPathComponent("data"), managedWorkspaceRoots: [])
        var held: [SessionRunLease] = [first]
        for _ in 1..<AuditStore.maximumConcurrentRuns { held.append(try other.acquireRunLease(for: UUID())) }
        XCTAssertThrowsError(try store.acquireRunLease(for: UUID()))
        _ = held
    }
}
