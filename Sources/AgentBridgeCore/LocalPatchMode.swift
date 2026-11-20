import Darwin
import Foundation

/// A tracked or non-ignored untracked file that can be offered in the Local
/// patch picker. Unsafe and oversized paths remain visible but are disabled.
public struct LocalChangeFileCandidate: Equatable, Identifiable, Sendable {
    public let path: String
    public let byteCount: Int?
    public let isSelectable: Bool

    public var id: String { path }

    public init(path: String, byteCount: Int?, isSelectable: Bool) {
        self.path = path
        self.byteCount = byteCount
        self.isSelectable = isSelectable
    }
}

public struct LocalChangeInputFileSize: Equatable, Sendable {
    public let path: String
    public let byteCount: Int

    public init(path: String, byteCount: Int) {
        self.path = path
        self.byteCount = byteCount
    }
}

/// Byte accounting for the exact request prompt. The input budget follows
/// Local's context window less the output reserve and 512-token safety margin.
///
/// The model returns complete file contents, so the output reserve must also fit
/// every selected file (any of them may be rewritten in full) plus the JSON
/// wrapper and summary. Bytes are counted as tokens, the same conservative rule
/// as the input budget.
public struct LocalChangeInputPreview: Equatable, Sendable {
    /// Room for the summary and the JSON object around the file entries.
    public static let outputResponseAllowanceBytes = 512
    /// Room for one file entry's keys, path and punctuation, besides its path.
    public static let outputFileEntryAllowanceBytes = 48

    public let files: [LocalChangeInputFileSize]
    public let totalInputBytes: Int
    public let budgetBytes: Int
    /// Bytes the model may need to return: the selected files in full, an
    /// entry for each allowed new path, and a fixed response allowance.
    public let estimatedOutputBytes: Int
    /// The output reserve in bytes (`maxOutputTokens`, bytes counted as tokens).
    public let outputBudgetBytes: Int
    /// Changed files a fix round left out because they cannot be sent (binary,
    /// over 256 KiB, ignored or otherwise not a selectable candidate). The model
    /// cannot modify them in that round.
    public let skippedChangedPaths: [String]

    public var fitsBudget: Bool { totalInputBytes <= budgetBytes }
    public var overBudgetBytes: Int { max(0, totalInputBytes - budgetBytes) }
    public var fitsOutputBudget: Bool { estimatedOutputBytes <= outputBudgetBytes }
    public var overOutputBudgetBytes: Int { max(0, estimatedOutputBytes - outputBudgetBytes) }
    /// Both the input and the output reserve fit, so a run may be sent.
    public var fitsAllBudgets: Bool { fitsBudget && fitsOutputBudget }

    public init(
        files: [LocalChangeInputFileSize],
        totalInputBytes: Int,
        budgetBytes: Int,
        estimatedOutputBytes: Int,
        outputBudgetBytes: Int,
        skippedChangedPaths: [String] = []
    ) {
        self.files = files
        self.totalInputBytes = totalInputBytes
        self.budgetBytes = budgetBytes
        self.estimatedOutputBytes = estimatedOutputBytes
        self.outputBudgetBytes = outputBudgetBytes
        self.skippedChangedPaths = skippedChangedPaths
    }

    /// The output the model may need when it rewrites every selected file and
    /// creates every allowed new path (new file contents are not known ahead).
    public static func estimatedOutputBytes(files: [LocalChangeInputFileSize], newFilePaths: [String]) -> Int {
        let selected = files.reduce(0) { $0 + $1.byteCount + $1.path.utf8.count + outputFileEntryAllowanceBytes }
        let created = newFilePaths.reduce(0) { $0 + $1.utf8.count + outputFileEntryAllowanceBytes }
        return outputResponseAllowanceBytes + selected + created
    }
}

public struct LocalChangeRunResult: Equatable, Sendable {
    public let summary: String
    public let changedPaths: [String]
    public let inputBytes: Int
    public let outputBytes: Int
    /// Changed files a fix round could not send; see `LocalChangeInputPreview`.
    public let skippedChangedPaths: [String]

