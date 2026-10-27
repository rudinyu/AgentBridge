import Foundation
import XCTest
@testable import AgentBridgeCore

final class WorkspaceRootConfigurationTests: XCTestCase {
    func testChangeRootRejectsGitRepositoryAndMissingNestedRootBeforeCreatingIt() async throws {
        let fileManager = FileManager.default
        let testRoot = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: testRoot) }

        let repository = testRoot.appendingPathComponent("repository", isDirectory: true)
        try fileManager.createDirectory(
            at: repository.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        let privateRoot = testRoot.appendingPathComponent("private", isDirectory: true)

        await assertWorkspaceRootRejected(repository, privateRootURL: privateRoot)

        let nestedRoot = repository
            .appendingPathComponent("new", isDirectory: true)
            .appendingPathComponent("workspace", isDirectory: true)
        await assertWorkspaceRootRejected(nestedRoot, privateRootURL: privateRoot)
        XCTAssertFalse(fileManager.fileExists(atPath: nestedRoot.path))
        XCTAssertFalse(fileManager.fileExists(atPath: nestedRoot.deletingLastPathComponent().path))
    }

    func testChangeRootRejectsLinkedWorktreeGitFile() async throws {
        let fileManager = FileManager.default
        let testRoot = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: testRoot) }

        let worktree = testRoot.appendingPathComponent("worktree", isDirectory: true)
        let linkedGitDirectory = testRoot
            .appendingPathComponent("repository.git", isDirectory: true)
            .appendingPathComponent("worktrees", isDirectory: true)
            .appendingPathComponent("linked", isDirectory: true)
        try fileManager.createDirectory(at: worktree, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: linkedGitDirectory, withIntermediateDirectories: true)
        try Data("gitdir: \(linkedGitDirectory.path)\n".utf8)
            .write(to: worktree.appendingPathComponent(".git"))

        let privateRoot = testRoot.appendingPathComponent("private", isDirectory: true)
        await assertWorkspaceRootRejected(worktree, privateRootURL: privateRoot)
    }

    func testChangeRootChecksCanonicalPathForMissingRootBeneathSymlinkedParent() async throws {
        let fileManager = FileManager.default
        let testRoot = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: testRoot) }

        let repository = testRoot.appendingPathComponent("repository", isDirectory: true)
        try fileManager.createDirectory(
            at: repository.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        let alias = testRoot.appendingPathComponent("repository-alias", isDirectory: true)
        try fileManager.createSymbolicLink(at: alias, withDestinationURL: repository)

        let requested = alias
            .appendingPathComponent("new", isDirectory: true)
            .appendingPathComponent("workspace", isDirectory: true)
        let privateRoot = testRoot.appendingPathComponent("private", isDirectory: true)
        await assertWorkspaceRootRejected(requested, privateRootURL: privateRoot)

        let canonicalRequested = repository
            .appendingPathComponent("new", isDirectory: true)
            .appendingPathComponent("workspace", isDirectory: true)
        XCTAssertFalse(fileManager.fileExists(atPath: canonicalRequested.path))
        XCTAssertFalse(fileManager.fileExists(atPath: canonicalRequested.deletingLastPathComponent().path))
    }

    func testChangeRootStillRejectsSelectedRootThatIsASymlink() async throws {
        let fileManager = FileManager.default
        let testRoot = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: testRoot) }

        let actualRoot = testRoot.appendingPathComponent("actual", isDirectory: true)
        try fileManager.createDirectory(at: actualRoot, withIntermediateDirectories: true)
        let selectedSymlink = testRoot.appendingPathComponent("selected", isDirectory: true)
        try fileManager.createSymbolicLink(at: selectedSymlink, withDestinationURL: actualRoot)

        let privateRoot = testRoot.appendingPathComponent("private", isDirectory: true)
        await assertWorkspaceRootRejected(selectedSymlink, privateRootURL: privateRoot)
        XCTAssertTrue(fileManager.fileExists(atPath: actualRoot.path))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentBridge-WorkspaceRoot-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func assertWorkspaceRootRejected(
        _ selectedRoot: URL,
        privateRootURL: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await WorkspaceRootCoordinator.changeRoot(
                to: selectedRoot,
                privateRootURL: privateRootURL
            )
            XCTFail("Expected the selected workspace data root to be rejected.", file: file, line: line)
        } catch let error as AgentBridgeError {
            guard case .invalidInput = error else {
                XCTFail("Expected invalidInput, got \(error).", file: file, line: line)
                return
            }
        } catch {
            XCTFail("Expected AgentBridgeError.invalidInput, got \(error).", file: file, line: line)
        }
    }
}
