import Darwin
import Foundation

/// A short-lived, private ticket for AgentBridge's native MCP stdio proxy.
/// Provider CLIs receive only the proxy command and this ticket path; the
/// underlying server is started by the proxy after it validates the grant.
public struct MCPProxyTicket: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let ticketID: UUID
    public let sessionID: UUID
    public let extensionID: String
    public let projectID: String
    public let provider: AgentProvider
    public let profileID: UUID
    public let configurationDigest: String
    public let reviewedDigest: String
    public let serverInspectionDigest: String
    public let sessionExtensionFingerprint: String
    public let runtimeStoreRootPath: String
    public let workspacePath: String
    public let cancellationRequestPath: String
    public let receiptPath: String
    public let proxyExecutablePath: String
    public let proxyExecutableDigest: String
    public let serverExecutablePath: String
    public let serverExecutableDigest: String
    public let serverArguments: [String]
    public let serverEntrypointPins: [MCPEntrypointPin]
    public let allowedTools: [String]
    public let startupTimeoutSeconds: Int
    public let toolTimeoutSeconds: Int
    public let maximumToolCallsPerRun: Int
    public let maximumToolResponseBytes: Int
    public let maximumTotalToolResponseBytes: Int
    public let launchConfiguration: MCPLaunchConfiguration
    public let createdAt: Date
    public let expiresAt: Date

    public var macControlTargetBundleID: String? { launchConfiguration.macControlTargetBundleID }
    public var macControlAccessMode: MacControlAccessMode? { launchConfiguration.macControlAccessMode }

    init(
        ticketID: UUID = UUID(),
        sessionID: UUID,
        extensionID: String,
        projectID: String,
        provider: AgentProvider,
        profileID: UUID,
        configurationDigest: String,
        reviewedDigest: String,
        serverInspectionDigest: String,
        sessionExtensionFingerprint: String,
        runtimeStoreRootPath: String,
        workspacePath: String,
        cancellationRequestPath: String,
        receiptPath: String,
        proxyExecutablePath: String,
        proxyExecutableDigest: String,
        serverExecutablePath: String,
        serverExecutableDigest: String,
        serverArguments: [String],
        serverEntrypointPins: [MCPEntrypointPin],
        allowedTools: [String],
        startupTimeoutSeconds: Int,
        toolTimeoutSeconds: Int,
        maximumToolCallsPerRun: Int,
        maximumToolResponseBytes: Int,
        maximumTotalToolResponseBytes: Int,
        launchConfiguration: MCPLaunchConfiguration,
        createdAt: Date = Date(),
        expiresAt: Date
    ) throws {
        guard (expiresAt.timeIntervalSince(createdAt) > 0),
              expiresAt.timeIntervalSince(createdAt) <= 3_600,
              (2...120).contains(startupTimeoutSeconds), (2...600).contains(toolTimeoutSeconds),
              (1...128).contains(maximumToolCallsPerRun),
              (64 * 1_024...8 * 1_024 * 1_024).contains(maximumToolResponseBytes),
              (maximumToolResponseBytes...32 * 1_024 * 1_024).contains(maximumTotalToolResponseBytes),
              ActiveExtensionValidation.isSHA256(configurationDigest),
              ActiveExtensionValidation.isSHA256(reviewedDigest),
              ActiveExtensionValidation.isSHA256(serverInspectionDigest),
              ActiveExtensionValidation.isSHA256(sessionExtensionFingerprint),
              ActiveExtensionValidation.isSHA256(proxyExecutableDigest),
              ActiveExtensionValidation.isSHA256(serverExecutableDigest) else {
            throw AgentBridgeError.invalidInput("The MCP proxy ticket fields are invalid or expired.")
        }
        self.schemaVersion = 1
        self.ticketID = ticketID
        self.sessionID = sessionID
        self.extensionID = try ActiveExtensionValidation.identifier(extensionID, label: "extension ID")
        self.projectID = try ActiveExtensionValidation.identifier(projectID, label: "project ID")
        self.provider = provider
        self.profileID = profileID
        self.configurationDigest = configurationDigest.lowercased()
        self.reviewedDigest = reviewedDigest.lowercased()
        self.serverInspectionDigest = serverInspectionDigest.lowercased()
        self.sessionExtensionFingerprint = sessionExtensionFingerprint.lowercased()
        self.runtimeStoreRootPath = try Self.absolutePath(runtimeStoreRootPath)
        self.workspacePath = try Self.absolutePath(workspacePath)
        self.cancellationRequestPath = try Self.absolutePath(cancellationRequestPath)
        self.receiptPath = try Self.absolutePath(receiptPath)
        self.proxyExecutablePath = try Self.absolutePath(proxyExecutablePath)
        self.proxyExecutableDigest = proxyExecutableDigest.lowercased()
        self.serverExecutablePath = try Self.absolutePath(serverExecutablePath)
        self.serverExecutableDigest = serverExecutableDigest.lowercased()
        self.serverArguments = try ActiveExtensionValidation.arguments(serverArguments)
        guard serverEntrypointPins.count <= 16,
              Set(serverEntrypointPins.map(\.path)).count == serverEntrypointPins.count else {
            throw AgentBridgeError.invalidInput("MCP entrypoint pins exceed their count or uniqueness limit.")
        }
        self.serverEntrypointPins = serverEntrypointPins
        self.allowedTools = try ActiveExtensionValidation.toolNames(allowedTools)
        self.startupTimeoutSeconds = startupTimeoutSeconds
        self.toolTimeoutSeconds = toolTimeoutSeconds
        self.maximumToolCallsPerRun = maximumToolCallsPerRun
        self.maximumToolResponseBytes = maximumToolResponseBytes
        self.maximumTotalToolResponseBytes = maximumTotalToolResponseBytes
        try launchConfiguration.validate(
            executablePath: self.serverExecutablePath,
            executableDigest: self.serverExecutableDigest,
            arguments: self.serverArguments,
            entrypointPins: self.serverEntrypointPins,
            allowedTools: self.allowedTools,
            extensionID: self.extensionID,
            maximumToolCallsPerRun: self.maximumToolCallsPerRun,
            maximumToolResponseBytes: self.maximumToolResponseBytes,
            maximumTotalToolResponseBytes: self.maximumTotalToolResponseBytes
        )
        self.launchConfiguration = launchConfiguration
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    public func validate(now: Date = Date()) throws {
        guard schemaVersion == 1,
              expiresAt > now,
              createdAt.timeIntervalSince(now) <= 300,
              expiresAt.timeIntervalSince(createdAt) <= 3_600,
              ActiveExtensionValidation.isSHA256(configurationDigest),
              ActiveExtensionValidation.isSHA256(reviewedDigest),
              ActiveExtensionValidation.isSHA256(serverInspectionDigest),
              ActiveExtensionValidation.isSHA256(sessionExtensionFingerprint),
              ActiveExtensionValidation.isSHA256(proxyExecutableDigest),
              ActiveExtensionValidation.isSHA256(serverExecutableDigest),
              (2...120).contains(startupTimeoutSeconds),
              (2...600).contains(toolTimeoutSeconds),
              (1...128).contains(maximumToolCallsPerRun),
              (64 * 1_024...8 * 1_024 * 1_024).contains(maximumToolResponseBytes),
              (maximumToolResponseBytes...32 * 1_024 * 1_024).contains(maximumTotalToolResponseBytes) else {
            throw AgentBridgeError.invalidInput("The MCP proxy ticket is invalid or expired.")
        }
        try launchConfiguration.validate(
            executablePath: serverExecutablePath,
            executableDigest: serverExecutableDigest,
            arguments: serverArguments,
            entrypointPins: serverEntrypointPins,
            allowedTools: allowedTools,
            extensionID: extensionID,
            maximumToolCallsPerRun: maximumToolCallsPerRun,
            maximumToolResponseBytes: maximumToolResponseBytes,
            maximumTotalToolResponseBytes: maximumTotalToolResponseBytes
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, ticketID, sessionID, extensionID, projectID, provider, profileID, configurationDigest, reviewedDigest, serverInspectionDigest, sessionExtensionFingerprint, runtimeStoreRootPath, workspacePath, cancellationRequestPath, receiptPath, proxyExecutablePath, proxyExecutableDigest, serverExecutablePath, serverExecutableDigest, serverArguments, serverEntrypointPins, allowedTools, startupTimeoutSeconds, toolTimeoutSeconds, maximumToolCallsPerRun, maximumToolResponseBytes, maximumTotalToolResponseBytes, launchConfiguration, createdAt, expiresAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                ticketID: container.decode(UUID.self, forKey: .ticketID),
                sessionID: container.decode(UUID.self, forKey: .sessionID),
                extensionID: container.decode(String.self, forKey: .extensionID),
                projectID: container.decode(String.self, forKey: .projectID),
                provider: container.decode(AgentProvider.self, forKey: .provider),
                profileID: container.decode(UUID.self, forKey: .profileID),
                configurationDigest: container.decode(String.self, forKey: .configurationDigest),
                reviewedDigest: container.decode(String.self, forKey: .reviewedDigest),
                serverInspectionDigest: container.decode(String.self, forKey: .serverInspectionDigest),
                sessionExtensionFingerprint: container.decode(String.self, forKey: .sessionExtensionFingerprint),
                runtimeStoreRootPath: container.decode(String.self, forKey: .runtimeStoreRootPath),
                workspacePath: container.decode(String.self, forKey: .workspacePath),
                cancellationRequestPath: container.decode(String.self, forKey: .cancellationRequestPath),
                receiptPath: container.decode(String.self, forKey: .receiptPath),
                proxyExecutablePath: container.decode(String.self, forKey: .proxyExecutablePath),
                proxyExecutableDigest: container.decode(String.self, forKey: .proxyExecutableDigest),
                serverExecutablePath: container.decode(String.self, forKey: .serverExecutablePath),
                serverExecutableDigest: container.decode(String.self, forKey: .serverExecutableDigest),
                serverArguments: container.decode([String].self, forKey: .serverArguments),
                serverEntrypointPins: container.decode([MCPEntrypointPin].self, forKey: .serverEntrypointPins),
                allowedTools: container.decode([String].self, forKey: .allowedTools),
                startupTimeoutSeconds: container.decode(Int.self, forKey: .startupTimeoutSeconds),
                toolTimeoutSeconds: container.decode(Int.self, forKey: .toolTimeoutSeconds),
                maximumToolCallsPerRun: container.decode(Int.self, forKey: .maximumToolCallsPerRun),
                maximumToolResponseBytes: container.decode(Int.self, forKey: .maximumToolResponseBytes),
                maximumTotalToolResponseBytes: container.decode(Int.self, forKey: .maximumTotalToolResponseBytes),
                launchConfiguration: container.decode(MCPLaunchConfiguration.self, forKey: .launchConfiguration),
                createdAt: container.decode(Date.self, forKey: .createdAt),
                expiresAt: container.decode(Date.self, forKey: .expiresAt)
            )
            guard try container.decode(Int.self, forKey: .schemaVersion) == 1 else {
                throw AgentBridgeError.invalidInput("Unsupported MCP proxy ticket version.")
            }
        } catch {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: container, debugDescription: "The MCP proxy ticket is invalid.")
        }
    }

    private static func absolutePath(_ value: String) throws -> String {
        guard let path = ActiveExtensionValidation.preservedAbsolutePath(value) else {
            throw AgentBridgeError.invalidInput("MCP proxy ticket paths must be absolute and valid.")
        }
        return path
    }
}

