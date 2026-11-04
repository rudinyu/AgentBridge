import Darwin
import Foundation

/// A permission an imported extension may request. Permissions describe policy
/// only; this registry never runs extension code or contacts a provider.
public enum ExtensionPermission: String, Codable, CaseIterable, Hashable, Sendable {
    case readSelectedFiles
    case writeSelectedFiles
    case readTaskContext
    case writeTaskContext
    case networkAccess
}

public enum ExtensionKind: String, Codable, Equatable, Hashable, Sendable {
    case skill
    case mcp
}

public enum ExtensionImportSource: String, Codable, Equatable, Hashable, Sendable {
    case localMetadata
    case skillCatalog
    case mcpRegistry
}

/// Inert metadata describing an extension. There is deliberately no executable
/// payload, entrypoint, or activation flag in this type.
public struct ExtensionDescriptor: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: ExtensionKind
    public let name: String
    public let version: String
    public let summary: String
    public let requestedPermissions: [ExtensionPermission]

    public init(
        id: String,
        kind: ExtensionKind,
        name: String,
        version: String,
        summary: String,
        requestedPermissions: [ExtensionPermission] = []
    ) throws {
        let validatedID = try ExtensionPolicyValidation.identifier(id, label: "extension ID", maximumBytes: 160)
        let validatedName = try ExtensionPolicyValidation.text(name, label: "extension name", maximumBytes: 256, allowEmpty: false)
        let validatedVersion = try ExtensionPolicyValidation.text(version, label: "extension version", maximumBytes: 128, allowEmpty: false)
        let validatedSummary = try ExtensionPolicyValidation.text(summary, label: "extension summary", maximumBytes: 4_096, allowEmpty: true)
        guard requestedPermissions.count <= ExtensionPolicyStore.maximumPermissions,
              Set(requestedPermissions).count == requestedPermissions.count else {
            throw AgentBridgeError.invalidInput("Extension permissions must be unique and within the supported limit.")
        }

        self.id = validatedID
        self.kind = kind
        self.name = validatedName
        self.version = validatedVersion
        self.summary = validatedSummary
        self.requestedPermissions = requestedPermissions.sorted { $0.rawValue < $1.rawValue }
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, name, version, summary, requestedPermissions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(String.self, forKey: .id),
                kind: container.decode(ExtensionKind.self, forKey: .kind),
                name: container.decode(String.self, forKey: .name),
                version: container.decode(String.self, forKey: .version),
                summary: container.decode(String.self, forKey: .summary),
                requestedPermissions: container.decode([ExtensionPermission].self, forKey: .requestedPermissions)
            )
        } catch {
            throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "The extension descriptor is invalid.")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(name, forKey: .name)
        try container.encode(version, forKey: .version)
        try container.encode(summary, forKey: .summary)
        try container.encode(requestedPermissions, forKey: .requestedPermissions)
    }
}

public struct ExtensionProvenance: Codable, Equatable, Sendable {
    public let source: ExtensionImportSource
    public let sourceReference: String
    public let importedBy: String
    public let importedAt: Date

    public init(source: ExtensionImportSource, sourceReference: String, importedBy: String, importedAt: Date = Date()) throws {
        self.source = source
        self.sourceReference = try ExtensionPolicyValidation.text(sourceReference, label: "extension source reference", maximumBytes: 2_048, allowEmpty: false)
        self.importedBy = try ExtensionPolicyValidation.text(importedBy, label: "extension importer", maximumBytes: 256, allowEmpty: false)
        self.importedAt = importedAt
    }

    private enum CodingKeys: String, CodingKey { case source, sourceReference, importedBy, importedAt }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                source: container.decode(ExtensionImportSource.self, forKey: .source),
                sourceReference: container.decode(String.self, forKey: .sourceReference),
                importedBy: container.decode(String.self, forKey: .importedBy),
                importedAt: container.decode(Date.self, forKey: .importedAt)
            )
        } catch {
            throw DecodingError.dataCorruptedError(forKey: .sourceReference, in: container, debugDescription: "The extension provenance is invalid.")
        }
    }
}

