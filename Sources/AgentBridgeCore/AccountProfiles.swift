import Darwin
import Foundation

/// A user-visible label for one provider context. Local-model profiles are
/// configuration identities only; they do not imply a provider login.
///
/// This model intentionally contains no credentials or plan claims. Provider
/// status and plan details must be obtained from that profile's own CLI login.
public struct AccountProfile: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public let provider: AgentProvider
    public let usesExistingLogin: Bool
    public var allowsSharedMemory: Bool
    public let createdAt: Date

    public init(
        id: UUID,
        name: String,
        provider: AgentProvider,
        usesExistingLogin: Bool,
        allowsSharedMemory: Bool,
        createdAt: Date
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.usesExistingLogin = usesExistingLogin
        self.allowsSharedMemory = allowsSharedMemory
        self.createdAt = createdAt
    }

    /// Stable reserved IDs for built-in provider profiles.
    public static func defaultID(for provider: AgentProvider) -> UUID {
        switch provider {
        case .codex:
            UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))
        case .claude:
            UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2))
        case .local:
            UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3))
        }
    }
}

public enum AccountProfileError: Error, LocalizedError, Equatable {
    case invalidName
    case duplicateName(AgentProvider)
    case profileNotFound(UUID)
    case providerMismatch(UUID, AgentProvider)
    case existingLoginCannotBeReauthenticated
    case maximumProfilesReached
    case invalidStore
    case persistence(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName:
            "Account names must contain 1 to 80 characters and cannot include newlines or control characters."
        case .duplicateName(let provider):
            "An account named this already exists for \(provider.rawValue). Choose a different name."
        case .profileNotFound(let id):
            "Could not find account profile \(id.uuidString)."
        case .providerMismatch(let id, let provider):
            "Account profile \(id.uuidString)  does not belong to \(provider.rawValue)."
        case .existingLoginCannotBeReauthenticated:
            "The built-in account uses the current local sign-in. To avoid signing out or overwriting it, create a separate account profile before signing in."
        case .maximumProfilesReached:
            "The maximum number of account profiles has been reached."
        case .invalidStore:
            "The account profile file is malformed or inconsistent. Switching stopped to avoid using the wrong account."
        case .persistence(let message):
            "Could not safely read or write account settings: \(message)"
        }
    }
}

/// Stores account labels, selections, and per-profile shared-memory consent.
/// Credentials remain in the provider CLI's own profile directory and are
/// never loaded, copied, or stored by this type.
public final class AccountProfileStore: @unchecked Sendable {
    public let rootURL: URL

    private let accountsURL: URL
    private let profilesURL: URL
    private let lockURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let beforeProfileMetadataWrite: (() throws -> Void)?
    private let instanceLock = NSLock()

    fileprivate static let schemaVersion = 1
    private static let maximumFileSize = 1 * 1_024 * 1_024
    private static let maximumProfiles = 64

    public convenience init(rootURL: URL, fileManager: FileManager = .default) throws {
        try self.init(rootURL: rootURL, fileManager: fileManager, beforeProfileMetadataWrite: nil)
    }

    /// Internal persistence fault injection keeps rollback behavior testable
    /// without changing the public store API.
    init(
        rootURL: URL,
        fileManager: FileManager = .default,
        beforeProfileMetadataWrite: (() throws -> Void)?
    ) throws {
        guard rootURL.isFileURL, rootURL.path.hasPrefix("/"),
              !rootURL.path.split(separator: "/", omittingEmptySubsequences: true).contains("..") else {
            throw AccountProfileError.persistence("The account directory path is invalid.")
        }
        let standardizedRoot = rootURL.standardizedFileURL
        guard standardizedRoot.path != "/" else {
            throw AccountProfileError.persistence("The filesystem root cannot be used as an account directory.")
        }

        self.rootURL = standardizedRoot
        self.accountsURL = standardizedRoot.appendingPathComponent("accounts", isDirectory: true)
        self.profilesURL = standardizedRoot.appendingPathComponent(".account-profiles.json")
        self.lockURL = standardizedRoot.appendingPathComponent(".account-profiles.lock")
        self.fileManager = fileManager
        self.beforeProfileMetadataWrite = beforeProfileMetadataWrite
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601
        self.encoder.outputFormatting = [.sortedKeys]

        try Self.createPrivateDirectory(standardizedRoot, fileManager: fileManager)
        try Self.createPrivateDirectory(accountsURL, fileManager: fileManager)
        try Self.createPrivateFile(lockURL)

        // Initialize an empty document once, under the same cross-process lock
        // used by later mutations. Existing malformed files fail closed.
        _ = try withStoreLock {
            let document = try readDocument(allowMissing: true)
            try writeDocument(document)
            return document
        }
    }

