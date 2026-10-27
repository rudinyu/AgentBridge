import Foundation

public enum ParallelTaskStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case queued
    case inProgress
    case blocked
    case completed
    case failed
    case cancelled

    fileprivate var isTerminal: Bool {
        self == .completed || self == .failed || self == .cancelled
    }
}

public enum ParallelTaskApprovalState: String, Codable, CaseIterable, Hashable, Sendable {
    case notRequested
    case requested
    case approved
    case rejected
}

public enum ParallelTaskReferenceKind: String, Codable, Hashable, Sendable {
    case verification
    case diff
}

/// A bounded reference to verification evidence or a diff. The board stores
/// references as data and never opens or runs them.
public struct ParallelTaskReference: Codable, Equatable, Hashable, Sendable {
    public let kind: ParallelTaskReferenceKind
    public let value: String

    public init(kind: ParallelTaskReferenceKind, value: String) throws {
        self.kind = kind
        self.value = try ParallelTaskValidation.text(value, label: "task reference", maximumBytes: ParallelTaskBoard.maximumReferenceBytes, allowEmpty: false)
    }

    private enum CodingKeys: String, CodingKey { case kind, value }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(kind: container.decode(ParallelTaskReferenceKind.self, forKey: .kind), value: container.decode(String.self, forKey: .value))
        } catch {
            throw DecodingError.dataCorruptedError(forKey: .value, in: container, debugDescription: "The task reference is invalid.")
        }
    }
}

/// Coordination metadata for a single task. IDs are UUIDs with distinct roles:
/// a session can contain multiple task records, each with its own task ID.
public struct ParallelTaskRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let sessionID: UUID
    public let status: ParallelTaskStatus
    public let createdAt: Date
    public let updatedAt: Date
    public let progressSummary: String
    public let approvalState: ParallelTaskApprovalState
    public let references: [ParallelTaskReference]

    public init(
        id: UUID,
        sessionID: UUID,
        status: ParallelTaskStatus = .queued,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        progressSummary: String = "",
        approvalState: ParallelTaskApprovalState = .notRequested,
        references: [ParallelTaskReference] = []
    ) throws {
        let resolvedUpdatedAt = updatedAt ?? createdAt
        guard id != sessionID else {
            throw AgentBridgeError.invalidInput("A task ID must be independent from its session ID.")
        }
        guard resolvedUpdatedAt >= createdAt else {
            throw AgentBridgeError.invalidInput("A task update timestamp cannot precede its creation timestamp.")
        }
        guard references.count <= ParallelTaskBoard.maximumReferencesPerTask,
              Set(references).count == references.count else {
            throw AgentBridgeError.invalidInput("Task references must be unique and within the supported limit.")
        }

        self.id = id
        self.sessionID = sessionID
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = resolvedUpdatedAt
        self.progressSummary = try ParallelTaskValidation.text(
            progressSummary,
            label: "task progress summary",
            maximumBytes: ParallelTaskBoard.maximumProgressSummaryBytes,
            allowEmpty: true
        )
        self.approvalState = approvalState
        self.references = references
    }

    private enum CodingKeys: String, CodingKey {
        case id, sessionID, status, createdAt, updatedAt, progressSummary, approvalState, references
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(UUID.self, forKey: .id),
                sessionID: container.decode(UUID.self, forKey: .sessionID),
                status: container.decode(ParallelTaskStatus.self, forKey: .status),
                createdAt: container.decode(Date.self, forKey: .createdAt),
                updatedAt: container.decode(Date.self, forKey: .updatedAt),
                progressSummary: container.decode(String.self, forKey: .progressSummary),
                approvalState: container.decode(ParallelTaskApprovalState.self, forKey: .approvalState),
                references: container.decode([ParallelTaskReference].self, forKey: .references)
            )
        } catch {
            throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "The parallel task record is invalid.")
        }
    }
}