    public init(summary: String, changedPaths: [String], inputBytes: Int, outputBytes: Int, skippedChangedPaths: [String] = []) {
        self.summary = summary
        self.changedPaths = changedPaths
        self.inputBytes = inputBytes
        self.outputBytes = outputBytes
        self.skippedChangedPaths = skippedChangedPaths
    }
}

struct LocalPatchFileOutput: Equatable, Sendable {
    enum Action: String, Sendable { case modify, create, delete }
    let path: String
    let action: Action
    let content: String?
}

struct LocalPatchResponse: Equatable, Sendable {
    let summary: String
    let files: [LocalPatchFileOutput]
}

enum LocalPatchApplicationError: Error, LocalizedError, Equatable {
    case rejectedPaths([String])
    case writeFailed(rollbackFailed: Bool)

    var errorDescription: String? {
        switch self {
        case .rejectedPaths(let paths):
            return "The Local model response contains paths that were not selected or allowed: %@. Nothing was written.".replacingOccurrences(of: "%@", with: paths.sorted().joined(separator: ", "))
        case .writeFailed(false):
            return "Could not safely update Local model files; the workspace was restored to its previous state."
        case .writeFailed(true):
            return "Could not safely update Local model files; the workspace rollback also failed. Inspect and restore the isolated workspace before continuing."
        }
    }
}

enum LocalPatchResponseParser {
    static let maximumResponseBytes = LocalModelClient.maximumResponseBytes
    static let maximumFileBytes = 256 * 1_024
    static let maximumTotalFileBytes = 1 * 1_024 * 1_024
    static let maximumFiles = 200

    static func parse(_ text: String) throws -> LocalPatchResponse {
        let responseBytes = text.utf8.count
        guard responseBytes <= maximumResponseBytes,
              let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else {
            throw AgentBridgeError.invalidInput("The Local model response is not one strict JSON object matching the required schema. Nothing was written.")
        }
        guard StrictJSONDuplicateKeyScanner.hasUniqueObjectKeys(text),
              let object = root as? [String: Any],
              Set(object.keys) == Set(["summary", "files"]),
              let summary = object["summary"] as? String,
              !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              summary.utf8.count <= 8_192,
              !summary.contains("\0"),
              let rawFiles = object["files"] as? [[String: Any]],
              rawFiles.count <= maximumFiles else {
            throw AgentBridgeError.invalidInput("The Local model response is not one strict JSON object matching the required schema. Nothing was written.")
        }

        var files: [LocalPatchFileOutput] = []
        var seenPaths = Set<String>()
        var totalBytes = 0
        for entry in rawFiles {
            guard let path = entry["path"] as? String,
                  let actionText = entry["action"] as? String,
                  let action = LocalPatchFileOutput.Action(rawValue: actionText) else {
                throw AgentBridgeError.invalidInput("The Local model response is not one strict JSON object matching the required schema. Nothing was written.")
            }
            guard LocalPatchWorkspace.isNormalizedRelativePath(path),
                  seenPaths.insert(path).inserted else {
                throw AgentBridgeError.invalidInput("The Local model response contains paths that were not selected or allowed: %@. Nothing was written.".replacingOccurrences(of: "%@", with: path))
            }

            let content: String?
            switch action {
            case .modify, .create:
                guard Set(entry.keys) == Set(["path", "action", "content"]),
                      let value = entry["content"] as? String,
                      !value.contains("\0") else {
                    throw AgentBridgeError.invalidInput("The Local model response is not one strict JSON object matching the required schema. Nothing was written.")
                }
                let count = value.utf8.count
                guard count <= maximumFileBytes else {
                    throw AgentBridgeError.invalidInput("The Local model response exceeds the per-file size limit of 256 KiB. Nothing was written.")
                }
                totalBytes += count
                guard totalBytes <= maximumTotalFileBytes else {
                    throw AgentBridgeError.invalidInput("The Local model response exceeds the total file size limit of 1 MiB. Nothing was written.")
                }
                content = value
            case .delete:
                guard Set(entry.keys) == Set(["path", "action"])
                        || (Set(entry.keys) == Set(["path", "action", "content"]) && (entry["content"] is NSNull)) else {
                    throw AgentBridgeError.invalidInput("The Local model response is not one strict JSON object matching the required schema. Nothing was written.")
                }
                content = nil
            }
            files.append(LocalPatchFileOutput(path: path, action: action, content: content))
        }
        return LocalPatchResponse(summary: summary, files: files)
    }
}

