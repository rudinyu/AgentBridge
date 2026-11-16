import Darwin
import Foundation
import XCTest
@testable import AgentBridgeCore

final class ProjectHandoffMarkdownStoreTests: XCTestCase {
    private static let unavailableRootError = AgentBridgeError.persistence(
        "The configured workspace data root is unavailable or contains a symbolic link."
    )

    func testDataRootUnderTmpSymlinkOpensAndRoundTrips() throws {
        // `/tmp` is a symbolic link to `private/tmp`; the workspace root keeps the
        // `/tmp/...` form, so the store must open it through that ancestor link.
        let dataRoot = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("AgentBridgeHandoffTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        XCTAssertTrue(dataRoot.path.hasPrefix("/tmp/"))

        let store = try ProjectHandoffMarkdownStore(dataRootURL: dataRoot)
        try assertRoundTrip(store)
    }

    func testDataRootBehindUserAncestorSymlinkIsRefused() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let realParent = root.appendingPathComponent("real-parent", isDirectory: true)
        try FileManager.default.createDirectory(
            at: realParent.appendingPathComponent("data", isDirectory: true),
            withIntermediateDirectories: true
        )
        let aliasParent = root.appendingPathComponent("alias-parent", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: aliasParent, withDestinationURL: realParent)

        XCTAssertThrowsError(try ProjectHandoffMarkdownStore(
            dataRootURL: aliasParent.appendingPathComponent("data", isDirectory: true)
        )) { error in
            XCTAssertEqual(error as? AgentBridgeError, Self.unavailableRootError)
        }
    }

    func testDataRootSymlinkToAnotherDirectoryIsRefused() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "real")

        XCTAssertThrowsError(try ProjectHandoffMarkdownStore(dataRootURL: link)) { error in
            XCTAssertEqual(error as? AgentBridgeError, Self.unavailableRootError)
        }
        var info = stat()
        XCTAssertNotEqual(lstat(real.appendingPathComponent("handoffs").path, &info), 0)
    }

    func testDanglingDataRootSymlinkIsRefused() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appendingPathComponent("dangling", isDirectory: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "missing")

        XCTAssertThrowsError(try ProjectHandoffMarkdownStore(dataRootURL: link)) { error in
            XCTAssertEqual(error as? AgentBridgeError, Self.unavailableRootError)
        }
    }

    func testDataRootSymlinkToFileIsRefused() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file")
        try Data("not a directory".utf8).write(to: file)
        let link = root.appendingPathComponent("file-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "file")

        XCTAssertThrowsError(try ProjectHandoffMarkdownStore(dataRootURL: link)) { error in
            XCTAssertEqual(error as? AgentBridgeError, Self.unavailableRootError)
        }
    }

    func testHandoffsDirectorySymlinkIsStillRefused() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dataRoot = root.appendingPathComponent("data", isDirectory: true)
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            at: dataRoot.appendingPathComponent("handoffs"),
            withDestinationURL: elsewhere
        )

        XCTAssertThrowsError(try ProjectHandoffMarkdownStore(dataRootURL: dataRoot))
    }

    func testCopyHistoriesReadsSourceRootUnderTmpSymlink() throws {
        let source = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("AgentBridgeHandoffTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: source) }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)

        let scope = try appendSample(to: ProjectHandoffMarkdownStore(dataRootURL: source))
        try ProjectHandoffMarkdownStore.copyHistories(from: source, to: destination)

        let copied = try ProjectHandoffMarkdownStore(dataRootURL: destination).load(scope: scope)
        XCTAssertEqual(copied?.suggestedPrompt, "Continue with the tests.")
    }

    func testCopyHistoriesRefusesSourceRootBehindUserAncestorSymlink() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let realParent = root.appendingPathComponent("real-parent", isDirectory: true)
        let sourceReal = realParent.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceReal, withIntermediateDirectories: true)
        try appendSample(to: ProjectHandoffMarkdownStore(dataRootURL: sourceReal))
        let aliasParent = root.appendingPathComponent("alias-parent", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: aliasParent, withDestinationURL: realParent)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)

        XCTAssertThrowsError(try ProjectHandoffMarkdownStore.copyHistories(
            from: aliasParent.appendingPathComponent("source", isDirectory: true),
            to: destination
        )) { error in
            XCTAssertEqual(
                error as? AgentBridgeError,
                .persistence("Could not safely open the source workspace data root.")
            )
        }
    }

    @discardableResult
    private func appendSample(to store: ProjectHandoffMarkdownStore) throws -> SharedMemoryScope {
        let scope = try SharedMemoryScope(
            repositoryPath: "/tmp/agentbridge-handoff-repository",
            snapshotCommit: String(repeating: "a", count: 40)
        )
        _ = try store.append(
            scope: scope,
            sourceProvider: "codex",
            sourceAccount: "default",
            sourceProfileID: UUID(),
            sourceLocalModel: nil,
            targetProvider: "claude",
            targetAccount: "default",
            targetProfileID: UUID(),
            targetLocalModel: nil,
            done: "Implemented the parser.",
            nextStep: "Write the tests.",
            suggestedPrompt: "Continue with the tests."
        )
        return scope
    }

    private func assertRoundTrip(_ store: ProjectHandoffMarkdownStore) throws {
        let scope = try appendSample(to: store)
        let loaded = try store.load(scope: scope)
        XCTAssertEqual(loaded?.suggestedPrompt, "Continue with the tests.")
        XCTAssertTrue(loaded?.markdown.contains("Implemented the parser.") ?? false)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectHandoffMarkdownStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