    /// Returns the built-in provider profile first, followed by its
    /// independent custom profiles.
    public func profiles(provider: AgentProvider) throws -> [AccountProfile] {
        try withStoreLock {
            let document = try readDocument()
            var result = [defaultProfile(provider: provider, document: document)]
            result.append(contentsOf: document.profiles
                .filter { $0.provider == provider }
                .sorted {
                    if $0.createdAt == $1.createdAt { return $0.id.uuidString < $1.id.uuidString }
                    return $0.createdAt < $1.createdAt
                })
            return result
        }
    }

    public func selected(provider: AgentProvider) throws -> AccountProfile {
        try withStoreLock {
            let document = try readDocument()
            let selectedID = document.selectedProfileID(for: provider) ?? Self.defaultID(for: provider)
            if selectedID == Self.defaultID(for: provider) {
                return defaultProfile(provider: provider, document: document)
            }
            guard let profile = document.profiles.first(where: { $0.id == selectedID }) else {
                throw AccountProfileError.invalidStore
            }
            guard profile.provider == provider else {
                throw AccountProfileError.providerMismatch(selectedID, provider)
            }
            return profile
        }
    }

    /// Creates a separate provider configuration directory. Custom profiles
    /// allow shared memory by default and are not selected automatically.
    public func create(
        name: String,
        provider: AgentProvider,
        allowsSharedMemory: Bool = true
    ) throws -> AccountProfile {
        let normalizedName = try Self.normalizedName(name)
        return try withStoreLock {
            var document = try readDocument()
            guard document.profiles.count < Self.maximumProfiles else {
                throw AccountProfileError.maximumProfilesReached
            }
            let normalizedKey = Self.nameKey(normalizedName)
            guard !document.profiles.contains(where: {
                $0.provider == provider && Self.nameKey($0.name) == normalizedKey
            }) else {
                throw AccountProfileError.duplicateName(provider)
            }

            let id = UUID()
            let profile = AccountProfile(
                id: id,
                name: normalizedName,
                provider: provider,
                usesExistingLogin: false,
                allowsSharedMemory: allowsSharedMemory,
                createdAt: Date()
            )
            let directory = provider == .local ? nil : credentialDirectory(for: profile)
            let profileDirectory = directory?.deletingLastPathComponent()
            try Self.createPrivateDirectory(accountsURL, fileManager: fileManager)
            if let profileDirectory { try Self.createExclusivePrivateDirectory(profileDirectory) }
            do {
                if let directory { try Self.createPrivateDirectory(directory, fileManager: fileManager) }
                document.profiles.append(profile)
                try beforeProfileMetadataWrite?()
                try writeDocument(document)
            } catch {
                // Atomic persistence may have renamed the metadata before a
                // later sync error. Retain its credential directory if the
                // profile is already present, or if the metadata cannot be
                // read to determine whether the rename committed.
                let profileWasPersisted = (try? readDocument().profiles.contains(where: { $0.id == id })) ?? true
                if !profileWasPersisted, let profileDirectory {
                    try? fileManager.removeItem(at: profileDirectory)
                }
                throw error
            }
            return profile
        }
    }

    public func select(id: UUID, provider: AgentProvider) throws {
        try withStoreLock {
            var document = try readDocument()
            if id != Self.defaultID(for: provider) {
                if Self.providers.first(where: { Self.defaultID(for: $0) == id }) != nil {
                    throw AccountProfileError.providerMismatch(id, provider)
                }
                guard let profile = document.profiles.first(where: { $0.id == id }) else {
                    throw AccountProfileError.profileNotFound(id)
                }
                guard profile.provider == provider else {
                    throw AccountProfileError.providerMismatch(id, provider)
                }
            }
            document.setSelectedProfileID(id, for: provider)
            try writeDocument(document)
        }
    }

    /// Updates shared-memory consent for either a custom profile or a built-in
    /// provider profile. New custom profiles and built-ins start enabled.
    public func setSharedMemoryAllowed(id: UUID, allowed: Bool) throws {
        try withStoreLock {
            var document = try readDocument()
            if id == Self.defaultID(for: .codex) {
                document.defaultCodexSharedMemoryAllowed = allowed
            } else if id == Self.defaultID(for: .claude) {
                document.defaultClaudeSharedMemoryAllowed = allowed
            } else if id == Self.defaultID(for: .local) {
                document.defaultLocalSharedMemoryAllowed = allowed
            } else if let index = document.profiles.firstIndex(where: { $0.id == id }) {
                document.profiles[index].allowsSharedMemory = allowed
            } else {
                throw AccountProfileError.profileNotFound(id)
            }
            try writeDocument(document)
        }
    }

