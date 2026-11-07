import Darwin
import Foundation

/// Runs verification under a macOS Seatbelt profile, because it executes code a
/// provider wrote. Paths reach the profile as `-D` parameters, so a folder name
/// cannot change the profile's meaning.
///
/// Network access stays on so a fresh checkout can fetch its dependencies. Tools
/// that start their own Seatbelt sandbox cannot run here, since macOS refuses to
/// nest them; `AGENTBRIDGE_VERIFICATION_SANDBOX=1` lets a script turn that off,
/// as `swift build --disable-sandbox` does.
struct VerificationSandbox {
    static let executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
    static let environmentMarker = "AGENTBRIDGE_VERIFICATION_SANDBOX"

    /// The checkout, its home and its temporary folder, from `makeWritableRoot`.
    let writableRoot: URL
    /// Neither these nor the user's home folder can be read or written. Other than
    /// `writableRoot`, only `/tmp` and the per-user temporary and cache folders can be
    /// written; compilers and many test suites need those.
    let protectedRoots: [URL]

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
            throw AgentBridgeError.verificationCommandRejected("macOS sandbox-exec is unavailable, so verification cannot be isolated.")
        }
        let protected = ([URL(fileURLWithPath: NSHomeDirectory())] + protectedRoots).map(Self.canonicalPath)
        let userFolders = [_CS_DARWIN_USER_TEMP_DIR, _CS_DARWIN_USER_CACHE_DIR].compactMap(Self.darwinUserDirectory)
        let executablePath = Self.canonicalPath(executable)

        var parameters = ["EXECUTABLE=\(executablePath)", "WRITABLE=\(Self.canonicalPath(writableRoot))"]
        parameters += protected.enumerated().map { "PROTECTED\($0.offset)=\($0.element)" }
        parameters += userFolders.enumerated().map { "USERFOLDER\($0.offset)=\($0.element)" }
        let profile = Self.profile(protectedCount: protected.count, userFolderCount: userFolders.count)
        return (
            Self.executableURL,
            parameters.flatMap { ["-D", $0] } + ["-p", profile, executablePath] + arguments
        )
    }

    // Seatbelt uses the last matching rule, so each `allow` narrows the `deny` above it.
    private static func profile(protectedCount: Int, userFolderCount: Int) -> String {
        let protected = (0..<protectedCount).map { "(subpath (param \"PROTECTED\($0)\"))" }.joined(separator: " ")
        let userFolders = (0..<userFolderCount).map { "(subpath (param \"USERFOLDER\($0)\"))" }.joined(separator: " ")
        return """
        (version 1)
        (allow default)
        (deny file-read-data file-read-xattr \(protected))
        (allow file-read-data file-read-xattr (subpath (param "WRITABLE")) (literal (param "EXECUTABLE")))
        (deny file-write*)
        (allow file-write* \(userFolders) (subpath "/private/tmp")
            (literal "/dev/null") (literal "/dev/zero") (literal "/dev/tty")
            (literal "/dev/dtracehelper") (subpath "/dev/fd"))
        (deny file-write* \(protected))
        (allow file-write* (subpath (param "WRITABLE")))
        (deny appleevent-send)
        (deny signal)
        (allow signal (target same-sandbox))
        (deny process-exec (literal "/bin/launchctl") (literal "/usr/bin/open")
            (literal "/usr/bin/osascript") (literal "/usr/bin/security"))
        (deny mach-lookup (global-name "com.apple.SecurityServer")
            (global-name "com.apple.securityd.xpc")
            (global-name "com.apple.coreservices.launchservicesd")
            (global-name "com.apple.coreservices.quarantine-resolver"))
        """
    }

    /// Seatbelt compares real paths, so `/var/...` would not match `/private/var/...`.
    private static func canonicalPath(_ url: URL) -> String {
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
