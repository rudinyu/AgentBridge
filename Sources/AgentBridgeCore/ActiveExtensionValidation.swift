import CryptoKit
import Darwin
import Foundation

enum ActiveExtensionValidation {
    static func identifier(_ value: String, label: String) throws -> String {
        guard isIdentifier(value) else { throw AgentBridgeError.invalidInput("The \(label) is invalid.") }
        return value
    }

    static func isIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= 160,
              isAlphanumeric(bytes[0]),
              bytes.allSatisfy({ isAlphanumeric($0) || [45, 46, 95, 58].contains($0) }),
              value != ".", value != ".." else { return false }
        return true
    }

    static func text(_ value: String, label: String, maximumBytes: Int, allowEmpty: Bool) throws -> String {
        guard value.utf8.count <= maximumBytes,
              allowEmpty || !value.isEmpty,
              !value.contains("\0"),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw AgentBridgeError.invalidInput("The \(label) is invalid or exceeds its size limit.")
        }
        return value
    }

    static func skillText(_ value: String, maximumBytes: Int) throws -> String {
        guard !value.isEmpty, value.utf8.count <= maximumBytes, !value.contains("\0"),
              !value.unicodeScalars.contains(where: { scalar in
                  CharacterSet.controlCharacters.contains(scalar) && scalar != "\n" && scalar != "\r" && scalar != "\t"
              }) else {
            throw AgentBridgeError.invalidInput("Skill instructions are empty, contain unsupported control characters, or exceed 64 KiB.")
        }
        return value
    }

    static func arguments(_ values: [String]) throws -> [String] {
        guard values.count <= 64,
              values.allSatisfy({ $0.utf8.count <= 4_096 && !$0.contains("\0") }),
              values.reduce(0, { $0 + $1.utf8.count }) <= 32_768 else {
            throw AgentBridgeError.invalidInput("MCP argv must contain at most 64 arguments and 32 KiB total without NUL bytes.")
        }
        return values
    }

    static func toolNames(_ values: [String]) throws -> [String] {
        guard !values.isEmpty, values.count <= 128, Set(values).count == values.count,
              values.allSatisfy(isToolName) else {
            throw AgentBridgeError.invalidInput("MCP tools require a unique, nonempty exact allowlist without wildcards or control characters.")
        }
        return values.sorted()
    }

    static func isToolName(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...128).contains(bytes.count), isAlphanumeric(bytes[0]) else { return false }
        return bytes.allSatisfy { isAlphanumeric($0) || [45, 46, 95, 58].contains($0) }
    }

    static func absoluteExecutablePath(_ value: String) throws -> String {
        guard let path = preservedAbsolutePath(value) else {
            throw AgentBridgeError.invalidInput("MCP command must be an absolute installed executable path.")
        }
        return path
    }

    /// Preserve `/private/var/...` spellings. Foundation can rewrite them to
    /// `/var/...`, which is a symlink and fails the no-follow file readers.
    static func preservedAbsolutePath(_ value: String) -> String? {
        guard value.hasPrefix("/"), !value.hasPrefix("//"), !value.contains("\0"), value.utf8.count <= 4_096,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        let components = value.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty, components.allSatisfy({ $0 != "." && $0 != ".." }) else { return nil }
        return value
    }

    static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }
}

enum ActiveSkillFileReader {
    static func read(at url: URL) throws -> String {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0") else {
            throw AgentBridgeError.invalidInput("Select an absolute local SKILL.md file.")
        }
        guard let path = ActiveExtensionValidation.preservedAbsolutePath(url.path) else { throw invalidFile() }
        let pathComponents = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard pathComponents.count >= 2, pathComponents.last == "SKILL.md",
              pathComponents.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw AgentBridgeError.invalidInput("Skill import requires a regular file named SKILL.md.")
        }

        var directory = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directory >= 0 else { throw invalidFile() }
        defer { _ = close(directory) }

        for component in pathComponents.dropLast() {
            let child = component.withCString { openat(directory, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) }
            guard child >= 0 else { throw invalidFile() }
            _ = close(directory)
            directory = child
        }

        var before = stat()
        guard "SKILL.md".withCString({ fstatat(directory, $0, &before, AT_SYMLINK_NOFOLLOW) }) == 0,
              (before.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              before.st_size >= 0,
              before.st_size <= off_t(ActiveSkillSnapshot.maximumContentBytes) else {
            throw invalidFile()
        }
        let descriptor = "SKILL.md".withCString {
            openat(directory, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else { throw invalidFile() }
        defer { _ = close(descriptor) }

        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              (opened.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              sameFile(before, opened),
              opened.st_size >= 0,
              opened.st_size <= off_t(ActiveSkillSnapshot.maximumContentBytes) else {
            throw invalidFile()
        }

        var data = Data()
        data.reserveCapacity(Int(opened.st_size))
        var buffer = [UInt8](repeating: 0, count: 8 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                return Darwin.read(descriptor, baseAddress, min(rawBuffer.count, ActiveSkillSnapshot.maximumContentBytes - data.count + 1))
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw invalidFile()
            }
            if count == 0 { break }
            guard data.count + count <= ActiveSkillSnapshot.maximumContentBytes else {
                throw AgentBridgeError.invalidInput("SKILL.md must be 64 KiB or smaller.")
            }
            data.append(contentsOf: buffer.prefix(count))
        }

        var after = stat()
        guard fstat(descriptor, &after) == 0,
              (after.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              sameFile(opened, after),
              after.st_size == off_t(data.count) else {
            throw AgentBridgeError.invalidInput("SKILL.md changed while it was being imported.")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw AgentBridgeError.invalidInput("SKILL.md must contain valid UTF-8 text.")
        }
        return try ActiveExtensionValidation.skillText(text, maximumBytes: ActiveSkillSnapshot.maximumContentBytes)
    }

    private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func invalidFile() -> AgentBridgeError {
        .invalidInput("SKILL.md must be a bounded regular file with no symlink in its path.")
    }
}