/// MacControl uses the same stdio proxy protocol, with additional target and
/// action restrictions carried by `launchConfiguration`.
public typealias MacControlProxyTicket = MCPProxyTicket

/// Per-run command passed to the provider CLI. Construction is limited to an
/// absolute AgentBridge executable and one private ticket path.
public struct MCPServerCommandConfiguration: Equatable, Sendable {
    public let extensionID: String
    public let serverID: String
    public let commandPath: String
    public let arguments: [String]
    public let ticketID: UUID
    public let configurationDigest: String
    public let inspectionDigest: String
    public let receiptPath: String
    public let allowedTools: [String]
    public let startupTimeoutSeconds: Int
    public let toolTimeoutSeconds: Int
    public let maximumToolCallsPerRun: Int
    public let maximumToolResponseBytes: Int
    public let maximumTotalToolResponseBytes: Int

    init(
        configuration: ActiveMCPConfiguration,
        proxyExecutablePath: String,
        ticketURL: URL,
        receiptURL: URL,
        ticketID: UUID,
        inspectionDigest: String,
        maximumToolCallsPerRun: Int? = nil
    ) throws {
        let proxy = try ActiveExtensionValidation.absoluteExecutablePath(proxyExecutablePath)
        guard ticketURL.isFileURL, let ticketPath = ActiveExtensionValidation.preservedAbsolutePath(ticketURL.path) else {
            throw AgentBridgeError.invalidInput("MCP proxy ticket path is invalid.")
        }
        guard receiptURL.isFileURL, let receiptPath = ActiveExtensionValidation.preservedAbsolutePath(receiptURL.path) else {
            throw AgentBridgeError.invalidInput("MCP proxy receipt path is invalid.")
        }
        guard ActiveExtensionValidation.isSHA256(inspectionDigest) else {
            throw AgentBridgeError.invalidInput("MCP server inspection digest is invalid.")
        }
        self.extensionID = configuration.extensionID
        self.serverID = MCPServerIdentifier.make(extensionID: configuration.extensionID)
        self.commandPath = proxy
        self.arguments = ["mcp-proxy", "--ticket", ticketPath]
        self.ticketID = ticketID
        self.configurationDigest = configuration.configurationDigest
        self.inspectionDigest = inspectionDigest.lowercased()
        self.receiptPath = receiptPath
        self.allowedTools = configuration.allowedTools
        self.startupTimeoutSeconds = configuration.startupTimeoutSeconds
        self.toolTimeoutSeconds = configuration.toolTimeoutSeconds
        let effectiveCallLimit = maximumToolCallsPerRun ?? configuration.maximumToolCallsPerRun
        guard (1...configuration.maximumToolCallsPerRun).contains(effectiveCallLimit) else {
            throw AgentBridgeError.invalidInput("The per-run MCP tool-call limit may only reduce the approved configuration limit.")
        }
        self.maximumToolCallsPerRun = effectiveCallLimit
        self.maximumToolResponseBytes = configuration.maximumToolResponseBytes
        self.maximumTotalToolResponseBytes = configuration.maximumTotalToolResponseBytes
    }
}

