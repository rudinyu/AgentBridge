import Darwin
import Foundation

/// Private control-plane storage for one provider invocation's MCP tickets,
/// receipts, and proxy homes. It lives outside the provider workspace and its
/// temporary directory so model-controlled tools cannot forge proxy evidence.
final class MCPRunDirectoryLease {
    let directoryURL: URL

    private let lock = NSLock()
    private var removed = false

    init(applicationSupportRoot: URL, providerWriteRoots: [URL]) throws {
        guard applicationSupportRoot.isFileURL,
              let supportPath = ActiveExtensionValidation.preservedAbsolutePath(applicationSupportRoot.path) else {
            throw AgentBridgeError.persistence("The MCP control-plane root is invalid.")
        }
        guard let canonicalSupportPath = Self.resolvedPath(supportPath) else {
            throw AgentBridgeError.persistence("The MCP control-plane root is unavailable.")
        }
        let root = URL(fileURLWithPath: canonicalSupportPath, isDirectory: true)
            .appendingPathComponent("mcp-runs", isDirectory: true)
        let candidate = root.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)

        for writeRoot in providerWriteRoots {
            guard writeRoot.isFileURL,
                  let writeRootPath = ActiveExtensionValidation.preservedAbsolutePath(writeRoot.path),
                  let canonicalWriteRoot = Self.resolvedPath(writeRootPath),
                  !Self.pathsOverlap(candidate.path, canonicalWriteRoot) else {
                throw AgentBridgeError.persistence("MCP control-plane files must be outside provider-writable paths.")
            }
        }

        try AuditStore.createPrivateDirectory(root)
        guard mkdir(candidate.path, mode_t(0o700)) == 0 else {
            throw AgentBridgeError.persistence("Could not create the private MCP control-plane directory.")
        }
        let descriptor = candidate.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            _ = rmdir(candidate.path)
            throw AgentBridgeError.persistence("The private MCP control-plane directory is unavailable.")
        }
        defer { _ = Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              metadata.st_uid == getuid(),
              fchmod(descriptor, mode_t(0o700)) == 0 else {
            _ = rmdir(candidate.path)
            throw AgentBridgeError.persistence("The MCP control-plane directory failed access checks.")
        }
        self.directoryURL = candidate
    }

    func remove() {
        lock.lock()
        defer { lock.unlock() }
        guard !removed else { return }
        removed = true
        var metadata = stat()
        guard lstat(directoryURL.path, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              metadata.st_uid == getuid() else { return }
        try? FileManager.default.removeItem(at: directoryURL)
    }

    deinit {
        remove()
    }

    private static func pathsOverlap(_ lhs: String, _ rhs: String) -> Bool {
        contains(lhs, within: rhs) || contains(rhs, within: lhs)
    }

    private static func resolvedPath(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard path.withCString({ realpath($0, &buffer) }) != nil else { return nil }
        return String(cString: buffer)
    }

    private static func contains(_ path: String, within parent: String) -> Bool {
        path == parent || path.hasPrefix(parent.hasSuffix("/") ? parent : parent + "/")
    }
}
