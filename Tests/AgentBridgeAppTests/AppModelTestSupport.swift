import Darwin
import AgentBridgeCore
import XCTest
@testable import AgentBridgeApp

extension XCTestCase {
    /// An `AppModel` over a fresh store under `build/test-fixtures`, removed when
    /// the test ends. The fixture parent is resolved with `realpath` so paths the
    /// store compares are canonical. `sessions` are saved before the first refresh.
    @MainActor
    func makeTestAppModel(sessions: [SessionRecord] = []) throws -> AppModel {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixtureParent = packageRoot.appendingPathComponent("build/test-fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureParent, withIntermediateDirectories: true)
        guard let resolvedPath = fixtureParent.path.withCString({ realpath($0, nil) }) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { free(resolvedPath) }
        let canonicalParent = URL(fileURLWithPath: String(cString: resolvedPath), isDirectory: true)
        let root = canonicalParent.appendingPathComponent("\(type(of: self))-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: root.appendingPathComponent("data"), withIntermediateDirectories: true)
        let store = try AuditStore(rootURL: root.appendingPathComponent("state"), workspaceRootURL: root.appendingPathComponent("data"), managedWorkspaceRoots: [])
        let service = try BridgeService(store: store)
        if !sessions.isEmpty { try store.saveSessions(sessions) }
        let model = AppModel(store: store, service: service)
        model.refresh()
        return model
    }

    /// Returns once every block already on the main queue has run: main-queue work
    /// runs in order, so the block queued here runs after all of it. Use this to
    /// show that a `DispatchQueue.main.async` hop has (or has not) done something,
    /// instead of waiting a fixed time. Main-actor `Task`s are queued the same way.
    @MainActor
    func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 5)
    }
}