public struct ExtensionGrant: Codable, Equatable, Sendable {
    public let extensionID: String
    public let projectID: String
    public let permissions: [ExtensionPermission]
    /// Relative project paths the selected-file permissions may access.
    public let allowedRelativePaths: [String]
    /// Exact hostnames allowed when `networkAccess` is granted.
    public let allowedHosts: [String]
    public let grantedBy: String
    public let grantedAt: Date

    public init(
        extensionID: String,
        projectID: String,
        permissions: [ExtensionPermission],
        allowedRelativePaths: [String] = [],
        allowedHosts: [String] = [],
        grantedBy: String,
        grantedAt: Date = Date()
    ) throws {
        self.extensionID = try ExtensionPolicyValidation.identifier(extensionID, label: "extension ID", maximumBytes: 160)
        self.projectID = try ExtensionPolicyValidation.identifier(projectID, label: "project ID", maximumBytes: 160)
        guard !permissions.isEmpty,
              permissions.count <= ExtensionPolicyStore.maximumPermissions,
              Set(permissions).count == permissions.count else {
            throw AgentBridgeError.invalidInput("An extension grant must include unique, supported permissions.")
        }
        let includesFilePermission = permissions.contains(.readSelectedFiles) || permissions.contains(.writeSelectedFiles)
        let includesNetworkPermission = permissions.contains(.networkAccess)
        guard includesFilePermission == !allowedRelativePaths.isEmpty,
              includesNetworkPermission == !allowedHosts.isEmpty else {
            throw AgentBridgeError.invalidInput("File and network permissions require matching, explicit path or host scopes.")
        }
        guard allowedRelativePaths.count <= ExtensionPolicyStore.maximumScopeEntries,
              allowedHosts.count <= ExtensionPolicyStore.maximumScopeEntries else {
            throw AgentBridgeError.invalidInput("Extension permission scopes exceed the supported limit.")
        }
        let paths = try allowedRelativePaths.map(ExtensionPolicyValidation.relativePath)
        let hosts = try allowedHosts.map(ExtensionPolicyValidation.host)
        guard Set(paths).count == paths.count, Set(hosts).count == hosts.count else {
            throw AgentBridgeError.invalidInput("Extension permission scopes must not contain duplicates.")
        }

        self.permissions = permissions.sorted { $0.rawValue < $1.rawValue }
        self.allowedRelativePaths = paths.sorted()
        self.allowedHosts = hosts.sorted()
        self.grantedBy = try ExtensionPolicyValidation.text(grantedBy, label: "granting actor", maximumBytes: 256, allowEmpty: false)
        self.grantedAt = grantedAt
    }

    private enum CodingKeys: String, CodingKey {
        case extensionID, projectID, permissions, allowedRelativePaths, allowedHosts, grantedBy, grantedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                extensionID: container.decode(String.self, forKey: .extensionID),
                projectID: container.decode(String.self, forKey: .projectID),
                permissions: container.decode([ExtensionPermission].self, forKey: .permissions),
                allowedRelativePaths: container.decode([String].self, forKey: .allowedRelativePaths),
                allowedHosts: container.decode([String].self, forKey: .allowedHosts),
                grantedBy: container.decode(String.self, forKey: .grantedBy),
                grantedAt: container.decode(Date.self, forKey: .grantedAt)
            )
        } catch {
            throw DecodingError.dataCorruptedError(forKey: .extensionID, in: container, debugDescription: "The extension grant is invalid.")
        }
    }
}

public enum ExtensionPolicyAuditAction: String, Codable, Equatable, Hashable, Sendable {
    case imported
    case granted
    case revoked
}