    /// Holds the profile-store lock while the caller copies approved context
    /// into its destination, so consent cannot be revoked between validation
    /// and that synchronous copy.
    func withSharedMemoryConsent<T>(profileIDs: Set<UUID>, _ operation: () throws -> T) throws -> T {
        try withStoreLock {
            let document = try readDocument()
            for id in profileIDs {
                let allowsSharing: Bool
                if id == AccountProfile.defaultID(for: .codex) {
                    allowsSharing = document.defaultCodexSharedMemoryAllowed ?? true
                } else if id == AccountProfile.defaultID(for: .claude) {
                    allowsSharing = document.defaultClaudeSharedMemoryAllowed ?? true
                } else if id == AccountProfile.defaultID(for: .local) {
                    allowsSharing = document.defaultLocalSharedMemoryAllowed ?? true
                } else if let profile = document.profiles.first(where: { $0.id == id }) {
                    allowsSharing = profile.allowsSharedMemory
                } else {
                    throw AccountProfileError.profileNotFound(id)
                }
                guard allowsSharing else {
                    throw AgentBridgeError.sessionMismatch("Shared-memory consent has changed; review the handoff again.")
                }
            }
            return try operation()
        }
    }

    /// Returns only the provider-specific configuration-directory override.
    /// The default profile deliberately returns no overrides so the app does
    /// not change or inspect the user's existing provider login.
    public func environmentOverrides(for profile: AccountProfile) throws -> [String: String] {
        try withStoreLock {
            let document = try readDocument()
            let canonical = try canonicalProfile(profile, document: document)
            guard !canonical.usesExistingLogin, canonical.provider != .local else { return [:] }
            let directory = credentialDirectory(for: canonical)
            try Self.requirePrivateDirectory(directory)
            switch canonical.provider {
            case .codex:
                return ["CODEX_HOME": directory.path]
            case .claude:
                return ["CLAUDE_CONFIG_DIR": directory.path]
            case .local:
                return [:]
            }
        }
    }

    /// Provides only subscription-login commands for custom profiles. Passing
    /// the provider CLI `--console` flag would select API billing, so it is
    /// intentionally absent. Built-in login is never re-run by the app.
    public func loginArguments(for profile: AccountProfile) throws -> [String] {
        try withStoreLock {
            let document = try readDocument()
            let canonical = try canonicalProfile(profile, document: document)
            guard !canonical.usesExistingLogin else {
                throw AccountProfileError.existingLoginCannotBeReauthenticated
            }
            switch canonical.provider {
            case .codex:
                return ["-c", "forced_login_method=\"chatgpt\"", "login"]
            case .claude:
                return [
                    "--safe-mode", "--setting-sources", "",
                    "--settings", "{\"forceLoginMethod\":\"claudeai\",\"disableAllHooks\":true,\"apiKeyHelper\":\"\"}",
                    "auth", "login"
                ]
            case .local:
                throw AccountProfileError.existingLoginCannotBeReauthenticated
            }
        }
    }

    private static var providers: [AgentProvider] { [.codex, .claude, .local] }

    private static func defaultID(for provider: AgentProvider) -> UUID {
        AccountProfile.defaultID(for: provider)
    }

