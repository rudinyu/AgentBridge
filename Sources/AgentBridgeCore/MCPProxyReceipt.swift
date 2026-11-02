import Darwin
import Foundation

public enum MCPProxyReceiptStatus: String, Codable, Equatable, Sendable {
    case started
    case initialized
    case failed
}

public enum MCPProxyFailureCode: String, Codable, Equatable, Sendable {
    case ticketInvalid
    case grantRevoked
    case executableChanged
    case entrypointChanged
    case serverLaunchFailed
    case handshakeFailed
    case toolCallRejected
    case toolResponseInvalid
    case cancelled
    case timedOut
}

/// Secret-free, bounded evidence written by the stdio proxy. It deliberately
/// stores no MCP arguments, prompt text, result blocks, images, or server output.
public struct MCPProxyReceipt: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let ticketID: UUID
    public let extensionID: String
    public let configurationDigest: String
    public let status: MCPProxyReceiptStatus
    public let toolCallCount: Int
    public let failureCode: MCPProxyFailureCode?
    public let updatedAt: Date

    init(
        ticket: MCPProxyTicket,
        status: MCPProxyReceiptStatus,
        toolCallCount: Int = 0,
        failureCode: MCPProxyFailureCode? = nil,
        updatedAt: Date = Date()
    ) throws {
        guard (0...ticket.maximumToolCallsPerRun).contains(toolCallCount),
              (status == .failed) == (failureCode != nil),
              ActiveExtensionValidation.isSHA256(ticket.configurationDigest) else {
            throw AgentBridgeError.invalidInput("MCP proxy receipt fields are invalid.")
        }
        self.schemaVersion = 1
        self.ticketID = ticket.ticketID
        self.extensionID = ticket.extensionID
        self.configurationDigest = ticket.configurationDigest
        self.status = status
        self.toolCallCount = toolCallCount
        self.failureCode = failureCode
        self.updatedAt = updatedAt
    }
}

public enum MCPProxyReceiptFile {
    private static let maximumBytes = 16 * 1_024

    public static func write(_ receipt: MCPProxyReceipt, to url: URL) throws {
        guard url.isFileURL, let path = ActiveExtensionValidation.preservedAbsolutePath(url.path) else {
            throw AgentBridgeError.invalidInput("MCP proxy receipt path is invalid.")
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let fileName = components.last, !components.isEmpty,
              components.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw AgentBridgeError.invalidInput("MCP proxy receipt path is invalid.")
        }
        let parent = try openDirectory(Array(components.dropLast(1)))
        defer { _ = Darwin.close(parent) }
        try requirePrivateDirectory(parent)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(receipt)
        guard data.count <= maximumBytes else { throw AgentBridgeError.invalidInput("MCP proxy receipt exceeds its size limit.") }

        let temporaryName = ".mcp-receipt-\(UUID().uuidString.lowercased())"
        let descriptor = temporaryName.withCString { openat(parent, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600)) }
        guard descriptor >= 0 else { throw AgentBridgeError.persistence("Could not create a private MCP proxy receipt.") }
        defer {
            _ = Darwin.close(descriptor)
            _ = temporaryName.withCString { unlinkat(parent, $0, 0) }
        }
        try writeAll(data, descriptor: descriptor)
        guard fchmod(descriptor, mode_t(0o600)) == 0, fsync(descriptor) == 0 else {
            throw AgentBridgeError.persistence("Could not sync the MCP proxy receipt.")
        }
        let renameResult = temporaryName.withCString { source in
            fileName.withCString { destination in renameat(parent, source, parent, destination) }
        }
        if renameResult != 0 || fsync(parent) != 0 {
            throw AgentBridgeError.persistence("Could not atomically publish the MCP proxy receipt.")
        }
    }

    public static func read(from url: URL) throws -> MCPProxyReceipt {
        guard url.isFileURL, let path = ActiveExtensionValidation.preservedAbsolutePath(url.path) else {
            throw AgentBridgeError.invalidInput("MCP proxy receipt path is invalid.")
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let fileName = components.last, !components.isEmpty,
              components.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw AgentBridgeError.invalidInput("MCP proxy receipt path is invalid.")
        }
        let parent = try openDirectory(Array(components.dropLast(1)))
        defer { _ = Darwin.close(parent) }
        try requirePrivateDirectory(parent)
        let descriptor = fileName.withCString { openat(parent, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        guard descriptor >= 0 else { throw AgentBridgeError.persistence("MCP proxy receipt is unavailable.") }
        defer { _ = Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              metadata.st_uid == getuid(), metadata.st_nlink == 1,
              (metadata.st_mode & 0o077) == 0,
              metadata.st_size > 0, metadata.st_size <= maximumBytes else {
            throw AgentBridgeError.persistence("MCP proxy receipt is not a bounded private regular file.")
        }
        var data = Data()
        data.reserveCapacity(Int(metadata.st_size))
        var buffer = [UInt8](repeating: 0, count: 4 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                return Darwin.read(descriptor, baseAddress, rawBuffer.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw AgentBridgeError.persistence("Could not read MCP proxy receipt.")
            }
            guard data.count + count <= maximumBytes else { throw AgentBridgeError.persistence("MCP proxy receipt exceeds its size limit.") }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count == metadata.st_size else { throw AgentBridgeError.persistence("MCP proxy receipt changed while being read.") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let receipt = try decoder.decode(MCPProxyReceipt.self, from: data)
        guard receipt.schemaVersion == 1,
              ActiveExtensionValidation.isSHA256(receipt.configurationDigest),
              (0...128).contains(receipt.toolCallCount),
              (receipt.status == .failed) == (receipt.failureCode != nil) else {
            throw AgentBridgeError.persistence("MCP proxy receipt failed integrity checks.")
        }
        return receipt
    }

    private static func openDirectory(_ components: [String]) throws -> Int32 {
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw AgentBridgeError.persistence("MCP proxy receipt path is unavailable.") }
        for component in components {
            let child = component.withCString { openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) }
            guard child >= 0 else {
                _ = Darwin.close(descriptor)
                throw AgentBridgeError.persistence("MCP proxy receipt path contains a symlink or missing directory.")
            }
            _ = Darwin.close(descriptor)
            descriptor = child
        }
        return descriptor
    }

    private static func requirePrivateDirectory(_ descriptor: Int32) throws {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              metadata.st_uid == getuid(), (metadata.st_mode & 0o077) == 0 else {
            throw AgentBridgeError.persistence("MCP proxy receipt directory must be private to the current user.")
        }
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let count = Darwin.write(descriptor, baseAddress.advanced(by: offset), rawBuffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw AgentBridgeError.persistence("Could not write MCP proxy receipt.")
                }
                guard count > 0 else { throw AgentBridgeError.persistence("MCP proxy receipt write was incomplete.") }
                offset += count
            }
        }
    }
}