public struct ExtensionPolicyAuditEvent: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let action: ExtensionPolicyAuditAction
    public let extensionID: String
    public let projectID: String?
    public let permissions: [ExtensionPermission]
    public let actor: String
    public let occurredAt: Date

    fileprivate init(
        action: ExtensionPolicyAuditAction,
        extensionID: String,
        projectID: String?,
        permissions: [ExtensionPermission],
        actor: String,
        occurredAt: Date = Date()
    ) {
        self.id = UUID()
        self.action = action
        self.extensionID = extensionID
        self.projectID = projectID
        self.permissions = permissions
        self.actor = actor
        self.occurredAt = occurredAt
    }

    private enum CodingKeys: String, CodingKey { case id, action, extensionID, projectID, permissions, actor, occurredAt }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            let decodedID = try container.decode(UUID.self, forKey: .id)
            let decodedAction = try container.decode(ExtensionPolicyAuditAction.self, forKey: .action)
            let decodedExtensionID = try ExtensionPolicyValidation.identifier(
                container.decode(String.self, forKey: .extensionID),
                label: "extension ID",
                maximumBytes: 160
            )
            let decodedProjectID = try container.decodeIfPresent(String.self, forKey: .projectID).map {
                try ExtensionPolicyValidation.identifier($0, label: "project ID", maximumBytes: 160)
            }
            let decodedPermissions = try container.decode([ExtensionPermission].self, forKey: .permissions)
            let decodedActor = try ExtensionPolicyValidation.text(
                container.decode(String.self, forKey: .actor),
                label: "audit actor",
                maximumBytes: 256,
                allowEmpty: false
            )
            let decodedDate = try container.decode(Date.self, forKey: .occurredAt)
            guard decodedPermissions.count <= ExtensionPolicyStore.maximumPermissions,
                  Set(decodedPermissions).count == decodedPermissions.count,
                  (decodedAction == .imported && decodedProjectID == nil)
                    || (decodedAction != .imported && decodedProjectID != nil && !decodedPermissions.isEmpty) else {
                throw AgentBridgeError.invalidInput("The extension policy audit event is invalid.")
            }
            self.id = decodedID
            self.action = decodedAction
            self.extensionID = decodedExtensionID
            self.projectID = decodedProjectID
            self.permissions = decodedPermissions
            self.actor = decodedActor
            self.occurredAt = decodedDate
        } catch {
            throw DecodingError.dataCorruptedError(forKey: .extensionID, in: container, debugDescription: "The extension policy audit event is invalid.")
        }
    }
}

/// Stores inert Skills/MCP metadata and explicit per-project permission grants.
/// Importing a descriptor does not enable it and no provider code is executed.
public final class ExtensionPolicyStore: @unchecked Sendable {
    public static let maximumDescriptors = 200
    public static let maximumGrants = 2_000
    public static let maximumPermissions = 5
    public static let maximumScopeEntries = 32
    public static let maximumStoredBytes = 1 * 1_024 * 1_024
    public static let maximumAuditEvents = 1_000

    private static let fileName = "extension-policy.json"
    private let rootURL: URL

    public init(rootURL: URL, fileManager: FileManager = .default) throws {
        self.rootURL = rootURL.standardizedFileURL
        try AgentBridgePrivateJSONDocument.withLockedRoot(rootURL: self.rootURL, fileManager: fileManager) { _ in () }
    }

    /// Imports descriptor metadata and provenance only. The operation is
    /// idempotent for an identical descriptor and rejects conflicting IDs.
    @discardableResult
    public func importDescriptor(
        _ descriptor: ExtensionDescriptor,
        source: ExtensionImportSource,
        sourceReference: String,
        importedBy: String
    ) throws -> ExtensionProvenance {
        let provenance = try ExtensionProvenance(source: source, sourceReference: sourceReference, importedBy: importedBy)
        return try withDocument { document in
            if let existing = document.extensions.first(where: { $0.descriptor.id == descriptor.id }) {
                guard existing.descriptor == descriptor else {
                    throw AgentBridgeError.invalidInput("An extension with this ID already exists with different metadata.")
                }
                return existing.provenance
            }
            guard document.extensions.count < Self.maximumDescriptors else {
                throw AgentBridgeError.persistence("The extension registry has reached its descriptor limit.")
            }
            document.extensions.append(StoredExtension(descriptor: descriptor, provenance: provenance))
            document.auditEvents.append(ExtensionPolicyAuditEvent(
                action: .imported,
                extensionID: descriptor.id,
                projectID: nil,
                permissions: descriptor.requestedPermissions,
                actor: provenance.importedBy,
                occurredAt: provenance.importedAt
            ))
            Self.trimAuditEvents(&document.auditEvents)
            return provenance
        }
    }

