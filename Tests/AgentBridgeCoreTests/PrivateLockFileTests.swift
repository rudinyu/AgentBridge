import Darwin
import Foundation
import XCTest
@testable import AgentBridgeCore

final class PrivateLockFileTests: XCTestCase {
    private struct LockError: Error, Equatable {
        let failure: String
    }

    func testExclusiveLockBlocksOtherHoldersAndSharedLocksCoexist() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let lockURL = root.appendingPathComponent("store.lock")

        try PrivateLockFile.withLock(at: lockURL, error: map) {
            XCTAssertFalse(try canLockWithoutWaiting(lockURL, operation: LOCK_SH))
        }
        XCTAssertTrue(try canLockWithoutWaiting(lockURL, operation: LOCK_EX))

        try PrivateLockFile.withLock(at: lockURL, exclusive: false, error: map) {
            XCTAssertTrue(try canLockWithoutWaiting(lockURL, operation: LOCK_SH))
            XCTAssertFalse(try canLockWithoutWaiting(lockURL, operation: LOCK_EX))
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: lockURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testRejectsSymbolicLinksAndHardLinkedLockFiles() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target.lock")
        FileManager.default.createFile(atPath: target.path, contents: nil, attributes: [.posixPermissions: 0o600])

        let symlink = root.appendingPathComponent("symlink.lock")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
        XCTAssertThrowsError(try PrivateLockFile.withLock(at: symlink, error: map) {}) { error in
            XCTAssertEqual(error as? LockError, LockError(failure: "unavailable"))
        }

        let hardLink = root.appendingPathComponent("hardlink.lock")
        try FileManager.default.linkItem(at: target, to: hardLink)
        XCTAssertThrowsError(try PrivateLockFile.withLock(at: hardLink, error: map) {}) { error in
            XCTAssertEqual(error as? LockError, LockError(failure: "notPrivateFile"))
        }
    }

    func testDirectoryRelativeLockHonorsCreateAndPermissionOptions() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(directory, 0)
        defer { _ = close(directory) }

        XCTAssertThrowsError(try PrivateLockFile.withLock(named: ".lock", in: directory, create: false, error: map) {}) { error in
            XCTAssertEqual(error as? LockError, LockError(failure: "unavailable"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".lock").path))

        let ran = try PrivateLockFile.withLock(named: ".lock", in: directory, create: true, error: map) { true }
        XCTAssertTrue(ran)

        // Read-only locking leaves loose permissions untouched.
        XCTAssertEqual(chmod(root.appendingPathComponent(".lock").path, 0o644), 0)
        try PrivateLockFile.withLock(named: ".lock", in: directory, create: false, securePermissions: false, error: map) {}
        let attributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(".lock").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o644)
    }

    private func map(_ failure: PrivateLockFile.Failure) -> Error {
        switch failure {
        case .unavailable: LockError(failure: "unavailable")
        case .notPrivateFile: LockError(failure: "notPrivateFile")
        case .lockFailed: LockError(failure: "lockFailed")
        }
    }

    /// flock locks belong to the open file description, so a second open in
    /// this process contends with the helper's lock like another process would.
    private func canLockWithoutWaiting(_ url: URL, operation: Int32) throws -> Bool {
        let descriptor = open(url.path, O_RDWR | O_CLOEXEC)
        guard descriptor >= 0 else { throw LockError(failure: "open") }
        defer { _ = close(descriptor) }
        guard flock(descriptor, operation | LOCK_NB) == 0 else { return false }
        _ = flock(descriptor, LOCK_UN)
        return true
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentBridge-Lock-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
