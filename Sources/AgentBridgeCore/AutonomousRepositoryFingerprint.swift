import CryptoKit
import Darwin
import Foundation

public struct AutonomousRepositoryFingerprint: Codable, Equatable, Sendable {
    public let sourceRepositoryPath: String
    public let headCommit: String
    public let statusDigest: String
    public let trackedDiffDigest: String
    public let untrackedPathsDigest: String
    public let untrackedContentDigest: String
    public let overallDigest: String

    public init(
        sourceRepositoryPath: String,
        headCommit: String,
        statusDigest: String,
        trackedDiffDigest: String,
        untrackedPathsDigest: String,
        untrackedContentDigest: String = String(repeating: "0", count: 64)
    ) {
        self.sourceRepositoryPath = sourceRepositoryPath
        self.headCommit = headCommit
        self.statusDigest = statusDigest
        self.trackedDiffDigest = trackedDiffDigest
        self.untrackedPathsDigest = untrackedPathsDigest
        self.untrackedContentDigest = untrackedContentDigest
        let payload = [sourceRepositoryPath, headCommit, statusDigest, trackedDiffDigest, untrackedPathsDigest, untrackedContentDigest]
            .map { "\($0.utf8.count):\($0)" }.joined()
        self.overallDigest = SHA256.hash(data: Data(payload.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public var isIntact: Bool {
        let payload = [sourceRepositoryPath, headCommit, statusDigest, trackedDiffDigest, untrackedPathsDigest, untrackedContentDigest]
            .map { "\($0.utf8.count):\($0)" }.joined()
        let digest = SHA256.hash(data: Data(payload.utf8)).map { String(format: "%02x", $0) }.joined()
        return overallDigest == digest
            && sourceRepositoryPath.hasPrefix("/")
            && (40...64).contains(headCommit.utf8.count)
            && [statusDigest, trackedDiffDigest, untrackedPathsDigest, untrackedContentDigest].allSatisfy(Self.isSHA256)
    }

    /// Captures Git state without modifying the source tree. Untracked files are
    /// hashed by content as well as path, so a desktop action cannot quietly
    /// replace a file while leaving its status marker unchanged.
    public static func capture(sourceRepositoryPath: String) async throws -> AutonomousRepositoryFingerprint {
        let normalizedPath = URL(fileURLWithPath: sourceRepositoryPath, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
        var rootMetadata = stat()
        guard sourceRepositoryPath.hasPrefix("/"), !sourceRepositoryPath.contains("\0"),
              lstat(normalizedPath, &rootMetadata) == 0,
              (rootMetadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else {
            throw AutonomousOrchestrationError.blocked("The source repository could not be safely fingerprinted.")
        }
        let gitURL = URL(fileURLWithPath: "/usr/bin/git")
        let runner = SafeProcessRunner()
        let environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": "/",
            "LANG": "C",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_SYSTEM": "/dev/null",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_OPTIONAL_LOCKS": "0",
            "GIT_NO_REPLACE_OBJECTS": "1",
            "GIT_ATTR_NOSYSTEM": "1"
        ]
        func git(_ command: [String], outputLimit: Int) async throws -> Data {
            let result = try await runner.run(ProcessSpec(
                executableURL: gitURL,
                arguments: [
                    "-c", "core.fsmonitor=false",
                    "-c", "core.hooksPath=/dev/null",
                    "-c", "core.untrackedCache=false",
                    "--literal-pathspecs",
                    "-C", normalizedPath
                ] + command,
                environment: environment,
                timeout: 30,
                outputLimit: outputLimit
            ))
            guard result.exitCode == 0, !result.timedOut, !result.wasCancelled, !result.outputWasTruncated else {
                throw AutonomousOrchestrationError.blocked("The source repository changed or exceeded a safe fingerprint limit.")
            }
            return result.standardOutput
        }

        let headData = try await git(["rev-parse", "--verify", "HEAD"], outputLimit: 256)
        guard let head = String(data: headData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              (40...64).contains(head.utf8.count),
              head.utf8.allSatisfy({
                  ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 70) || ($0 >= 97 && $0 <= 102)
              }) else {
            throw AutonomousOrchestrationError.blocked("The source repository has no valid HEAD commit.")
        }
        let status = try await git(["status", "--porcelain=v1", "-z", "--untracked-files=all"], outputLimit: 16 * 1_024 * 1_024)
        let trackedDiff = try await git([
            "diff", "--no-ext-diff", "--no-textconv", "--no-color", "--binary", "HEAD", "--"
        ], outputLimit: 64 * 1_024 * 1_024)
        let untrackedPaths = try await git(["ls-files", "--others", "--exclude-standard", "-z"], outputLimit: 16 * 1_024 * 1_024)
        let contentDigest = try untrackedContentDigest(at: normalizedPath, pathsData: untrackedPaths)
        return AutonomousRepositoryFingerprint(
            sourceRepositoryPath: normalizedPath,
            headCommit: head.lowercased(),
            statusDigest: sha256(status),
            trackedDiffDigest: sha256(trackedDiff),
            untrackedPathsDigest: sha256(untrackedPaths),
            untrackedContentDigest: contentDigest
        )
    }

    private static func untrackedContentDigest(at repositoryPath: String, pathsData: Data) throws -> String {
        let entries = pathsData.split(separator: 0, omittingEmptySubsequences: true)
        guard entries.count <= 10_000 else {
            throw AutonomousOrchestrationError.blocked("The source repository contains too many untracked paths to fingerprint safely.")
        }
        let rootDescriptor = repositoryPath.withCString { open($0, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW) }
        guard rootDescriptor >= 0 else {
            throw AutonomousOrchestrationError.blocked("The source repository directory could not be opened safely.")
        }
        defer { _ = close(rootDescriptor) }

        var aggregate = SHA256()
        var totalBytes = 0
        for entry in entries {
            guard let path = String(data: Data(entry), encoding: .utf8),
                  !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else {
                throw AutonomousOrchestrationError.blocked("An untracked source path could not be fingerprinted safely.")
            }
            let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard !components.isEmpty,
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                throw AutonomousOrchestrationError.blocked("An untracked source path contains an unsafe component.")
            }
            var parentDescriptor = dup(rootDescriptor)
            guard parentDescriptor >= 0 else {
                throw AutonomousOrchestrationError.blocked("The source repository directory could not be duplicated safely.")
            }
            for component in components.dropLast() {
                let nextDescriptor = component.withCString { openat(parentDescriptor, $0, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW) }
                _ = close(parentDescriptor)
                guard nextDescriptor >= 0 else {
                    throw AutonomousOrchestrationError.blocked("An untracked source path escaped or changed during fingerprinting.")
                }
                parentDescriptor = nextDescriptor
            }
            defer { _ = close(parentDescriptor) }
            let leaf = components[components.count - 1]
            var metadata = stat()
            let statResult = leaf.withCString { fstatat(parentDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW) }
            guard statResult == 0 else {
                throw AutonomousOrchestrationError.blocked("An untracked source path changed during fingerprinting.")
            }
            var fileDigest = SHA256()
            if (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) {
                let descriptor = leaf.withCString { openat(parentDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
                guard descriptor >= 0 else {
                    throw AutonomousOrchestrationError.blocked("An untracked source file could not be opened safely.")
                }
                defer { _ = close(descriptor) }
                var opened = stat()
                guard fstat(descriptor, &opened) == 0,
                      (opened.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                      opened.st_dev == metadata.st_dev, opened.st_ino == metadata.st_ino else {
                    throw AutonomousOrchestrationError.blocked("An untracked source file changed while it was being opened.")
                }
                var buffer = [UInt8](repeating: 0, count: 32 * 1_024)
                while true {
                    let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                    if count == 0 { break }
                    if count < 0 {
                        if errno == EINTR { continue }
                        throw AutonomousOrchestrationError.blocked("An untracked source file could not be read safely.")
                    }
                    totalBytes += count
                    guard totalBytes <= 64 * 1_024 * 1_024 else {
                        throw AutonomousOrchestrationError.blocked("Untracked source files exceed the fingerprint size limit.")
                    }
                    fileDigest.update(data: Data(buffer.prefix(count)))
                }
                var finalMetadata = stat()
                guard fstat(descriptor, &finalMetadata) == 0,
                      finalMetadata.st_dev == opened.st_dev,
                      finalMetadata.st_ino == opened.st_ino,
                      finalMetadata.st_size == opened.st_size else {
                    throw AutonomousOrchestrationError.blocked("An untracked source file changed while it was being fingerprinted.")
                }
            } else if (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK) {
                var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX))
                let count = leaf.withCString { name in
                    buffer.withUnsafeMutableBufferPointer { readlinkat(parentDescriptor, name, $0.baseAddress, $0.count) }
                }
                guard count >= 0, count < buffer.count else {
                    throw AutonomousOrchestrationError.blocked("An untracked source symlink could not be fingerprinted safely.")
                }
                totalBytes += count
                guard totalBytes <= 64 * 1_024 * 1_024 else {
                    throw AutonomousOrchestrationError.blocked("Untracked source files exceed the fingerprint size limit.")
                }
                fileDigest.update(data: Data(buffer.prefix(count)))
            } else {
                throw AutonomousOrchestrationError.blocked("An untracked source path is not a regular file or symlink.")
            }
            let fileHash = fileDigest.finalize().map { String(format: "%02x", $0) }.joined()
            let item = "\(path.utf8.count):\(path):\(fileHash)"
            aggregate.update(data: Data(item.utf8))
        }
        return aggregate.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }
}