public enum MCPProxyTicketFile {
    private static let maximumBytes = 128 * 1_024

    @discardableResult
    public static func write(_ ticket: MCPProxyTicket, to url: URL) throws -> URL {
        try ticket.validate()
        guard url.isFileURL, let path = ActiveExtensionValidation.preservedAbsolutePath(url.path) else {
            throw AgentBridgeError.invalidInput("MCP proxy ticket destination is invalid.")
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let fileName = components.last, !components.isEmpty,
              components.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw AgentBridgeError.invalidInput("MCP proxy ticket destination is invalid.")
        }
        let parent = try openDirectory(components.dropLast(1).map { $0 })
        defer { _ = Darwin.close(parent) }
        var parentInfo = stat()
        guard fstat(parent, &parentInfo) == 0,
              (parentInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              parentInfo.st_uid == getuid(), (parentInfo.st_mode & 0o077) == 0 else {
            throw AgentBridgeError.persistence("MCP proxy ticket directory must be private to the current user.")
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(ticket)
        guard data.count <= maximumBytes else { throw AgentBridgeError.invalidInput("MCP proxy ticket exceeds its size limit.") }
        let descriptor = fileName.withCString { openat(parent, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600)) }
        guard descriptor >= 0 else { throw AgentBridgeError.persistence("Could not create a private MCP proxy ticket.") }
        defer { _ = Darwin.close(descriptor) }
        try writeAll(data, descriptor: descriptor)
        guard fchmod(descriptor, mode_t(0o600)) == 0, fsync(descriptor) == 0, fsync(parent) == 0 else {
            _ = fileName.withCString { unlinkat(parent, $0, 0) }
            throw AgentBridgeError.persistence("Could not secure and sync the MCP proxy ticket.")
        }
        return URL(fileURLWithPath: path)
    }

    public static func read(from url: URL) throws -> MCPProxyTicket {
        guard url.isFileURL, let path = ActiveExtensionValidation.preservedAbsolutePath(url.path) else {
            throw AgentBridgeError.invalidInput("MCP proxy ticket path is invalid.")
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let fileName = components.last, !components.isEmpty,
              components.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw AgentBridgeError.invalidInput("MCP proxy ticket path is invalid.")
        }
        let parent = try openDirectory(components.dropLast(1).map { $0 })
        defer { _ = Darwin.close(parent) }
        var parentInfo = stat()
        guard fstat(parent, &parentInfo) == 0,
              (parentInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              parentInfo.st_uid == getuid(), (parentInfo.st_mode & 0o077) == 0 else {
            throw AgentBridgeError.persistence("MCP proxy ticket directory failed private access checks.")
        }
        let descriptor = fileName.withCString { openat(parent, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        guard descriptor >= 0 else { throw AgentBridgeError.persistence("MCP proxy ticket is missing or unsafe.") }
        defer { _ = Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              metadata.st_uid == getuid(), metadata.st_nlink == 1,
              (metadata.st_mode & 0o077) == 0,
              metadata.st_size > 0, metadata.st_size <= maximumBytes else {
            throw AgentBridgeError.persistence("MCP proxy ticket must be a bounded private regular file.")
        }
        var data = Data()
        data.reserveCapacity(Int(metadata.st_size))
        var buffer = [UInt8](repeating: 0, count: 8 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                return Darwin.read(descriptor, baseAddress, rawBuffer.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw AgentBridgeError.persistence("Could not read MCP proxy ticket.")
            }
            guard data.count + count <= maximumBytes else { throw AgentBridgeError.persistence("MCP proxy ticket exceeds its size limit.") }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count == metadata.st_size else { throw AgentBridgeError.persistence("MCP proxy ticket changed while it was being read.") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let ticket = try decoder.decode(MCPProxyTicket.self, from: data)
        try ticket.validate()
        return ticket
    }

    private static func openDirectory(_ components: [String]) throws -> Int32 {
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw AgentBridgeError.persistence("MCP proxy ticket path is unavailable.") }
        for component in components {
            let child = component.withCString { openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) }
            guard child >= 0 else {
                _ = Darwin.close(descriptor)
                throw AgentBridgeError.persistence("MCP proxy ticket path contains a symlink or missing directory.")
            }
            _ = Darwin.close(descriptor)
            descriptor = child
        }
        return descriptor
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let count = Darwin.write(descriptor, baseAddress.advanced(by: offset), rawBuffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw AgentBridgeError.persistence("Could not write MCP proxy ticket.")
                }
                guard count > 0 else { throw AgentBridgeError.persistence("MCP proxy ticket write was incomplete.") }
                offset += count
            }
        }
    }
}