    public func listDescriptors(kind: ExtensionKind? = nil) throws -> [ExtensionDescriptor] {
        try withDocument { document in
            document.extensions
                .map(\.descriptor)
                .filter { kind == nil || $0.kind == kind }
                .sorted { $0.id < $1.id }
        }
    }

    public func descriptor(id: String) throws -> ExtensionDescriptor? {
        let validatedID = try ExtensionPolicyValidation.identifier(id, label: "extension ID", maximumBytes: 160)
        return try withDocument { document in document.extensions.first { $0.descriptor.id == validatedID }?.descriptor }
    }

    public func provenance(forExtensionID id: String) throws -> ExtensionProvenance? {
        let validatedID = try ExtensionPolicyValidation.identifier(id, label: "extension ID", maximumBytes: 160)
        return try withDocument { document in document.extensions.first { $0.descriptor.id == validatedID }?.provenance }
    }

    /// Grants only a subset of permissions declared by an imported descriptor.
    /// File and network grants always require explicit resource scopes.
    @discardableResult
    public func grant(
        extensionID: String,
        projectID: String,
        permissions: [ExtensionPermission],
        allowedRelativePaths: [String] = [],
        allowedHosts: [String] = [],
        grantedBy: String
    ) throws -> ExtensionGrant {
        let grant = try ExtensionGrant(
            extensionID: extensionID,
            projectID: projectID,
            permissions: permissions,
            allowedRelativePaths: allowedRelativePaths,
            allowedHosts: allowedHosts,
            grantedBy: grantedBy
        )
        return try withDocument { document in
            guard let stored = document.extensions.first(where: { $0.descriptor.id == grant.extensionID }) else {
                throw AgentBridgeError.invalidInput("Import the extension descriptor before granting permissions.")
            }
            guard Set(grant.permissions).isSubset(of: Set(stored.descriptor.requestedPermissions)) else {
                throw AgentBridgeError.invalidInput("An extension grant cannot exceed the permissions declared by its descriptor.")
            }
            if let index = document.grants.firstIndex(where: {
                $0.extensionID == grant.extensionID && $0.projectID == grant.projectID
            }) {
                document.grants[index] = grant
            } else {
                guard document.grants.count < Self.maximumGrants else {
                    throw AgentBridgeError.persistence("The extension grant registry has reached its limit.")
                }
                document.grants.append(grant)
            }
            document.auditEvents.append(ExtensionPolicyAuditEvent(
                action: .granted,
                extensionID: grant.extensionID,
                projectID: grant.projectID,
                permissions: grant.permissions,
                actor: grant.grantedBy,
                occurredAt: grant.grantedAt
            ))
            Self.trimAuditEvents(&document.auditEvents)
            return grant
        }
    }

    @discardableResult
    public func revoke(extensionID: String, projectID: String, revokedBy: String) throws -> Bool {
        let validatedExtensionID = try ExtensionPolicyValidation.identifier(extensionID, label: "extension ID", maximumBytes: 160)
        let validatedProjectID = try ExtensionPolicyValidation.identifier(projectID, label: "project ID", maximumBytes: 160)
        let actor = try ExtensionPolicyValidation.text(revokedBy, label: "revoking actor", maximumBytes: 256, allowEmpty: false)
        return try withDocument { document in
            guard let index = document.grants.firstIndex(where: {
                $0.extensionID == validatedExtensionID && $0.projectID == validatedProjectID
            }) else { return false }
            let removed = document.grants.remove(at: index)
            document.auditEvents.append(ExtensionPolicyAuditEvent(
                action: .revoked,
                extensionID: validatedExtensionID,
                projectID: validatedProjectID,
                permissions: removed.permissions,
                actor: actor
            ))
            Self.trimAuditEvents(&document.auditEvents)
            return true
        }
    }

