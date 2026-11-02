import CryptoKit
import Darwin
import Foundation

/// A bounded content pin for a script interpreted as the MCP entrypoint. It
/// does not pin modules, packages, dynamic libraries, or other transitive code.
public struct MCPEntrypointPin: Codable, Equatable, Sendable {
    public let path: String
    public let digest: String

    init(path: String, digest: String) throws {
        guard let preservedPath = ActiveExtensionValidation.preservedAbsolutePath(path),
              ActiveExtensionValidation.isSHA256(digest) else {
            throw AgentBridgeError.invalidInput("MCP entrypoint pin is invalid.")
        }
        self.path = preservedPath
        self.digest = digest.lowercased()
    }

    private enum CodingKeys: String, CodingKey { case path, digest }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(path: container.decode(String.self, forKey: .path), digest: container.decode(String.self, forKey: .digest))
        } catch {
            throw DecodingError.dataCorruptedError(forKey: .path, in: container, debugDescription: "MCP entrypoint pin is invalid.")
        }
    }
}

enum MCPEntrypointIntegrity {
    static let maximumScriptBytes: off_t = 16 * 1_024 * 1_024

    private enum Interpreter {
        case python
        case node
        case ruby
        case perl
        case php
        case shell
    }

    static func pins(commandPath: String, arguments: [String]) throws -> [MCPEntrypointPin] {
        let executableName = URL(fileURLWithPath: commandPath).lastPathComponent.lowercased()
        // `env` can dispatch a second interpreter whose script would otherwise
        // be invisible to the direct-command entrypoint pinning below. Require
        // imports to name that installed executable directly instead.
        guard executableName != "env" else {
            throw ActiveExtensionRuntimeError.invalidConfiguration("MCP commands must name the installed executable directly; env wrappers are not accepted.")
        }
        guard let interpreter = interpreter(for: executableName) else { return [] }
        if arguments.contains(where: { inlineOrModuleFlag($0, interpreter: interpreter) }) { return [] }

        var skipNext = false
        var candidate: String?
        for argument in arguments {
            if skipNext { skipNext = false; continue }
            if argument.isEmpty { continue }
            if argument == "-X" || argument == "-W" || argument == "-I" || argument == "-r" || argument == "-M" || argument == "-d" || argument == "-c" {
                skipNext = true
                continue
            }
            if argument == "--loader" || argument == "--import" || argument == "--require" || argument == "--check-hash-based-pycs" {
                skipNext = true
                continue
            }
            if argument.hasPrefix("-") { continue }
            candidate = argument
            break
        }
        guard let candidate else {
            throw ActiveExtensionRuntimeError.invalidConfiguration("Interpreter-based MCP commands must name a script or use an explicit inline/module mode.")
        }
        guard candidate.hasPrefix("/") else {
            throw ActiveExtensionRuntimeError.invalidConfiguration("Interpreter MCP entrypoint scripts must use an absolute path so their content can be pinned.")
        }
        let result = try digestScript(at: candidate)
        return [try MCPEntrypointPin(path: result.path, digest: result.digest)]
    }

    static func validate(_ pins: [MCPEntrypointPin], workspacePath: String) throws {
        guard let workspace = ActiveExtensionValidation.preservedAbsolutePath(workspacePath) else {
            throw ActiveExtensionRuntimeError.invalidConfiguration("Session workspace path is invalid.")
        }
        let canonicalWorkspace = canonicalExistingPath(workspace)
        for pin in pins {
            let path = pin.path
            let canonicalPin = canonicalExistingPath(path)
            guard canonicalPin != canonicalWorkspace,
                  !canonicalPin.hasPrefix(canonicalWorkspace.hasSuffix("/") ? canonicalWorkspace : canonicalWorkspace + "/") else {
                throw ActiveExtensionRuntimeError.invalidConfiguration("MCP entrypoint scripts inside the session workspace are not allowed.")
            }
            guard try digestScript(at: path).digest == pin.digest else {
                throw ActiveExtensionRuntimeError.invalidConfiguration("An MCP entrypoint script changed after import and review.")
            }
        }
    }

    private static func interpreter(for executableName: String) -> Interpreter? {
        let name = executableName.lowercased()
        if name == "python" || name == "python3" || name.range(of: #"^python3\.[0-9]+$"#, options: .regularExpression) != nil || name == "pypy" || name == "pypy3" {
            return .python
        }
        if ["node", "nodejs", "bun", "deno"].contains(name) { return .node }
        if name == "ruby" { return .ruby }
        if name == "perl" { return .perl }
        if name == "php" { return .php }
        if ["sh", "bash", "dash", "zsh", "fish", "ksh", "mksh", "csh", "tcsh"].contains(name) { return .shell }
        return nil
    }

    private static func inlineOrModuleFlag(_ argument: String, interpreter: Interpreter) -> Bool {
        return switch interpreter {
        case .python: ["-c", "-m", "--command", "--module"].contains(argument)
        case .node: ["-e", "-p", "--eval", "--print", "--input-type"].contains(argument)
        case .ruby: ["-e", "--eval"].contains(argument)
        case .perl: ["-e"].contains(argument)
        case .php: ["-r"].contains(argument)
        case .shell: ["-c", "-lc", "-cl", "-ec", "-ce", "--command"].contains(argument)
        }
    }

    private static func digestScript(at path: String) throws -> (path: String, digest: String) {
        guard let preservedPath = ActiveExtensionValidation.preservedAbsolutePath(path) else {
            throw ActiveExtensionRuntimeError.invalidConfiguration("MCP script path must be absolute and valid.")
        }
        let components = preservedPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let fileName = components.last, !components.isEmpty,
              components.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw ActiveExtensionRuntimeError.invalidConfiguration("MCP script path is invalid.")
        }
        var directory = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directory >= 0 else { throw invalidScript() }
        defer { _ = Darwin.close(directory) }
        for component in components.dropLast() {
            let child = component.withCString { openat(directory, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) }
            guard child >= 0 else { throw invalidScript() }
            _ = Darwin.close(directory)
            directory = child
        }
        let descriptor = fileName.withCString { openat(directory, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
        guard descriptor >= 0 else { throw invalidScript() }
        defer { _ = Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              (before.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              before.st_size > 0, before.st_size <= maximumScriptBytes else { throw invalidScript() }

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        var total: off_t = 0
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                return Darwin.read(descriptor, baseAddress, rawBuffer.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw invalidScript()
            }
            if count == 0 { break }
            total += off_t(count)
            guard total <= maximumScriptBytes else { throw invalidScript() }
            hasher.update(data: Data(buffer.prefix(count)))
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              total == after.st_size else { throw invalidScript() }
        return (preservedPath, hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private static func canonicalExistingPath(_ path: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard path.withCString({ realpath($0, &buffer) }) != nil else { return path }
        return String(cString: buffer)
    }

    private static func invalidScript() -> ActiveExtensionRuntimeError {
        .invalidConfiguration("MCP entrypoint must be a bounded regular file with no symlink path components.")
    }
}