enum LocalPatchWorkspace {
    static let maximumFileBytes = LocalPatchResponseParser.maximumFileBytes

    struct FileState: Equatable {
        let data: Data
        let mode: mode_t
        let device: dev_t
        let inode: ino_t
    }

    struct Snapshot {
        let path: String
        let state: FileState?
    }

    static func isNormalizedRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 4_096, !path.hasPrefix("/"),
              !path.contains("\0"),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty
            && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && $0.lowercased() != ".git" }
    }

    static func candidate(path: String, root: URL) -> LocalChangeFileCandidate {
        guard isNormalizedRelativePath(path) else {
            return LocalChangeFileCandidate(path: path, byteCount: nil, isSelectable: false)
        }
        do {
            guard let metadata = try metadata(path: path, root: root), (metadata.st_mode & S_IFMT) == S_IFREG else {
                return LocalChangeFileCandidate(path: path, byteCount: nil, isSelectable: false)
            }
            let bytes = Int(metadata.st_size)
            guard bytes <= maximumFileBytes,
                  let state = try read(path: path, root: root, maximumBytes: maximumFileBytes),
                  String(data: state.data, encoding: .utf8) != nil,
                  !state.data.contains(0) else {
                return LocalChangeFileCandidate(path: path, byteCount: bytes, isSelectable: false)
            }
            return LocalChangeFileCandidate(path: path, byteCount: bytes, isSelectable: true)
        } catch {
            return LocalChangeFileCandidate(path: path, byteCount: nil, isSelectable: false)
        }
    }

    static func readText(path: String, root: URL) throws -> (String, FileState) {
        guard isNormalizedRelativePath(path),
              let state = try read(path: path, root: root, maximumBytes: maximumFileBytes),
              let text = String(data: state.data, encoding: .utf8),
              !text.contains("\0") else {
            throw AgentBridgeError.invalidInput("Selected files must be tracked or untracked, not ignored, regular UTF-8 files inside the isolated workspace, and at most 256 KiB each: %@.".replacingOccurrences(of: "%@", with: path))
        }
        return (text, state)
    }

    static func validateAbsent(path: String, root: URL) throws {
        guard isNormalizedRelativePath(path), try metadata(path: path, root: root) == nil else {
            throw AgentBridgeError.invalidInput("The Local model response contains paths that were not selected or allowed: %@. Nothing was written.".replacingOccurrences(of: "%@", with: path))
        }
    }

    static func writeAll(
        _ outputs: [LocalPatchFileOutput],
        selectedPaths: Set<String>,
        newPaths: Set<String>,
        expectedFileContents: [String: Data],
        root: URL
    ) throws {
        var rejected: [String] = []
        for output in outputs {
            let selected = selectedPaths.contains(output.path)
            switch output.action {
            case .modify where !selected, .delete where !selected:
                rejected.append(output.path)
            case .create where !newPaths.contains(output.path):
                rejected.append(output.path)
            default:
                break
            }
            if output.action == .create {
                do { try validateAbsent(path: output.path, root: root) }
                catch { rejected.append(output.path) }
            } else if selected {
                do { _ = try readText(path: output.path, root: root) }
                catch { rejected.append(output.path) }
            }
        }
        guard rejected.isEmpty else {
            throw LocalPatchApplicationError.rejectedPaths(Array(Set(rejected)))
        }

        let snapshots: [Snapshot]
        do {
            snapshots = try outputs.map { output -> Snapshot in
                switch output.action {
                case .modify, .delete:
                    let (_, state) = try readText(path: output.path, root: root)
                    guard expectedFileContents[output.path] == state.data else {
                        throw LocalPatchApplicationError.rejectedPaths([output.path])
                    }
                    return Snapshot(path: output.path, state: state)
                case .create:
                    return Snapshot(path: output.path, state: nil)
                }
            }
        } catch let error as LocalPatchApplicationError {
            throw error
        } catch {
            throw LocalPatchApplicationError.rejectedPaths(outputs.map(\.path))
        }

        var createdDirectories: [String] = []
        var appliedPaths: [String] = []
        do {
            try withRootDescriptor(root) { rootDescriptor in
                for output in outputs {
                    switch output.action {
                    case .modify, .create:
                        let snapshot = snapshots.first(where: { $0.path == output.path })!
                        let mode = snapshot.state?.mode ?? mode_t(0o644)
                        try atomicWrite(
                            Data((output.content ?? "").utf8),
                            path: output.path,
                            mode: mode,
                            mustBeAbsent: output.action == .create,
                            expected: snapshot.state,
                            rootDescriptor: rootDescriptor,
                            createdDirectories: &createdDirectories
                        )
                    case .delete:
                        try removeRegularFile(path: output.path, expected: snapshots.first(where: { $0.path == output.path })?.state, rootDescriptor: rootDescriptor)
                    }
                    appliedPaths.append(output.path)
                }
            }
        } catch {
            do {
                try withRootDescriptor(root) { rootDescriptor in
                    for snapshot in snapshots.filter({ appliedPaths.contains($0.path) }).reversed() {
                        if let state = snapshot.state {
                            try atomicWrite(
                                state.data,
                                path: snapshot.path,
                                mode: state.mode,
                                mustBeAbsent: false,
                                expected: nil,
                                rootDescriptor: rootDescriptor,
                                createdDirectories: &createdDirectories
                            )
                        } else {
                            try removeIfRegularFile(path: snapshot.path, rootDescriptor: rootDescriptor)
                        }
                    }
                    for directory in createdDirectories.reversed() {
                        try removeDirectoryIfEmpty(path: directory, rootDescriptor: rootDescriptor)
                    }
                }
            } catch {
                throw LocalPatchApplicationError.writeFailed(rollbackFailed: true)
            }
            throw LocalPatchApplicationError.writeFailed(rollbackFailed: false)
        }
    }

    private static func withRootDescriptor<T>(_ root: URL, _ body: (Int32) throws -> T) throws -> T {
        let descriptor = root.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else { throw posixError() }
        defer { close(descriptor) }
        return try body(descriptor)
    }

    private static func parentDescriptor(rootDescriptor: Int32, components: [String], createMissing: Bool, createdDirectories: inout [String]) throws -> Int32 {
        let descriptor = dup(rootDescriptor)
        guard descriptor >= 0 else { throw posixError() }
        var current = descriptor
        var prefix: [String] = []
        for component in components {
            prefix.append(component)
            var next = component.withCString { openat(current, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            if next < 0, errno == ENOENT, createMissing {
                let made = component.withCString { mkdirat(current, $0, mode_t(0o755)) }
                if made == 0 { createdDirectories.append(prefix.joined(separator: "/")) }
                else if errno != EEXIST { close(current); throw posixError() }
                next = component.withCString { openat(current, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            }
            guard next >= 0 else { close(current); throw posixError() }
            close(current)
            current = next
        }
        return current
    }

    private static func metadata(path: String, root: URL) throws -> stat? {
        let components = path.split(separator: "/").map(String.init)
        return try withRootDescriptor(root) { rootDescriptor in
            var created: [String] = []
            let parent: Int32
            do {
                parent = try parentDescriptor(rootDescriptor: rootDescriptor, components: Array(components.dropLast()), createMissing: false, createdDirectories: &created)
            } catch let error as NSError where error.code == ENOENT {
                return nil
            }
            defer { close(parent) }
            var info = stat()
            let result = components.last!.withCString { fstatat(parent, $0, &info, AT_SYMLINK_NOFOLLOW) }
            if result == 0 { return info }
            if errno == ENOENT { return nil }
            throw posixError()
        }
    }

    private static func read(path: String, root: URL, maximumBytes: Int) throws -> FileState? {
        let components = path.split(separator: "/").map(String.init)
        return try withRootDescriptor(root) { rootDescriptor in
            var created: [String] = []
            let parent = try parentDescriptor(rootDescriptor: rootDescriptor, components: Array(components.dropLast()), createMissing: false, createdDirectories: &created)
            defer { close(parent) }
            let descriptor = components.last!.withCString { openat(parent, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
            if descriptor < 0 {
                if errno == ENOENT { return nil }
                throw posixError()
            }
            defer { close(descriptor) }
            var before = stat()
            guard fstat(descriptor, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
                  before.st_size >= 0, before.st_size <= maximumBytes else { throw posixError(EFBIG) }
            var bytes = Data()
            bytes.reserveCapacity(Int(before.st_size))
            var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
            while true {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count == 0 { break }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                guard bytes.count + count <= maximumBytes else { throw posixError(EFBIG) }
                bytes.append(contentsOf: buffer.prefix(count))
            }
            var after = stat()
            guard fstat(descriptor, &after) == 0,
                  before.st_dev == after.st_dev, before.st_ino == after.st_ino,
                  before.st_size == after.st_size, bytes.count == Int(after.st_size) else {
                throw AgentBridgeError.invalidInput("A selected file changed while Local model input was being prepared.")
            }
            return FileState(data: bytes, mode: before.st_mode & 0o7777, device: before.st_dev, inode: before.st_ino)
        }
    }

    private static func atomicWrite(
        _ data: Data,
        path: String,
        mode: mode_t,
        mustBeAbsent: Bool,
        expected: FileState?,
        rootDescriptor: Int32,
        createdDirectories: inout [String]
    ) throws {
        let components = path.split(separator: "/").map(String.init)
        let parentPath = Array(components.dropLast())
        let parent = try parentDescriptor(rootDescriptor: rootDescriptor, components: parentPath, createMissing: true, createdDirectories: &createdDirectories)
        defer { close(parent) }
        let leaf = components.last!
        var current = stat()
        let currentResult = leaf.withCString { fstatat(parent, $0, &current, AT_SYMLINK_NOFOLLOW) }
        if mustBeAbsent {
            guard currentResult != 0, errno == ENOENT else { throw posixError(EEXIST) }
        } else if let expected {
            guard currentResult == 0, (current.st_mode & S_IFMT) == S_IFREG,
                  current.st_dev == expected.device, current.st_ino == expected.inode else { throw posixError(ESTALE) }
        } else if currentResult == 0, (current.st_mode & S_IFMT) != S_IFREG {
            throw posixError(ELOOP)
        }

        let temporary = ".agentbridge-local-patch-\(UUID().uuidString.lowercased())"
        let output = temporary.withCString { openat(parent, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode) }
        guard output >= 0 else { throw posixError() }
        var didRename = false
        defer {
            close(output)
            if !didRename { _ = temporary.withCString { unlinkat(parent, $0, 0) } }
        }
        guard fchmod(output, mode) == 0 else { throw posixError() }
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let count = Darwin.write(output, base.advanced(by: written), rawBuffer.count - written)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                guard count > 0 else { throw posixError(EIO) }
                written += count
            }
        }
        guard fsync(output) == 0 else { throw posixError() }
        let renameResult: Int32
        if mustBeAbsent {
            renameResult = temporary.withCString { source in leaf.withCString { destination in renameatx_np(parent, source, parent, destination, UInt32(RENAME_EXCL)) } }
        } else {
            renameResult = temporary.withCString { source in leaf.withCString { destination in renameat(parent, source, parent, destination) } }
        }
        guard renameResult == 0 else { throw posixError() }
        didRename = true
        _ = fsync(parent)
    }

    private static func removeRegularFile(path: String, expected: FileState?, rootDescriptor: Int32) throws {
        let components = path.split(separator: "/").map(String.init)
        var created: [String] = []
        let parent = try parentDescriptor(rootDescriptor: rootDescriptor, components: Array(components.dropLast()), createMissing: false, createdDirectories: &created)
        defer { close(parent) }
        var current = stat()
        let leaf = components.last!
        guard leaf.withCString({ fstatat(parent, $0, &current, AT_SYMLINK_NOFOLLOW) }) == 0,
              (current.st_mode & S_IFMT) == S_IFREG,
              expected.map({ current.st_dev == $0.device && current.st_ino == $0.inode }) ?? true,
              leaf.withCString({ unlinkat(parent, $0, 0) }) == 0 else { throw posixError() }
        _ = fsync(parent)
    }

    private static func removeIfRegularFile(path: String, rootDescriptor: Int32) throws {
        guard let existing = try metadataAt(path: path, rootDescriptor: rootDescriptor) else { return }
        guard (existing.st_mode & S_IFMT) == S_IFREG else { throw posixError(ELOOP) }
        try removeRegularFile(path: path, expected: nil, rootDescriptor: rootDescriptor)
    }

    private static func metadataAt(path: String, rootDescriptor: Int32) throws -> stat? {
        let components = path.split(separator: "/").map(String.init)
        var created: [String] = []
        let parent: Int32
        do { parent = try parentDescriptor(rootDescriptor: rootDescriptor, components: Array(components.dropLast()), createMissing: false, createdDirectories: &created) }
        catch where errno == ENOENT { return nil }
        defer { close(parent) }
        var info = stat()
        let result = components.last!.withCString { fstatat(parent, $0, &info, AT_SYMLINK_NOFOLLOW) }
        if result == 0 { return info }
        if errno == ENOENT { return nil }
        throw posixError()
    }

    private static func removeDirectoryIfEmpty(path: String, rootDescriptor: Int32) throws {
        let components = path.split(separator: "/").map(String.init)
        var created: [String] = []
        let parent = try parentDescriptor(rootDescriptor: rootDescriptor, components: Array(components.dropLast()), createMissing: false, createdDirectories: &created)
        defer { close(parent) }
        _ = components.last!.withCString { unlinkat(parent, $0, AT_REMOVEDIR) }
    }

    private static func posixError(_ code: Int32? = nil) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code ?? errno))
    }
}

private enum StrictJSONDuplicateKeyScanner {
    static func hasUniqueObjectKeys(_ text: String) -> Bool {
        var scanner = Scanner(bytes: Array(text.utf8))
        return scanner.scanValue() && scanner.isAtEnd
    }

    private struct Scanner {
        let bytes: [UInt8]
        var index = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        var isAtEnd: Bool {
            var copy = self
            copy.skipWhitespace()
            return copy.index == bytes.count
        }

        mutating func scanValue() -> Bool {
            skipWhitespace()
            guard index < bytes.count else { return false }
            switch bytes[index] {
            case 0x7B: return scanObject()
            case 0x5B: return scanArray()
            case 0x22: return scanString() != nil
            default:
                while index < bytes.count, ![0x2C, 0x5D, 0x7D, 0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
                return index > 0
            }
        }

        mutating func scanObject() -> Bool {
            index += 1
            skipWhitespace()
            if consume(0x7D) { return true }
            var keys = Set<String>()
            while true {
                skipWhitespace()
                guard let key = scanString(), keys.insert(key).inserted else { return false }
                skipWhitespace()
                guard consume(0x3A), scanValue() else { return false }
                skipWhitespace()
                if consume(0x7D) { return true }
                guard consume(0x2C) else { return false }
            }
        }

        mutating func scanArray() -> Bool {
            index += 1
            skipWhitespace()
            if consume(0x5D) { return true }
            while true {
                guard scanValue() else { return false }
                skipWhitespace()
                if consume(0x5D) { return true }
                guard consume(0x2C) else { return false }
            }
        }

        mutating func scanString() -> String? {
            guard consume(0x22) else { return nil }
            let start = index - 1
            var escaped = false
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if escaped { escaped = false; continue }
                if byte == 0x5C { escaped = true; continue }
                if byte == 0x22 {
                    let token = Data(bytes[start..<index])
                    return (try? JSONSerialization.jsonObject(with: token, options: [.fragmentsAllowed])) as? String
                }
            }
            return nil
        }

        mutating func consume(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }
    }
}