    private func defaultProfile(provider: AgentProvider, document: ProfileStoreDocument) -> AccountProfile {
        AccountProfile(
            id: Self.defaultID(for: provider),
            name: provider == .local ? "Local model" : "Current local login",
            provider: provider,
            // Prevent login workflows from treating this built-in identity as
            // a credential profile. Local has no authentication state.
            usesExistingLogin: true,
            allowsSharedMemory: document.defaultSharedMemoryAllowed(for: provider),
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func canonicalProfile(_ supplied: AccountProfile, document: ProfileStoreDocument) throws -> AccountProfile {
        if supplied.id == Self.defaultID(for: supplied.provider) {
            return defaultProfile(provider: supplied.provider, document: document)
        }
        if Self.providers.contains(where: { Self.defaultID(for: $0) == supplied.id }) {
            throw AccountProfileError.providerMismatch(supplied.id, supplied.provider)
        }
        guard let stored = document.profiles.first(where: { $0.id == supplied.id }) else {
            throw AccountProfileError.profileNotFound(supplied.id)
        }
        guard stored.provider == supplied.provider else {
            throw AccountProfileError.providerMismatch(supplied.id, supplied.provider)
        }
        return stored
    }

    private func credentialDirectory(for profile: AccountProfile) -> URL {
        accountsURL
            .appendingPathComponent(profile.id.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent(profile.provider.rawValue, isDirectory: true)
    }

    private func withStoreLock<T>(_ operation: () throws -> T) throws -> T {
        instanceLock.lock()
        defer { instanceLock.unlock() }
        return try PrivateLockFile.withLock(at: lockURL, error: { failure in
            switch failure {
            case .unavailable: AccountProfileError.persistence("Could not open the lock file.")
            case .notPrivateFile: AccountProfileError.persistence("The lock file is not a secure private regular file.")
            case .lockFailed: AccountProfileError.persistence("Could not lock the account settings.")
            }
        }, operation)
    }

    private func readDocument(allowMissing: Bool = false) throws -> ProfileStoreDocument {
        var pathMetadata = stat()
        if lstat(profilesURL.path, &pathMetadata) != 0 {
            if errno == ENOENT, allowMissing { return ProfileStoreDocument() }
            if errno == ENOENT { throw AccountProfileError.invalidStore }
            throw AccountProfileError.persistence("Could not inspect the account profile file.")
        }
        guard (pathMetadata.st_mode & S_IFMT) == S_IFREG else {
            throw AccountProfileError.persistence("The account profile file cannot be a symlink or a non-regular file.")
        }

        let descriptor = open(profilesURL.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw AccountProfileError.persistence("Could not safely open the account profile file.") }
        defer { _ = close(descriptor) }
        var openedMetadata = stat()
        guard fstat(descriptor, &openedMetadata) == 0,
              (openedMetadata.st_mode & S_IFMT) == S_IFREG,
              openedMetadata.st_size >= 0,
              openedMetadata.st_size <= off_t(Self.maximumFileSize),
              fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw AccountProfileError.persistence("The account profile file format or permissions are unsafe.")
        }

        var data = Data()
        data.reserveCapacity(Int(openedMetadata.st_size))
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw AccountProfileError.persistence("Could not read the account profile file.")
            }
            if count == 0 { break }
            guard data.count + count <= Self.maximumFileSize else {
                throw AccountProfileError.persistence("The account profile file exceeds the size limit.")
            }
            data.append(contentsOf: buffer[0..<count])
        }

        do {
            let document = try decoder.decode(ProfileStoreDocument.self, from: data)
            try validate(document)
            return document
        } catch let error as AccountProfileError {
            throw error
        } catch {
            throw AccountProfileError.invalidStore
        }
    }