    public func grant(forExtensionID extensionID: String, projectID: String) throws -> ExtensionGrant? {
        let validatedExtensionID = try ExtensionPolicyValidation.identifier(extensionID, label: "extension ID", maximumBytes: 160)
        let validatedProjectID = try ExtensionPolicyValidation.identifier(projectID, label: "project ID", maximumBytes: 160)
        return try withDocument { document in
            document.grants.first { $0.extensionID == validatedExtensionID && $0.projectID == validatedProjectID }
        }
    }

    public func isEnabled(extensionID: String, forProject projectID: String) throws -> Bool {
        try grant(forExtensionID: extensionID, projectID: projectID) != nil
    }

    public func auditEvents(extensionID: String? = nil, projectID: String? = nil) throws -> [ExtensionPolicyAuditEvent] {
        let validatedExtensionID = try extensionID.map {
            try ExtensionPolicyValidation.identifier($0, label: "extension ID", maximumBytes: 160)
        }
        let validatedProjectID = try projectID.map {
            try ExtensionPolicyValidation.identifier($0, label: "project ID", maximumBytes: 160)
        }
        return try withDocument { document in
            document.auditEvents.filter { event in
                (validatedExtensionID == nil || event.extensionID == validatedExtensionID)
                    && (validatedProjectID == nil || event.projectID == validatedProjectID)
            }
        }
    }

    private func withDocument<T>(_ operation: (inout ExtensionPolicyDocument) throws -> T) throws -> T {
        try AgentBridgePrivateJSONDocument.withLockedRoot(rootURL: rootURL) { directoryDescriptor in
            var document = try Self.readDocument(directoryDescriptor: directoryDescriptor)
            let originalData = try Self.encode(document)
            let result = try operation(&document)
            let updatedData = try Self.encode(document)
            if originalData != updatedData {
                try AgentBridgePrivateJSONDocument.write(
                    updatedData,
                    fileName: Self.fileName,
                    maximumBytes: Self.maximumStoredBytes,
                    directoryDescriptor: directoryDescriptor
                )
            }
            return result
        }
    }

    /// Imports a validated policy document from the legacy user-root
    /// location when this private store has none yet.
    @discardableResult
    public func importLegacyDocument(from legacyRootURL: URL) throws -> Bool {
        try AgentBridgePrivateJSONDocument.importLegacyDocument(
            fileName: Self.fileName,
            maximumBytes: Self.maximumStoredBytes,
            from: legacyRootURL,
            into: rootURL
        ) { directoryDescriptor in
            guard try AgentBridgePrivateJSONDocument.read(
                fileName: Self.fileName,
                maximumBytes: Self.maximumStoredBytes,
                directoryDescriptor: directoryDescriptor
            ) != nil else { return nil }
            return try Self.encode(Self.readDocument(directoryDescriptor: directoryDescriptor))
        }
    }

    private static func readDocument(directoryDescriptor: Int32) throws -> ExtensionPolicyDocument {
        guard let data = try AgentBridgePrivateJSONDocument.read(
            fileName: Self.fileName,
            maximumBytes: Self.maximumStoredBytes,
            directoryDescriptor: directoryDescriptor
        ) else { return ExtensionPolicyDocument() }
        do {
            let document = try makeDecoder().decode(ExtensionPolicyDocument.self, from: data)
            guard document.schemaVersion == 1,
                  document.extensions.count <= maximumDescriptors,
                  document.grants.count <= maximumGrants,
                  document.auditEvents.count <= maximumAuditEvents,
                  Set(document.extensions.map { $0.descriptor.id }).count == document.extensions.count,
                  Set(document.grants.map { "\($0.extensionID)\0\($0.projectID)" }).count == document.grants.count,
                  document.grants.allSatisfy({ grant in
                      document.extensions.first(where: { $0.descriptor.id == grant.extensionID })
                          .map { Set(grant.permissions).isSubset(of: Set($0.descriptor.requestedPermissions)) } ?? false
                  }) else {
                throw AgentBridgeError.persistence("The extension policy document failed integrity checks.")
            }
            return document
        } catch let error as AgentBridgeError {
            throw error
        } catch {
            throw AgentBridgeError.persistence("The extension policy document is malformed.")
        }
    }

