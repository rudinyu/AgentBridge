import Darwin
import Foundation
import XCTest
@testable import AgentBridgeCore

final class AccountProfilesTests: XCTestCase {
    func testBuiltInProfileIDsAreStableAndDefaultLoginCannotBeReplaced() throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        let store = try AccountProfileStore(rootURL: root)
        let codex = try store.profiles(provider: .codex)[0]
        let claude = try store.profiles(provider: .claude)[0]

        XCTAssertEqual(AccountProfile.defaultID(for: .codex).uuidString.lowercased(), "00000000-0000-0000-0000-000000000001")
        XCTAssertEqual(AccountProfile.defaultID(for: .claude).uuidString.lowercased(), "00000000-0000-0000-0000-000000000002")
        XCTAssertEqual(codex.id, AccountProfile.defaultID(for: .codex))
        XCTAssertEqual(claude.id, AccountProfile.defaultID(for: .claude))
        XCTAssertEqual(codex.name, "目前本機登入")
        XCTAssertEqual(claude.name, "目前本機登入")
        XCTAssertTrue(codex.usesExistingLogin)
        XCTAssertTrue(claude.usesExistingLogin)
        XCTAssertEqual(try store.environmentOverrides(for: codex), [:])
        XCTAssertEqual(try store.environmentOverrides(for: claude), [:])
        XCTAssertThrowsError(try store.loginArguments(for: codex)) {
            XCTAssertEqual($0 as? AccountProfileError, .existingLoginCannotBeReauthenticated)
        }
        XCTAssertThrowsError(try store.loginArguments(for: claude)) {
            XCTAssertEqual($0 as? AccountProfileError, .existingLoginCannotBeReauthenticated)
        }
    }

    func testCustomProfilesUseSeparateProviderDirectoriesAndSelectionPersists() throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        let store = try AccountProfileStore(rootURL: root)
        let codexPersonal = try store.create(name: "Personal", provider: .codex)
        let codexWork = try store.create(name: "Work", provider: .codex)
        let claudePersonal = try store.create(name: "Personal", provider: .claude)

        XCTAssertNotEqual(try store.environmentOverrides(for: codexPersonal)["CODEX_HOME"],
                          try store.environmentOverrides(for: codexWork)["CODEX_HOME"])
        XCTAssertNotEqual(try store.environmentOverrides(for: codexPersonal)["CODEX_HOME"],
                          try store.environmentOverrides(for: claudePersonal)["CLAUDE_CONFIG_DIR"])
        XCTAssertNil(try store.environmentOverrides(for: codexWork)["HOME"])
        XCTAssertNil(try store.environmentOverrides(for: claudePersonal)["HOME"])

        try store.select(id: codexWork.id, provider: .codex)
        try store.select(id: claudePersonal.id, provider: .claude)
        let reopenedStore = try AccountProfileStore(rootURL: root)
        XCTAssertEqual(try reopenedStore.selected(provider: .codex).id, codexWork.id)
        XCTAssertEqual(try reopenedStore.selected(provider: .claude).id, claudePersonal.id)

        let codexPath = try XCTUnwrap(reopenedStore.environmentOverrides(for: codexWork)["CODEX_HOME"])
        let claudePath = try XCTUnwrap(reopenedStore.environmentOverrides(for: claudePersonal)["CLAUDE_CONFIG_DIR"])
        XCTAssertTrue(codexPath.hasSuffix("/accounts/\(codexWork.id.uuidString.lowercased())/codex"))
        XCTAssertTrue(claudePath.hasSuffix("/accounts/\(claudePersonal.id.uuidString.lowercased())/claude"))
    }

    func testSubscriptionLoginArgumentsUseOnlyCustomProfiles() throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        let store = try AccountProfileStore(rootURL: root)
        let codex = try store.create(name: "Codex alt", provider: .codex)
        let claude = try store.create(name: "Claude alt", provider: .claude)

        XCTAssertEqual(
            try store.loginArguments(for: codex),
            ["-c", "forced_login_method=\"chatgpt\"", "login"]
        )
        let claudeArguments = try store.loginArguments(for: claude)
        XCTAssertEqual(Array(claudeArguments.suffix(2)), ["auth", "login"])
        XCTAssertTrue(claudeArguments.contains("--safe-mode"))
        XCTAssertTrue(claudeArguments.contains("--setting-sources"))
        XCTAssertFalse(claudeArguments.contains("--console"))
        XCTAssertTrue(claudeArguments.contains(where: { $0.contains("forceLoginMethod") && $0.contains("claudeai") }))
    }

    func testSharedMemoryStartsOnForNewProfilesAndCanBeChangedPerProfile() throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        let store = try AccountProfileStore(rootURL: root)
        let codexDefault = try store.selected(provider: .codex)
        let claudeDefault = try store.selected(provider: .claude)
        let codexCustom = try store.create(name: "Codex alt", provider: .codex)
        let claudeCustom = try store.create(name: "Claude alt", provider: .claude)
        let optedOutCustom = try store.create(name: "Codex private", provider: .codex, allowsSharedMemory: false)

        XCTAssertTrue(codexDefault.allowsSharedMemory)
        XCTAssertTrue(claudeDefault.allowsSharedMemory)
        XCTAssertTrue(codexCustom.allowsSharedMemory)
        XCTAssertTrue(claudeCustom.allowsSharedMemory)
        XCTAssertFalse(optedOutCustom.allowsSharedMemory)

        try store.setSharedMemoryAllowed(id: codexCustom.id, allowed: false)
        try store.setSharedMemoryAllowed(id: claudeCustom.id, allowed: false)
        try store.setSharedMemoryAllowed(id: AccountProfile.defaultID(for: .codex), allowed: false)
        let reopenedStore = try AccountProfileStore(rootURL: root)

        XCTAssertFalse(try XCTUnwrap(reopenedStore.profiles(provider: .codex).first(where: { $0.id == codexCustom.id })).allowsSharedMemory)
        XCTAssertFalse(try XCTUnwrap(reopenedStore.profiles(provider: .codex).first(where: { $0.id == optedOutCustom.id })).allowsSharedMemory)
        XCTAssertFalse(try XCTUnwrap(reopenedStore.profiles(provider: .claude).first(where: { $0.id == claudeCustom.id })).allowsSharedMemory)
        XCTAssertFalse(try reopenedStore.selected(provider: .codex).allowsSharedMemory)
        XCTAssertTrue(try reopenedStore.selected(provider: .claude).allowsSharedMemory)
    }

    func testProviderMismatchAndForgedProfileAreRejected() throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        let store = try AccountProfileStore(rootURL: root)
        let codex = try store.create(name: "Codex alt", provider: .codex)

        XCTAssertThrowsError(try store.select(id: codex.id, provider: .claude)) {
            XCTAssertEqual($0 as? AccountProfileError, .providerMismatch(codex.id, .claude))
        }
        let forged = AccountProfile(
            id: codex.id,
            name: "Fake label",
            provider: .claude,
            usesExistingLogin: false,
            allowsSharedMemory: true,
            createdAt: Date()
        )
        XCTAssertThrowsError(try store.environmentOverrides(for: forged)) {
            XCTAssertEqual($0 as? AccountProfileError, .providerMismatch(codex.id, .claude))
        }
        XCTAssertThrowsError(try store.loginArguments(for: forged)) {
            XCTAssertEqual($0 as? AccountProfileError, .providerMismatch(codex.id, .claude))
        }
    }

    func testNamesAreTrimmedBoundedAndCannotContainControls() throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        let store = try AccountProfileStore(rootURL: root)
        let profile = try store.create(name: "  Travel  ", provider: .codex)
        XCTAssertEqual(profile.name, "Travel")

        for invalid in ["", " \n ", "a\nb", String(repeating: "x", count: 81)] {
            XCTAssertThrowsError(try store.create(name: invalid, provider: .codex)) {
                XCTAssertEqual($0 as? AccountProfileError, .invalidName)
            }
        }
        XCTAssertThrowsError(try store.create(name: "travel", provider: .codex)) {
            XCTAssertEqual($0 as? AccountProfileError, .duplicateName(.codex))
        }
        XCTAssertNoThrow(try store.create(name: "travel", provider: .claude))
    }

    func testCorruptAndSymlinkedStateFailClosed() throws {
        let corruptRoot = try makeTemporaryRoot()
        defer { removeTemporaryRoot(corruptRoot) }
        _ = try AccountProfileStore(rootURL: corruptRoot)
        try Data("{ invalid JSON".utf8).write(to: corruptRoot.appendingPathComponent(".account-profiles.json"))
        XCTAssertThrowsError(try AccountProfileStore(rootURL: corruptRoot)) {
            XCTAssertEqual($0 as? AccountProfileError, .invalidStore)
        }

        let symlinkRoot = try makeTemporaryRoot()
        defer { removeTemporaryRoot(symlinkRoot) }
        try FileManager.default.createDirectory(at: symlinkRoot, withIntermediateDirectories: true)
        let outside = symlinkRoot.deletingLastPathComponent().appendingPathComponent("outside.json")
        try Data("{}".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: symlinkRoot.appendingPathComponent(".account-profiles.json"),
            withDestinationURL: outside
        )
        XCTAssertThrowsError(try AccountProfileStore(rootURL: symlinkRoot))
    }

    func testSymlinkedCredentialDirectoryIsRejected() throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        let store = try AccountProfileStore(rootURL: root)
        let profile = try store.create(name: "Alt", provider: .codex)
        let providerDirectory = root
            .appendingPathComponent("accounts", isDirectory: true)
            .appendingPathComponent(profile.id.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("codex", isDirectory: true)
        try FileManager.default.removeItem(at: providerDirectory)
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: providerDirectory, withDestinationURL: outside)

        XCTAssertThrowsError(try store.environmentOverrides(for: profile))
    }

    func testAccountMetadataDoesNotPersistCredentialValues() throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        let store = try AccountProfileStore(rootURL: root)
        _ = try store.create(name: "Personal", provider: .claude)
        let encoded = try String(contentsOf: root.appendingPathComponent(".account-profiles.json"), encoding: .utf8)

        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("api_key"))
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("access_token"))
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("password"))
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("credential"))
    }

    func testDirectoriesAndStateFilesArePrivate() throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        let store = try AccountProfileStore(rootURL: root)
        let profile = try store.create(name: "Private", provider: .claude)
        let idDirectory = root.appendingPathComponent("accounts", isDirectory: true)
            .appendingPathComponent(profile.id.uuidString.lowercased(), isDirectory: true)
        let credentialDirectory = idDirectory.appendingPathComponent("claude", isDirectory: true)

        XCTAssertEqual(try permissions(root), 0o700)
        XCTAssertEqual(try permissions(root.appendingPathComponent("accounts", isDirectory: true)), 0o700)
        XCTAssertEqual(try permissions(idDirectory), 0o700)
        XCTAssertEqual(try permissions(credentialDirectory), 0o700)
        XCTAssertEqual(try permissions(root.appendingPathComponent(".account-profiles.json")), 0o600)
        XCTAssertEqual(try permissions(root.appendingPathComponent(".account-profiles.lock")), 0o600)
    }

    func testFailedProfileMetadataWritePreservesOtherCredentialDirectories() throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        let store = try AccountProfileStore(rootURL: root)
        let existing = try store.create(name: "Keep existing", provider: .claude)
        let accountsDirectory = root.appendingPathComponent("accounts", isDirectory: true)
        let existingCredentialDirectory = accountsDirectory
            .appendingPathComponent(existing.id.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("claude", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: existingCredentialDirectory.path))
        let profileDirectoriesBefore = try Set(FileManager.default.contentsOfDirectory(atPath: accountsDirectory.path))

        let failingStore = try AccountProfileStore(
            rootURL: root,
            beforeProfileMetadataWrite: {
                throw AccountProfileError.persistence("injected metadata write failure")
            }
        )
        XCTAssertThrowsError(try failingStore.create(name: "Must roll back", provider: .codex))

        let profileDirectoriesAfter = try Set(FileManager.default.contentsOfDirectory(atPath: accountsDirectory.path))
        XCTAssertEqual(profileDirectoriesAfter, profileDirectoriesBefore)
        XCTAssertTrue(FileManager.default.fileExists(atPath: existingCredentialDirectory.path))
        XCTAssertEqual(try store.profiles(provider: .claude).map(\.id), [AccountProfile.defaultID(for: .claude), existing.id])
        XCTAssertEqual(try store.profiles(provider: .codex).map(\.id), [AccountProfile.defaultID(for: .codex)])
    }

    func testConcurrentCreatesAcrossStoreInstancesAreSerialized() throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        let stores = try (0..<8).map { _ in try AccountProfileStore(rootURL: root) }
        let results = ConcurrentProfileResults()
        let group = DispatchGroup()

        for (index, store) in stores.enumerated() {
            group.enter()
            DispatchQueue.global().async {
                do {
                    _ = try store.create(name: "Codex \(index)", provider: .codex)
                    results.record(success: true)
                } catch {
                    results.record(success: false)
                }
                group.leave()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(results.successes, 8)
        XCTAssertEqual(results.failures, 0)
        XCTAssertEqual(try stores[0].profiles(provider: .codex).count, 9)
    }

    private func makeTemporaryRoot() throws -> URL {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentBridge-AccountProfilesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        return parent.appendingPathComponent("profiles", isDirectory: true)
    }

    private func removeTemporaryRoot(_ root: URL) {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    private func permissions(_ url: URL) throws -> Int {
        let value = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        return try XCTUnwrap(value).intValue
    }
}

private final class ConcurrentProfileResults: @unchecked Sendable {
    private let lock = NSLock()
    private var successCount = 0
    private var failureCount = 0

    var successes: Int {
        lock.lock()
        defer { lock.unlock() }
        return successCount
    }

    var failures: Int {
        lock.lock()
        defer { lock.unlock() }
        return failureCount
    }

    func record(success: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if success { successCount += 1 } else { failureCount += 1 }
    }
}