/// A persistent board for coordinating work. It does not launch processes and
/// does not imply that tasks are actually running in parallel.
public final class ParallelTaskBoard: @unchecked Sendable {
    public static let maximumTasks = 1_000
    public static let maximumStoredBytes = 1 * 1_024 * 1_024
    public static let maximumProgressSummaryBytes = 2 * 1_024
    public static let maximumReferenceBytes = 2 * 1_024
    public static let maximumReferencesPerTask = 32

    private static let fileName = "parallel-task-board.json"
    private let rootURL: URL

    public init(rootURL: URL, fileManager: FileManager = .default) throws {
        self.rootURL = rootURL.standardizedFileURL
        try AgentBridgePrivateJSONDocument.withLockedRoot(rootURL: self.rootURL, fileManager: fileManager) { _ in () }
    }

    @discardableResult
    public func create(sessionID: UUID, id: UUID = UUID(), progressSummary: String = "") throws -> ParallelTaskRecord {
        let task = try ParallelTaskRecord(id: id, sessionID: sessionID, progressSummary: progressSummary)
        return try withDocument { document in
            guard !document.tasks.contains(where: { $0.id == task.id }) else {
                throw AgentBridgeError.invalidInput("A task with this ID already exists.")
            }
            guard document.tasks.count < Self.maximumTasks else {
                throw AgentBridgeError.persistence("The parallel task board has reached its task limit.")
            }
            document.tasks.append(task)
            return task
        }
    }

    public func list(sessionID: UUID? = nil, status: ParallelTaskStatus? = nil) throws -> [ParallelTaskRecord] {
        try withDocument { document in
            document.tasks
                .filter { (sessionID == nil || $0.sessionID == sessionID) && (status == nil || $0.status == status) }
                .sorted {
                    if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                    return $0.id.uuidString < $1.id.uuidString
                }
        }
    }

    public func task(id: UUID) throws -> ParallelTaskRecord? {
        try withDocument { document in document.tasks.first { $0.id == id } }
    }

    @discardableResult
    public func transition(taskID: UUID, to status: ParallelTaskStatus) throws -> ParallelTaskRecord {
        try update(taskID: taskID) { task in
            guard task.status != status else { return task }
            guard Self.allowedTransitions[task.status, default: []].contains(status) else {
                throw AgentBridgeError.invalidInput("The task status transition from \(task.status.rawValue) to \(status.rawValue) is not allowed.")
            }
            return try Self.replacing(task, status: status)
        }
    }

    @discardableResult
    public func updateProgress(taskID: UUID, summary: String) throws -> ParallelTaskRecord {
        let validatedSummary = try ParallelTaskValidation.text(
            summary,
            label: "task progress summary",
            maximumBytes: Self.maximumProgressSummaryBytes,
            allowEmpty: true
        )
        return try update(taskID: taskID) { task in
            guard !task.status.isTerminal else {
                throw AgentBridgeError.invalidInput("Progress cannot be changed after a task reaches a terminal state.")
            }
            guard task.progressSummary != validatedSummary else { return task }
            return try Self.replacing(task, progressSummary: validatedSummary)
        }
    }

    @discardableResult
    public func setApproval(taskID: UUID, to approvalState: ParallelTaskApprovalState) throws -> ParallelTaskRecord {
        try update(taskID: taskID) { task in
            guard task.approvalState != approvalState else { return task }
            guard Self.allowedApprovalTransitions[task.approvalState, default: []].contains(approvalState) else {
                throw AgentBridgeError.invalidInput("The task approval transition from \(task.approvalState.rawValue) to \(approvalState.rawValue) is not allowed.")
            }
            return try Self.replacing(task, approvalState: approvalState)
        }
    }

    @discardableResult
    public func addReference(taskID: UUID, kind: ParallelTaskReferenceKind, value: String) throws -> ParallelTaskRecord {
        let reference = try ParallelTaskReference(kind: kind, value: value)
        return try update(taskID: taskID) { task in
            if task.references.contains(reference) { return task }
            guard task.references.count < Self.maximumReferencesPerTask else {
                throw AgentBridgeError.invalidInput("A task cannot contain more than \(Self.maximumReferencesPerTask) references.")
            }
            return try Self.replacing(task, references: task.references + [reference])
        }
    }

