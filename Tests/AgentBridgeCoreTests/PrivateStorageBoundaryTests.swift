import Foundation
import XCTest
@testable import AgentBridgeCore

final class PrivateStorageBoundaryTests: XCTestCase {
    func testExtensionPolicyMovesToPrivateRootWithOneTimeLegacyImport() throws {
        let fileManager = FileManager.default
        let testRoot = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: testRoot) }
        let privateRoot = testRoot.appendingPathComponent("private", isDirectory: true)
        let userRoot = testRoot.appendingPathComponent("workspace", isDirectory: true)
        try fileManager.createDirectory(at: userRoot, withIntermediateDirectories: true)

        let legacyPolicyRoot = userRoot.appendingPathComponent("extension-policy", isDirectory: true)
        let legacyPolicy = try ExtensionPolicyStore(rootURL: legacyPolicyRoot)
        let first = try descriptor(id: "legacy.first")
        try legacyPolicy.importDescriptor(first, source: .localMetadata, sourceReference: "/tmp/first.json", importedBy: "local-user")

        _ = try BridgeService(store: AuditStore(rootURL: privateRoot, workspaceRootURL: userRoot, managedWorkspaceRoots: []))

        let privatePolicyRoot = privateRoot.appendingPathComponent("extension-policy", isDirectory: true)
        XCTAssertEqual(try ExtensionPolicyStore(rootURL: privatePolicyRoot).listDescriptors(), [first])

        // A later legacy change must not overwrite the private document.
        let second = try descriptor(id: "legacy.second")
        try legacyPolicy.importDescriptor(second, source: .localMetadata, sourceReference: "/tmp/second.json", importedBy: "local-user")
        _ = try BridgeService(store: AuditStore(rootURL: privateRoot, workspaceRootURL: userRoot, managedWorkspaceRoots: []))

        XCTAssertEqual(try ExtensionPolicyStore(rootURL: privatePolicyRoot).listDescriptors(), [first])
        XCTAssertEqual(Set(try legacyPolicy.listDescriptors().map(\.id)), [first.id, second.id])
    }

    func testMalformedLegacyExtensionDocumentsAreSkipped() throws {
        let fileManager = FileManager.default
        let testRoot = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: testRoot) }
        let privateRoot = testRoot.appendingPathComponent("private", isDirectory: true)
        let userRoot = testRoot.appendingPathComponent("workspace", isDirectory: true)
        let legacyPolicyRoot = userRoot.appendingPathComponent("extension-policy", isDirectory: true)
        let legacyRuntimeRoot = userRoot.appendingPathComponent("extension-runtime", isDirectory: true)
        try fileManager.createDirectory(at: legacyPolicyRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: legacyRuntimeRoot, withIntermediateDirectories: true)
        try Data("{ malformed".utf8).write(to: legacyPolicyRoot.appendingPathComponent("extension-policy.json"))
        try Data("{ malformed".utf8).write(to: legacyRuntimeRoot.appendingPathComponent("active-extensions.json"))

        _ = try BridgeService(store: AuditStore(rootURL: privateRoot, workspaceRootURL: userRoot, managedWorkspaceRoots: []))

        XCTAssertFalse(fileManager.fileExists(atPath: privateRoot.appendingPathComponent("extension-policy/extension-policy.json").path))
        XCTAssertFalse(fileManager.fileExists(atPath: privateRoot.appendingPathComponent("extension-runtime/active-extensions.json").path))
        XCTAssertEqual(try ExtensionPolicyStore(rootURL: privateRoot.appendingPathComponent("extension-policy", isDirectory: true)).listDescriptors(), [])
        XCTAssertEqual(
            try Data(contentsOf: legacyRuntimeRoot.appendingPathComponent("active-extensions.json")),
            Data("{ malformed".utf8)
        )
    }

    func testChangeRootMergesTaskBoardWithoutRemovingSource() async throws {
        let fileManager = FileManager.default
        let testRoot = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: testRoot) }
        let privateRoot = testRoot.appendingPathComponent("private", isDirectory: true)
        let oldRoot = testRoot.appendingPathComponent("old-workspace", isDirectory: true)
        let newRoot = testRoot.appendingPathComponent("new-workspace", isDirectory: true)
        try fileManager.createDirectory(at: oldRoot, withIntermediateDirectories: true)
        try WorkspaceRootConfigurationStore.save(selectedRootURL: oldRoot, priorRootURLs: [], privateRootURL: privateRoot)

        let oldBoard = try ParallelTaskBoard(rootURL: oldRoot.appendingPathComponent("task-board", isDirectory: true))
        try oldBoard.create(sessionID: UUID(), progressSummary: "Survives a root change.")
        let stored = try oldBoard.list()

        _ = try await WorkspaceRootCoordinator.changeRoot(to: newRoot, privateRootURL: privateRoot)

        let newBoard = try ParallelTaskBoard(rootURL: newRoot.appendingPathComponent("task-board", isDirectory: true))
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(try newBoard.list(), stored)
        XCTAssertEqual(try oldBoard.list(), stored)
    }

    func testChangeRootStopsOnConflictingTaskBoardRecord() async throws {
        let fileManager = FileManager.default
        let testRoot = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: testRoot) }
        let privateRoot = testRoot.appendingPathComponent("private", isDirectory: true)
        let oldRoot = testRoot.appendingPathComponent("old-workspace", isDirectory: true)
        let newRoot = testRoot.appendingPathComponent("new-workspace", isDirectory: true)
        try fileManager.createDirectory(at: oldRoot, withIntermediateDirectories: true)
        try WorkspaceRootConfigurationStore.save(selectedRootURL: oldRoot, priorRootURLs: [], privateRootURL: privateRoot)

        let taskID = UUID()
        let oldBoard = try ParallelTaskBoard(rootURL: oldRoot.appendingPathComponent("task-board", isDirectory: true))
        try oldBoard.create(sessionID: UUID(), id: taskID, progressSummary: "Source copy.")
        let original = try oldBoard.list()
        let newBoard = try ParallelTaskBoard(rootURL: newRoot.appendingPathComponent("task-board", isDirectory: true))
        try newBoard.create(sessionID: UUID(), id: taskID, progressSummary: "Different destination copy.")
        let conflicting = try newBoard.list()

        do {
            _ = try await WorkspaceRootCoordinator.changeRoot(to: newRoot, privateRootURL: privateRoot)
            XCTFail("A differing task-board record must stop the root change.")
        } catch let error as AgentBridgeError {
            guard case .persistence = error else { return XCTFail("Unexpected migration error: \(error)") }
        }
        XCTAssertEqual(try WorkspaceRootConfigurationStore.load(privateRootURL: privateRoot)?.selectedRootURL, oldRoot)
        XCTAssertEqual(try newBoard.list(), conflicting)
        XCTAssertEqual(try oldBoard.list(), original)
    }

    func testChangeRootRejectsRootsInsideDiscussionAndTaskBoardStorage() async throws {
        let fileManager = FileManager.default
        let testRoot = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: testRoot) }
        let privateRoot = testRoot.appendingPathComponent("private", isDirectory: true)
        let oldRoot = testRoot.appendingPathComponent("old-workspace", isDirectory: true)
        try fileManager.createDirectory(at: oldRoot, withIntermediateDirectories: true)
        try WorkspaceRootConfigurationStore.save(selectedRootURL: oldRoot, priorRootURLs: [], privateRootURL: privateRoot)

        for name in ["discussions", "task-board", "extension-policy", "extension-runtime"] {
            let nested = oldRoot.appendingPathComponent(name, isDirectory: true).appendingPathComponent("nested", isDirectory: true)
            try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
            do {
                _ = try await WorkspaceRootCoordinator.changeRoot(to: nested, privateRootURL: privateRoot)
                XCTFail("A root inside \(name) must be rejected.")
            } catch let error as AgentBridgeError {
                guard case .invalidInput = error else { return XCTFail("Unexpected error for \(name): \(error)") }
            }
        }
        XCTAssertEqual(try WorkspaceRootConfigurationStore.load(privateRootURL: privateRoot)?.selectedRootURL, oldRoot)
    }

    private func descriptor(id: String) throws -> ExtensionDescriptor {
        try ExtensionDescriptor(
            id: id,
            kind: .mcp,
            name: "Legacy MCP",
            version: "1.0.0",
            summary: "Metadata only",
            requestedPermissions: [.readTaskContext]
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentBridge-PrivateStorage-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
