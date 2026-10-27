import Foundation
import XCTest
@testable import AgentBridgeCore

final class ExtensionPolicyAndParallelTaskBoardTests: XCTestCase {
    func testExtensionImportIsDisabledUntilExplicitProjectScopedGrantAndRevocation() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ExtensionPolicyStore(rootURL: root.appendingPathComponent("policy", isDirectory: true))
        let descriptor = try ExtensionDescriptor(
            id: "sample.mcp",
            kind: .mcp,
            name: "Sample MCP",
            version: "1.2.0",
            summary: "Metadata only",
            requestedPermissions: [.readSelectedFiles, .readTaskContext, .networkAccess]
        )

        let provenance = try store.importDescriptor(
            descriptor,
            source: .mcpRegistry,
            sourceReference: "https://registry.example.invalid/sample",
            importedBy: "local-user"
        )

        XCTAssertEqual(try store.listDescriptors(), [descriptor])
        let storedProvenance = try XCTUnwrap(store.provenance(forExtensionID: descriptor.id))
        XCTAssertEqual(storedProvenance.source, provenance.source)
        XCTAssertEqual(storedProvenance.sourceReference, provenance.sourceReference)
        XCTAssertEqual(storedProvenance.importedBy, provenance.importedBy)
        XCTAssertLessThan(abs(storedProvenance.importedAt.timeIntervalSince(provenance.importedAt)), 0.001)
        XCTAssertFalse(try store.isEnabled(extensionID: descriptor.id, forProject: "project-alpha"))
        XCTAssertFalse(try store.isEnabled(extensionID: descriptor.id, forProject: "project-beta"))

        let grant = try store.grant(
            extensionID: descriptor.id,
            projectID: "project-alpha",
            permissions: [.readSelectedFiles, .networkAccess],
            allowedRelativePaths: ["docs/design"],
            allowedHosts: ["api.example.com"],
            grantedBy: "local-user"
        )

        XCTAssertEqual(grant.permissions, [.networkAccess, .readSelectedFiles].sorted { $0.rawValue < $1.rawValue })
        XCTAssertEqual(grant.allowedRelativePaths, ["docs/design"])
        XCTAssertEqual(grant.allowedHosts, ["api.example.com"])
        XCTAssertTrue(try store.isEnabled(extensionID: descriptor.id, forProject: "project-alpha"))
        XCTAssertFalse(try store.isEnabled(extensionID: descriptor.id, forProject: "project-beta"))
        XCTAssertThrowsError(try store.grant(
            extensionID: descriptor.id,
            projectID: "project-beta",
            permissions: [.writeSelectedFiles],
            allowedRelativePaths: ["docs"],
            grantedBy: "local-user"
        ))

        XCTAssertTrue(try store.revoke(extensionID: descriptor.id, projectID: "project-alpha", revokedBy: "local-user"))
        XCTAssertFalse(try store.isEnabled(extensionID: descriptor.id, forProject: "project-alpha"))
        XCTAssertFalse(try store.revoke(extensionID: descriptor.id, projectID: "project-alpha", revokedBy: "local-user"))

