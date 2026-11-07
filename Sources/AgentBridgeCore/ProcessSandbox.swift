import Darwin
import Foundation

/// Runs a process under a macOS Seatbelt profile. Paths reach the profile as `-D`
/// parameters, so a folder name cannot change the profile's meaning.
///
/// The home folder and `protectedRoots` cannot be read or written. Besides the
/// listed roots, only `/tmp` and the per-user temporary and cache folders can be
/// written; compilers and many test suites need those. Network access stays on.
/// macOS refuses a nested sandbox, so a sandboxed program cannot start its own.
struct ProcessSandbox {
    static let executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
    /// Set for verification, so a script can turn off a tool's own sandbox, as
    /// `swift build --disable-sandbox` does.
    static let verificationMarker = "AGENTBRIDGE_VERIFICATION_SANDBOX"

    /// Readable and writable even inside `protectedRoots`.
    var writableRoots: [URL]
    var protectedRoots: [URL]
    /// Like `writableRoots`, for a file and the siblings that begin with its name,
    /// such as the temporary files an atomic save writes beside it.
    var writablePrefixes: [URL] = []
    /// Readable even inside `protectedRoots`.
    var readableRoots: [URL] = []
    /// Read-only even inside `writableRoots`.
    var readOnlyRoots: [URL] = []
    /// Whether the Keychain can be reached, for a CLI that keeps its sign-in there.
    /// Claude Code reads it by running `/usr/bin/security`, so that stays allowed
    /// too. Item access is still limited by each item's own access list.
    var allowsKeychain = false

    /// Lives in the per-user temporary folder and not under the private data root,
    /// because a program that opens each parent folder in turn would be refused at
    /// the protected ones. macOS clears anything a crash leaves behind.
    static func makeWritableRoot(label: String) throws -> URL {
        guard let temporary = darwinUserDirectory(_CS_DARWIN_USER_TEMP_DIR) else {
            throw AgentBridgeError.persistence("Could not find the macOS temporary folder for verification.")
        }
        let url = URL(fileURLWithPath: temporary, isDirectory: true)
            .appendingPathComponent("AgentBridge-\(label)-\(UUID().uuidString.lowercased())", isDirectory: true)
        guard mkdir(url.path, mode_t(0o700)) == 0 else {
            throw AgentBridgeError.persistence("Could not create the macOS temporary folder for verification.")
        }
        return url
    }

    func command(executable: URL, arguments: [String]) throws -> (executable: URL, arguments: [String]) {
        guard FileManager.default.isExecutableFile(atPath: Self.executableURL.path) else {
            throw AgentBridgeError.verificationCommandRejected("macOS sandbox-exec is unavailable, so the process cannot be isolated.")
        }
        let groups: [(name: String, paths: [String])] = [
            ("PROTECTED", ([URL(fileURLWithPath: NSHomeDirectory())] + protectedRoots).map(Self.canonicalPath)),
            ("WRITABLE", writableRoots.map(Self.canonicalPath)),
            ("PREFIX", writablePrefixes.map(Self.canonicalPath)),
            ("READABLE", readableRoots.map(Self.canonicalPath)),
            ("READONLY", readOnlyRoots.map(Self.canonicalPath)),
            ("USERFOLDER", [_CS_DARWIN_USER_TEMP_DIR, _CS_DARWIN_USER_CACHE_DIR].compactMap(Self.darwinUserDirectory))
        ]
        let executablePath = Self.canonicalPath(executable)
        var parameters = ["EXECUTABLE=\(executablePath)"]
        var filters: [String: String] = [:]
        for group in groups {
            parameters += group.paths.enumerated().map { "\(group.name)\($0.offset)=\($0.element)" }
            let filter = group.name == "PREFIX" ? "prefix" : "subpath"
            filters[group.name] = group.paths.indices.map { "(\(filter) (param \"\(group.name)\($0)\"))" }.joined(separator: " ")
        }
        return (
            Self.executableURL,
            parameters.flatMap { ["-D", $0] } + ["-p", Self.profile(filters, allowsKeychain: allowsKeychain), executablePath] + arguments
        )
    }

    // Seatbelt uses the last matching rule, so each rule narrows the ones above it.
    private static func profile(_ filters: [String: String], allowsKeychain: Bool) -> String {
        let readOnly = filters["READONLY", default: ""]
        let keychainServices = allowsKeychain ? "" : """
            (global-name "com.apple.SecurityServer") (global-name "com.apple.securityd.xpc")
            """
        let keychainTool = allowsKeychain ? "" : #"(literal "/usr/bin/security")"#
        return """
        (version 1)
        (allow default)
        (deny file-read-data file-read-xattr \(filters["PROTECTED", default: ""]))
        (allow file-read-data file-read-xattr \(filters["WRITABLE", default: ""]) \(filters["PREFIX", default: ""])
            \(filters["READABLE", default: ""]) (literal (param "EXECUTABLE")))
        (deny file-write*)
        (allow file-write* \(filters["USERFOLDER", default: ""]) (subpath "/private/tmp")
            (literal "/dev/null") (literal "/dev/zero") (literal "/dev/tty")
            (literal "/dev/dtracehelper") (subpath "/dev/fd"))
        (deny file-write* \(filters["PROTECTED", default: ""]))
        (allow file-write* \(filters["WRITABLE", default: ""]) \(filters["PREFIX", default: ""]))
        \(readOnly.isEmpty ? "" : "(deny file-write* \(readOnly))")
        (deny appleevent-send)
        (deny signal)
        (allow signal (target same-sandbox))
        (deny process-exec (literal "/bin/launchctl") (literal "/usr/bin/open")
            (literal "/usr/bin/osascript") \(keychainTool))
        (deny mach-lookup \(keychainServices)
            (global-name "com.apple.coreservices.launchservicesd")
            (global-name "com.apple.coreservices.quarantine-resolver"))
        """
    }

    /// Seatbelt compares real paths, so `/var/...` would not match `/private/var/...`.
    static func canonicalPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func darwinUserDirectory(_ name: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(name, &buffer, buffer.count) > 0 else { return nil }
        return canonicalPath(URL(fileURLWithPath: String(cString: buffer), isDirectory: true))
    }
}