    private static func encode(_ document: ExtensionPolicyDocument) throws -> Data {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .millisecondsSince1970
            let data = try encoder.encode(document)
            guard data.count <= maximumStoredBytes else {
                throw AgentBridgeError.persistence("The extension policy document exceeds its storage limit.")
            }
            return data
        } catch let error as AgentBridgeError {
            throw error
        } catch {
            throw AgentBridgeError.persistence("The extension policy document could not be encoded.")
        }
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    private static func trimAuditEvents(_ events: inout [ExtensionPolicyAuditEvent]) {
        if events.count > maximumAuditEvents {
            events.removeFirst(events.count - maximumAuditEvents)
        }
    }
}

private struct StoredExtension: Codable {
    let descriptor: ExtensionDescriptor
    let provenance: ExtensionProvenance
}

private struct ExtensionPolicyDocument: Codable {
    var schemaVersion: Int
    var extensions: [StoredExtension]
    var grants: [ExtensionGrant]
    var auditEvents: [ExtensionPolicyAuditEvent]

    init() {
        schemaVersion = 1
        extensions = []
        grants = []
        auditEvents = []
    }
}

private enum ExtensionPolicyValidation {
    static func identifier(_ value: String, label: String, maximumBytes: Int) throws -> String {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= maximumBytes,
              isASCIIAlphaNumeric(bytes[0]),
              bytes.allSatisfy({ isASCIIAlphaNumeric($0) || $0 == 45 || $0 == 46 || $0 == 95 || $0 == 58 }),
              value != ".", value != ".." else {
            throw AgentBridgeError.invalidInput("The \(label) is invalid.")
        }
        return value
    }

    static func text(_ value: String, label: String, maximumBytes: Int, allowEmpty: Bool) throws -> String {
        let bytes = Array(value.utf8)
        guard bytes.count <= maximumBytes,
              (allowEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw AgentBridgeError.invalidInput("The \(label) is invalid or exceeds its size limit.")
        }
        return value
    }

    static func relativePath(_ value: String) throws -> String {
        let trimmed = try text(value, label: "relative path scope", maximumBytes: 1_024, allowEmpty: false)
        guard !trimmed.hasPrefix("/"), !trimmed.contains("\\"),
              trimmed.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw AgentBridgeError.invalidInput("File scopes must be normalized relative paths without traversal components.")
        }
        return trimmed
    }

    static func host(_ value: String) throws -> String {
        let normalized = value.lowercased()
        let labels = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard normalized.utf8.count <= 253, !labels.isEmpty,
              labels.allSatisfy({ label in
                  let bytes = Array(label.utf8)
                  return !bytes.isEmpty && bytes.count <= 63
                      && isASCIIAlphaNumeric(bytes[0]) && isASCIIAlphaNumeric(bytes[bytes.count - 1])
                      && bytes.allSatisfy({ isASCIIAlphaNumeric($0) || $0 == 45 })
              }) else {
            throw AgentBridgeError.invalidInput("Network scopes must be exact valid hostnames.")
        }
        return normalized
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
    }
}

/// Shared, bounded, private JSON-file persistence for the new coordination
/// stores. All file access is relative to a no-follow, private directory fd.
enum AgentBridgePrivateJSONDocument {
    private static let lockFileName = ".coordination.lock"