    private func update(taskID: UUID, transform: (ParallelTaskRecord) throws -> ParallelTaskRecord) throws -> ParallelTaskRecord {
        try withDocument { document in
            guard let index = document.tasks.firstIndex(where: { $0.id == taskID }) else {
                throw AgentBridgeError.invalidInput("The requested task does not exist.")
            }
            let updated = try transform(document.tasks[index])
            document.tasks[index] = updated
            return updated
        }
    }

    private func withDocument<T>(_ operation: (inout ParallelTaskBoardDocument) throws -> T) throws -> T {
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

    private static func readDocument(directoryDescriptor: Int32) throws -> ParallelTaskBoardDocument {
        guard let data = try AgentBridgePrivateJSONDocument.read(
            fileName: Self.fileName,
            maximumBytes: Self.maximumStoredBytes,
            directoryDescriptor: directoryDescriptor
        ) else { return ParallelTaskBoardDocument() }
        do {
            let document = try makeDecoder().decode(ParallelTaskBoardDocument.self, from: data)
            guard document.schemaVersion == 1,
                  document.tasks.count <= maximumTasks,
                  Set(document.tasks.map(\.id)).count == document.tasks.count else {
                throw AgentBridgeError.persistence("The parallel task board failed integrity checks.")
            }
            return document
        } catch let error as AgentBridgeError {
            throw error
        } catch {
            throw AgentBridgeError.persistence("The parallel task board is malformed.")
        }
    }

    private static func encode(_ document: ParallelTaskBoardDocument) throws -> Data {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .millisecondsSince1970
            let data = try encoder.encode(document)
            guard data.count <= maximumStoredBytes else {
                throw AgentBridgeError.persistence("The parallel task board exceeds its storage limit.")
            }
            return data
        } catch let error as AgentBridgeError {
            throw error
        } catch {
            throw AgentBridgeError.persistence("The parallel task board could not be encoded.")
        }
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    private static func replacing(
        _ task: ParallelTaskRecord,
        status: ParallelTaskStatus? = nil,
        progressSummary: String? = nil,
        approvalState: ParallelTaskApprovalState? = nil,
        references: [ParallelTaskReference]? = nil
    ) throws -> ParallelTaskRecord {
        try ParallelTaskRecord(
            id: task.id,
            sessionID: task.sessionID,
            status: status ?? task.status,
            createdAt: task.createdAt,
            updatedAt: max(Date(), task.updatedAt),
            progressSummary: progressSummary ?? task.progressSummary,
            approvalState: approvalState ?? task.approvalState,
            references: references ?? task.references
        )
    }

    private static let allowedTransitions: [ParallelTaskStatus: Set<ParallelTaskStatus>] = [
        .queued: [.inProgress, .cancelled],
        .inProgress: [.blocked, .completed, .failed, .cancelled],
        .blocked: [.inProgress, .failed, .cancelled]
    ]

    private static let allowedApprovalTransitions: [ParallelTaskApprovalState: Set<ParallelTaskApprovalState>] = [
        .notRequested: [.requested],
        .requested: [.approved, .rejected, .notRequested],
        .approved: [.requested],
        .rejected: [.requested]
    ]
}

private struct ParallelTaskBoardDocument: Codable {
    var schemaVersion: Int
    var tasks: [ParallelTaskRecord]

    init() {
        schemaVersion = 1
        tasks = []
    }
}

private enum ParallelTaskValidation {
    static func text(_ value: String, label: String, maximumBytes: Int, allowEmpty: Bool) throws -> String {
        guard value.utf8.count <= maximumBytes,
              allowEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw AgentBridgeError.invalidInput("The \(label) is invalid or exceeds its size limit.")
        }
        return value
    }
}
