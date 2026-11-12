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

    /// Runs the main run loop until a `DispatchQueue.main.async` block and a
    /// `Task { @MainActor }` queued here have both run, for `rounds` rounds.
    ///
    /// Guaranteed: the main queue is serial and FIFO, so every block already on
    /// it has run, and in a later round so has any block those blocks queued.
    /// Not guaranteed: main-actor `Task`s already queued have run. Their order
    /// relative to main-queue blocks and to this hop is up to the executor and
    /// their priority; the hop and the extra round only make it likely. So use
    /// this for deferred main-queue work, and to give a stray main-actor hop a
    /// chance to show itself; wait on the condition itself for anything a
    /// main-actor `Task` must have done.
    @MainActor
    func drainMainQueue(rounds: Int = 2) {
        for round in 1...max(1, rounds) {
            let queueBlockRan = expectation(description: "main-queue block \(round) ran")
            let mainActorTaskRan = expectation(description: "main-actor task \(round) ran")
            DispatchQueue.main.async { queueBlockRan.fulfill() }
            Task { @MainActor in mainActorTaskRan.fulfill() }
            wait(for: [queueBlockRan, mainActorTaskRan], timeout: 5)
        }
    }

    /// Git for the fixture source repository only: no inherited Git variables, no
    /// system or global config, templates or hooks, and a fixed identity. The core
    /// tests' `FixtureGit` is in a test target this one cannot import.
    func runFixtureGit(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "core.hooksPath=/dev/null"] + arguments
        process.environment = [
            "HOME": NSTemporaryDirectory(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_TEMPLATE_DIR": "",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_AUTHOR_NAME": "AgentBridge Fixture",
            "GIT_AUTHOR_EMAIL": "agentbridge-fixture@example.invalid",
            "GIT_COMMITTER_NAME": "AgentBridge Fixture",
            "GIT_COMMITTER_EMAIL": "agentbridge-fixture@example.invalid"
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "git", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")): \(text)"])
        }
    }
}