    private func writeDocument(_ document: ProfileStoreDocument) throws {
        try validate(document)
        let data: Data
        do {
            data = try encoder.encode(document)
        } catch {
            throw AccountProfileError.persistence("Could not encode the account settings.")
        }
        guard data.count <= Self.maximumFileSize else {
            throw AccountProfileError.persistence("The account profile file exceeds the size limit.")
        }

        let temporaryURL = rootURL.appendingPathComponent(".account-profiles.\(UUID().uuidString.lowercased()).tmp")
        let descriptor = open(temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw AccountProfileError.persistence("Could not create a temporary account profile file.") }
        var shouldRemoveTemporary = true
        defer {
            _ = close(descriptor)
            if shouldRemoveTemporary { _ = unlink(temporaryURL.path) }
        }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw AccountProfileError.persistence("Could not set permissions on the temporary file.")
        }

        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let count = write(descriptor, baseAddress.advanced(by: written), rawBuffer.count - written)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw AccountProfileError.persistence("Could not write the temporary account settings.")
                }
                guard count > 0 else { throw AccountProfileError.persistence("The account settings write did not complete.") }
                written += count
            }
        }
        guard fsync(descriptor) == 0, rename(temporaryURL.path, profilesURL.path) == 0 else {
            throw AccountProfileError.persistence("Could not atomically update the account settings.")
        }
        shouldRemoveTemporary = false
        let directoryDescriptor = open(rootURL.path, O_RDONLY)
        if directoryDescriptor >= 0 {
            defer { _ = close(directoryDescriptor) }
            guard fsync(directoryDescriptor) == 0 else {
                throw AccountProfileError.persistence("Could not synchronize the account directory.")
            }
        }
    }

    private func validate(_ document: ProfileStoreDocument) throws {
        guard document.schemaVersion == Self.schemaVersion,
              document.profiles.count <= Self.maximumProfiles else {
            throw AccountProfileError.invalidStore
        }

        var ids = Set<UUID>()
        var namesByProvider: [AgentProvider: Set<String>] = [:]
        for profile in document.profiles {
            guard !profile.usesExistingLogin,
                  profile.id != Self.defaultID(for: .codex),
                  profile.id != Self.defaultID(for: .claude),
                  profile.createdAt.timeIntervalSince1970.isFinite,
                  (try? Self.normalizedName(profile.name)) == profile.name,
                  ids.insert(profile.id).inserted else {
                throw AccountProfileError.invalidStore
            }
            let key = Self.nameKey(profile.name)
            guard namesByProvider[profile.provider, default: []].insert(key).inserted else {
                throw AccountProfileError.invalidStore
            }
        }

        for provider in Self.providers {
            guard let selectedID = document.selectedProfileID(for: provider) else { continue }
            if selectedID == Self.defaultID(for: provider) { continue }
            guard let profile = document.profiles.first(where: { $0.id == selectedID }),
                  profile.provider == provider else {
                throw AccountProfileError.invalidStore
            }
        }
    }

    private static func normalizedName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...80).contains(trimmed.count),
              !trimmed.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0)
              }) else {
            throw AccountProfileError.invalidName
        }
        return trimmed
    }

    private static func nameKey(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func createPrivateDirectory(_ url: URL, fileManager: FileManager) throws {
        var metadata = stat()
        if lstat(url.path, &metadata) != 0 {
            guard errno == ENOENT else { throw AccountProfileError.persistence("Could not inspect the account directory.") }
            do {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                throw AccountProfileError.persistence("Could not create the account directory.")
            }
        }
        guard lstat(url.path, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFDIR,
              chmod(url.path, mode_t(0o700)) == 0 else {
            throw AccountProfileError.persistence("The account directory must be private and cannot be a symlink.")
        }
    }

    private static func createExclusivePrivateDirectory(_ url: URL) throws {
        let result = url.path.withCString { mkdir($0, mode_t(0o700)) }
        guard result == 0 else {
            throw AccountProfileError.persistence("Could not create the new account directory.")
        }
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              chmod(url.path, mode_t(0o700)) == 0 else {
            _ = url.path.withCString { rmdir($0) }
            throw AccountProfileError.persistence("The new account directory permissions are unsafe.")
        }
    }

    private static func requirePrivateDirectory(_ url: URL) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFDIR,
              chmod(url.path, mode_t(0o700)) == 0 else {
            throw AccountProfileError.persistence("The account sign-in directory is missing or is not a secure private directory.")
        }
    }

    private static func createPrivateFile(_ url: URL) throws {
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw AccountProfileError.persistence("Could not create a secure lock file.") }
        defer { _ = close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG,
              fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw AccountProfileError.persistence("The lock file must be a private regular file.")
        }
    }
}

private struct ProfileStoreDocument: Codable {
    let schemaVersion: Int
    var profiles: [AccountProfile]
    var selectedCodexProfileID: UUID?
    var selectedClaudeProfileID: UUID?
    var defaultCodexSharedMemoryAllowed: Bool?
    var defaultClaudeSharedMemoryAllowed: Bool?
    var selectedLocalProfileID: UUID?
    var defaultLocalSharedMemoryAllowed: Bool?

    init() {
        self.schemaVersion = AccountProfileStore.schemaVersion
        self.profiles = []
        self.selectedCodexProfileID = nil
        self.selectedClaudeProfileID = nil
        self.defaultCodexSharedMemoryAllowed = nil
        self.defaultClaudeSharedMemoryAllowed = nil
        self.selectedLocalProfileID = nil
        self.defaultLocalSharedMemoryAllowed = nil
    }

    func selectedProfileID(for provider: AgentProvider) -> UUID? {
        switch provider {
        case .codex: selectedCodexProfileID
        case .claude: selectedClaudeProfileID
        case .local: selectedLocalProfileID
        }
    }

    mutating func setSelectedProfileID(_ id: UUID, for provider: AgentProvider) {
        switch provider {
        case .codex: selectedCodexProfileID = id
        case .claude: selectedClaudeProfileID = id
        case .local: selectedLocalProfileID = id
        }
    }

    func defaultSharedMemoryAllowed(for provider: AgentProvider) -> Bool {
        switch provider {
        case .codex: defaultCodexSharedMemoryAllowed ?? true
        case .claude: defaultClaudeSharedMemoryAllowed ?? true
        case .local: defaultLocalSharedMemoryAllowed ?? true
        }
    }
}