    static func withLockedRoot<T>(rootURL: URL, fileManager: FileManager = .default, _ operation: (Int32) throws -> T) throws -> T {
        do {
            if !fileManager.fileExists(atPath: rootURL.path) {
                try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
            }
        } catch {
            throw AgentBridgeError.persistence("Could not create private coordination storage.")
        }

        let directoryDescriptor = rootURL.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard directoryDescriptor >= 0 else {
            throw AgentBridgeError.persistence("Coordination storage is unavailable or is a symbolic link.")
        }
        defer { _ = close(directoryDescriptor) }
        var directoryInfo = stat()
        guard fstat(directoryDescriptor, &directoryInfo) == 0,
              (directoryInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              directoryInfo.st_uid == getuid(),
              fchmod(directoryDescriptor, mode_t(0o700)) == 0 else {
            throw AgentBridgeError.persistence("Coordination storage failed private-directory checks.")
        }

        let lockDescriptor = lockFileName.withCString {
            openat(directoryDescriptor, $0, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        }
        guard lockDescriptor >= 0 else {
            throw AgentBridgeError.persistence("Could not safely open the coordination lock.")
        }
        defer { _ = close(lockDescriptor) }
        var lockInfo = stat()
        guard fstat(lockDescriptor, &lockInfo) == 0,
              (lockInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              lockInfo.st_uid == getuid(), lockInfo.st_nlink == 1,
              fchmod(lockDescriptor, mode_t(0o600)) == 0 else {
            throw AgentBridgeError.persistence("The coordination lock is not a private regular file.")
        }
        while flock(lockDescriptor, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            throw AgentBridgeError.persistence("Could not lock coordination storage.")
        }
        defer { _ = flock(lockDescriptor, LOCK_UN) }
        return try operation(directoryDescriptor)
    }

    static func read(fileName: String, maximumBytes: Int, directoryDescriptor: Int32) throws -> Data? {
        let descriptor = fileName.withCString { openat(directoryDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw AgentBridgeError.persistence("Could not safely open a coordination document.")
        }
        defer { _ = close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              metadata.st_uid == getuid(), metadata.st_nlink == 1,
              metadata.st_size >= 0, metadata.st_size <= maximumBytes,
              fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw AgentBridgeError.persistence("A coordination document is not a bounded private regular file.")
        }
        var data = Data()
        data.reserveCapacity(Int(metadata.st_size))
        var buffer = [UInt8](repeating: 0, count: 8 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw AgentBridgeError.persistence("Could not read a coordination document.")
            }
            guard data.count + count <= maximumBytes else {
                throw AgentBridgeError.persistence("A coordination document exceeds its size limit.")
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    static func write(_ data: Data, fileName: String, maximumBytes: Int, directoryDescriptor: Int32) throws {
        guard data.count <= maximumBytes else {
            throw AgentBridgeError.persistence("A coordination document exceeds its size limit.")
        }
        var existing = stat()
        if fileName.withCString({ fstatat(directoryDescriptor, $0, &existing, AT_SYMLINK_NOFOLLOW) }) == 0 {
            guard (existing.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                  existing.st_uid == getuid(), existing.st_nlink == 1 else {
                throw AgentBridgeError.persistence("A coordination document path is not a private regular file.")
            }
        } else if errno != ENOENT {
            throw AgentBridgeError.persistence("Could not inspect a coordination document path.")
        }

        let temporaryName = ".coordination-\(UUID().uuidString.lowercased()).tmp"
        let descriptor = temporaryName.withCString {
            openat(directoryDescriptor, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        }
        guard descriptor >= 0 else {
            throw AgentBridgeError.persistence("Could not create a private coordination document.")
        }
        var shouldRemoveTemporary = true
        defer {
            _ = close(descriptor)
            if shouldRemoveTemporary { _ = temporaryName.withCString { unlinkat(directoryDescriptor, $0, 0) } }
        }
        try writeAll(data, descriptor: descriptor)
        guard fchmod(descriptor, mode_t(0o600)) == 0, fsync(descriptor) == 0 else {
            throw AgentBridgeError.persistence("Could not secure and sync a coordination document.")
        }
        let renameResult = temporaryName.withCString { source in
            fileName.withCString { destination in renameat(directoryDescriptor, source, directoryDescriptor, destination) }
        }
        guard renameResult == 0 else {
            throw AgentBridgeError.persistence("Could not atomically publish a coordination document.")
        }
        shouldRemoveTemporary = false
        guard fsync(directoryDescriptor) == 0 else {
            throw AgentBridgeError.persistence("Could not sync coordination storage.")
        }
    }

    /// Copies a legacy document into `rootURL` once, only when `rootURL` has
    /// no document yet. `validatedData` reads the document from a directory
    /// fd, runs the owning store's integrity checks, and returns canonical
    /// bytes (nil when absent). A missing or invalid legacy document is
    /// skipped; the legacy copy is never modified or removed.
    @discardableResult
    static func importLegacyDocument(
        fileName: String,
        maximumBytes: Int,
        from legacyRootURL: URL,
        into rootURL: URL,
        validatedData: (Int32) throws -> Data?
    ) throws -> Bool {
        let legacyRoot = legacyRootURL.standardizedFileURL
        guard legacyRoot.path != rootURL.standardizedFileURL.path else { return false }
        var metadata = stat()
        if lstat(legacyRoot.path, &metadata) != 0 {
            if errno == ENOENT { return false }
            throw AgentBridgeError.persistence("Could not inspect legacy coordination storage.")
        }
        guard (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else { return false }

        return try withLockedRoot(rootURL: rootURL) { directoryDescriptor in
            var existing = stat()
            if fileName.withCString({ fstatat(directoryDescriptor, $0, &existing, AT_SYMLINK_NOFOLLOW) }) == 0 {
                return false
            } else if errno != ENOENT {
                throw AgentBridgeError.persistence("Could not inspect a coordination document path.")
            }
            let legacyData: Data?
            do {
                legacyData = try withExistingLockedRoot(rootURL: legacyRoot) { try validatedData($0) } ?? nil
            } catch {
                return false
            }
            guard let legacyData else { return false }
            try write(legacyData, fileName: fileName, maximumBytes: maximumBytes, directoryDescriptor: directoryDescriptor)
            return true
        }
    }

    /// Takes the writers' lock on an existing root without creating the
    /// directory or lock file and without changing permissions. Returns nil
    /// when no store has ever locked that root.
    private static func withExistingLockedRoot<T>(rootURL: URL, _ operation: (Int32) throws -> T) throws -> T? {
        let directoryDescriptor = rootURL.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard directoryDescriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw AgentBridgeError.persistence("Legacy coordination storage is unavailable or is a symbolic link.")
        }
        defer { _ = close(directoryDescriptor) }
        var directoryInfo = stat()
        guard fstat(directoryDescriptor, &directoryInfo) == 0,
              (directoryInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              directoryInfo.st_uid == getuid() else {
            throw AgentBridgeError.persistence("Legacy coordination storage failed ownership checks.")
        }

        let lockDescriptor = lockFileName.withCString {
            openat(directoryDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard lockDescriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw AgentBridgeError.persistence("Could not safely open the legacy coordination lock.")
        }
        defer { _ = close(lockDescriptor) }
        var lockInfo = stat()
        guard fstat(lockDescriptor, &lockInfo) == 0,
              (lockInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              lockInfo.st_uid == getuid(), lockInfo.st_nlink == 1 else {
            throw AgentBridgeError.persistence("The legacy coordination lock is not a private regular file.")
        }
        while flock(lockDescriptor, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            throw AgentBridgeError.persistence("Could not lock legacy coordination storage.")
        }
        defer { _ = flock(lockDescriptor, LOCK_UN) }
        return try operation(directoryDescriptor)
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, baseAddress.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw AgentBridgeError.persistence("Could not write a coordination document.")
                }
                guard count > 0 else { throw AgentBridgeError.persistence("A coordination document write was incomplete.") }
                offset += count
            }
        }
    }
}