        let reopened = try ExtensionPolicyStore(rootURL: root.appendingPathComponent("policy", isDirectory: true))
        XCTAssertEqual(try reopened.listDescriptors(), [descriptor])
        XCTAssertNil(try reopened.grant(forExtensionID: descriptor.id, projectID: "project-alpha"))
        XCTAssertEqual(try reopened.auditEvents(extensionID: descriptor.id).map(\.action), [.imported, .granted, .revoked])
    }

    func testTaskBoardKeepsTaskAndSessionIDsIndependentAndValidatesTransitions() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let boardRoot = root.appendingPathComponent("board", isDirectory: true)
        let board = try ParallelTaskBoard(rootURL: boardRoot)
        let sessionID = UUID()
        let taskAID = UUID()
        let taskBID = UUID()

        let taskA = try board.create(sessionID: sessionID, id: taskAID, progressSummary: "Waiting for review")
        let taskB = try board.create(sessionID: sessionID, id: taskBID)
        XCTAssertNotEqual(taskA.id, taskA.sessionID)
        XCTAssertNotEqual(taskB.id, taskB.sessionID)
        XCTAssertNotEqual(taskA.id, taskB.id)
        XCTAssertEqual(try board.list(sessionID: sessionID).count, 2)
        XCTAssertThrowsError(try board.transition(taskID: taskAID, to: .completed))

        _ = try board.setApproval(taskID: taskAID, to: .requested)
        _ = try board.setApproval(taskID: taskAID, to: .approved)
        _ = try board.transition(taskID: taskAID, to: .inProgress)
        _ = try board.transition(taskID: taskAID, to: .blocked)
        _ = try board.updateProgress(taskID: taskAID, summary: "Waiting on the dependency owner")
        _ = try board.transition(taskID: taskAID, to: .inProgress)
        _ = try board.addReference(taskID: taskAID, kind: .verification, value: "ci://run/123")
        _ = try board.addReference(taskID: taskAID, kind: .diff, value: "git:abc123")
        let completed = try board.transition(taskID: taskAID, to: .completed)

        XCTAssertEqual(completed.status, .completed)
        XCTAssertEqual(completed.approvalState, .approved)
        XCTAssertEqual(completed.progressSummary, "Waiting on the dependency owner")
        XCTAssertEqual(completed.references.map(\.kind), [.verification, .diff])
        XCTAssertGreaterThanOrEqual(completed.updatedAt, completed.createdAt)
        XCTAssertThrowsError(try board.transition(taskID: taskAID, to: .failed))
        XCTAssertThrowsError(try board.updateProgress(taskID: taskAID, summary: "late update"))

        let reopened = try ParallelTaskBoard(rootURL: boardRoot)
        let persisted = try XCTUnwrap(reopened.task(id: taskAID))
        XCTAssertEqual(persisted.status, completed.status)
        XCTAssertEqual(persisted.sessionID, completed.sessionID)
        XCTAssertEqual(persisted.approvalState, completed.approvalState)
        XCTAssertEqual(persisted.progressSummary, completed.progressSummary)
        XCTAssertEqual(persisted.references, completed.references)
        XCTAssertLessThan(abs(persisted.updatedAt.timeIntervalSince(completed.updatedAt)), 0.001)
        XCTAssertEqual(try reopened.list(sessionID: sessionID, status: .queued).map(\.id), [taskBID])
    }

    func testExtensionAndTaskInputsEnforceBoundsAndNarrowScopes() throws {
        XCTAssertThrowsError(try ExtensionDescriptor(
            id: "oversized",
            kind: .skill,
            name: "Too long",
            version: "1",
            summary: String(repeating: "x", count: 4_097)
        ))
        XCTAssertThrowsError(try ExtensionGrant(
            extensionID: "example",
            projectID: "project",
            permissions: [.readSelectedFiles],
            allowedRelativePaths: ["../outside"],
            grantedBy: "user"
        ))
        XCTAssertThrowsError(try ExtensionGrant(
            extensionID: "example",
            projectID: "project",
            permissions: [.networkAccess],
            allowedHosts: ["*.example.com"],
            grantedBy: "user"
        ))

        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let board = try ParallelTaskBoard(rootURL: root.appendingPathComponent("board", isDirectory: true))
        let taskID = UUID()
        _ = try board.create(sessionID: UUID(), id: taskID)
        XCTAssertThrowsError(try board.updateProgress(
            taskID: taskID,
            summary: String(repeating: "x", count: ParallelTaskBoard.maximumProgressSummaryBytes + 1)
        ))
        XCTAssertThrowsError(try board.addReference(
            taskID: taskID,
            kind: .diff,
            value: String(repeating: "x", count: ParallelTaskBoard.maximumReferenceBytes + 1)
        ))
    }

    func testMalformedAndSymlinkedCoordinationDocumentsFailClosed() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let policyRoot = root.appendingPathComponent("policy", isDirectory: true)
        try FileManager.default.createDirectory(at: policyRoot, withIntermediateDirectories: true)
        try Data("{ malformed".utf8).write(to: policyRoot.appendingPathComponent("extension-policy.json"))
        let policy = try ExtensionPolicyStore(rootURL: policyRoot)
        XCTAssertThrowsError(try policy.listDescriptors())

        let boardRoot = root.appendingPathComponent("board", isDirectory: true)
        try FileManager.default.createDirectory(at: boardRoot, withIntermediateDirectories: true)
        try Data("{ malformed".utf8).write(to: boardRoot.appendingPathComponent("parallel-task-board.json"))
        let board = try ParallelTaskBoard(rootURL: boardRoot)
        XCTAssertThrowsError(try board.list())

        let targetRoot = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: targetRoot, withIntermediateDirectories: true)
        let aliasRoot = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: aliasRoot, withDestinationURL: targetRoot)
        XCTAssertThrowsError(try ExtensionPolicyStore(rootURL: aliasRoot))
        XCTAssertThrowsError(try ParallelTaskBoard(rootURL: aliasRoot))

        let symlinkPolicyRoot = root.appendingPathComponent("symlink-policy", isDirectory: true)
        try FileManager.default.createDirectory(at: symlinkPolicyRoot, withIntermediateDirectories: true)
        let externalFile = root.appendingPathComponent("external.json")
        try Data("{}".utf8).write(to: externalFile)
        try FileManager.default.createSymbolicLink(
            at: symlinkPolicyRoot.appendingPathComponent("extension-policy.json"),
            withDestinationURL: externalFile
        )
        let symlinkPolicy = try ExtensionPolicyStore(rootURL: symlinkPolicyRoot)
        XCTAssertThrowsError(try symlinkPolicy.listDescriptors())
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentBridge-extension-taskboard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
