import Darwin
import Foundation

final class AutonomousRunStore {
    static let maximumStoredBytes = 20 * 1_024 * 1_024
    static let maximumRuns = 200
    static let maximumEventsPerRun = 512

    private static let fileName = "autonomous-runs.json"
    private let rootURL: URL
    private let processIdentity: @Sendable (Int32) -> String?

    init(
        rootURL: URL,
        processIdentity: @escaping @Sendable (Int32) -> String? = { AutonomousRunStore.processIdentity(for: $0) }
    ) throws {
        self.rootURL = rootURL.standardizedFileURL
        self.processIdentity = processIdentity
        try AgentBridgePrivateJSONDocument.withLockedRoot(rootURL: self.rootURL) { _ in () }
    }

    static func currentProcessIdentity() -> String? {
        processIdentity(for: ProcessInfo.processInfo.processIdentifier)
    }

    func all() throws -> [AutonomousRunRecord] {
        try withReadOnlyDocument { document in
            document.runs
                .sorted { $0.plan.createdAt > $1.plan.createdAt }
                .map { record in
                    guard record.status == .running else { return record }
                    guard let pid = record.runningProcessID,
                          let expectedIdentity = record.runningProcessStartToken else { return Self.markInterrupted(record) }
                    if let currentIdentity = processIdentity(pid) {
                        return currentIdentity == expectedIdentity ? record : Self.markInterrupted(record)
                    }
                    return Self.processIsAlive(pid) ? record : Self.markInterrupted(record)
                }
        }
    }

    func record(id: UUID) throws -> AutonomousRunRecord? {
        try withReadOnlyDocument { document in document.runs.first(where: { $0.id == id }) }
    }

    func insert(_ record: AutonomousRunRecord) throws {
        try withDocument { document in
            guard !document.runs.contains(where: { $0.id == record.id }) else {
                throw AutonomousOrchestrationError.invalidRequest("An autonomous run with this ID already exists.")
            }
            guard document.runs.count < Self.maximumRuns else {
                throw AgentBridgeError.persistence("Autonomous run history has reached its record limit.")
            }
            try Self.validate(record)
            document.runs.append(record)
        }
    }

    @discardableResult
    func update(id: UUID, _ mutation: (inout AutonomousRunRecord) throws -> Void) throws -> AutonomousRunRecord {
        try withDocument { document in
            guard let index = document.runs.firstIndex(where: { $0.id == id }) else {
                throw AutonomousOrchestrationError.invalidRequest("Autonomous run not found.")
            }
            try mutation(&document.runs[index])
            try Self.validate(document.runs[index])
            if document.runs[index].status != .running {
                document.cancellationRequests.remove(id)
            }
            return document.runs[index]
        }
    }

    /// Applies a stage transition only while no process has durably requested
    /// cancellation. The check and update share the document lock so a
    /// cancellation confirmed before a provider reservation cannot be lost.
    @discardableResult
    func updateUnlessCancellationRequested(
        id: UUID,
        _ mutation: (inout AutonomousRunRecord) throws -> Void
    ) throws -> AutonomousRunRecord {
        try withDocument { document in
            guard !document.cancellationRequests.contains(id) else {
                throw AutonomousOrchestrationError.cancelled
            }
            guard let index = document.runs.firstIndex(where: { $0.id == id }) else {
                throw AutonomousOrchestrationError.invalidRequest("Autonomous run not found.")
            }
            try mutation(&document.runs[index])
            try Self.validate(document.runs[index])
            if document.runs[index].status != .running {
                document.cancellationRequests.remove(id)
            }
            return document.runs[index]
        }
    }

    /// Finalizes a run while observing the persistent cancellation request
    /// under the same lock as the status update.
    @discardableResult
    func updateObservingCancellationRequest(
        id: UUID,
        _ mutation: (inout AutonomousRunRecord, Bool) throws -> Void
    ) throws -> AutonomousRunRecord {
        try withDocument { document in
            guard let index = document.runs.firstIndex(where: { $0.id == id }) else {
                throw AutonomousOrchestrationError.invalidRequest("Autonomous run not found.")
            }
            try mutation(&document.runs[index], document.cancellationRequests.contains(id))
            try Self.validate(document.runs[index])
            if document.runs[index].status != .running {
                document.cancellationRequests.remove(id)
            }
            return document.runs[index]
        }
    }

    struct CancellationRequestResult {
        let record: AutonomousRunRecord
        let shouldCancelSessions: Bool
    }

    /// Persists cancellation for an active run before callers send best-effort
    /// per-session signals. Terminal records are returned unchanged.
    func requestCancellation(id: UUID) throws -> CancellationRequestResult {
        try withDocument { document in
            guard let index = document.runs.firstIndex(where: { $0.id == id }) else {
                throw AutonomousOrchestrationError.invalidRequest("Autonomous run not found.")
            }
            switch document.runs[index].status {
            case .running:
                document.cancellationRequests.insert(id)
                Self.appendEvent(
                    &document.runs[index],
                    kind: "run.cancel.requested",
                    message: "Cancellation request persisted for the active workflow."
                )
                try Self.validate(document.runs[index])
                return CancellationRequestResult(record: document.runs[index], shouldCancelSessions: true)
            case .awaitingApproval, .approved:
                document.runs[index].status = .cancelled
                document.runs[index].finishedAt = Date()
                document.runs[index].resultSummary = "Cancelled before execution; no provider write agent was started."
                for taskIndex in document.runs[index].taskProgress.indices {
                    document.runs[index].taskProgress[taskIndex].status = .cancelled
                    document.runs[index].taskProgress[taskIndex].updatedAt = Date()
                }
                Self.appendEvent(
                    &document.runs[index],
                    kind: "run.cancelled",
                    message: "Cancellation was recorded before execution."
                )
                try Self.validate(document.runs[index])
                return CancellationRequestResult(record: document.runs[index], shouldCancelSessions: false)
            default:
                return CancellationRequestResult(record: document.runs[index], shouldCancelSessions: false)
            }
        }
    }

    func isCancellationRequested(id: UUID) throws -> Bool {
        try withReadOnlyDocument { document in document.cancellationRequests.contains(id) }
    }

    private func withDocument<T>(_ operation: (inout Document) throws -> T) throws -> T {
        try AgentBridgePrivateJSONDocument.withLockedRoot(rootURL: rootURL) { descriptor in
            var document = try Self.read(directoryDescriptor: descriptor)
            let result = try operation(&document)
            try Self.write(document, directoryDescriptor: descriptor)
            return result
        }
    }

    private func withReadOnlyDocument<T>(_ operation: (Document) throws -> T) throws -> T {
        try AgentBridgePrivateJSONDocument.withLockedRoot(rootURL: rootURL) { descriptor in
            try operation(Self.read(directoryDescriptor: descriptor))
        }
    }

    private static func read(directoryDescriptor: Int32) throws -> Document {
        guard let data = try AgentBridgePrivateJSONDocument.read(
            fileName: fileName,
            maximumBytes: maximumStoredBytes,
            directoryDescriptor: directoryDescriptor
        ) else { return Document() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let document = try decoder.decode(Document.self, from: data)
            let runIDs = Set(document.runs.map(\.id))
            guard document.version == 1, document.runs.count <= maximumRuns,
                  runIDs.count == document.runs.count,
                  document.cancellationRequests.count <= maximumRuns,
                  document.cancellationRequests.isSubset(of: Set(document.runs.filter { $0.status == .running }.map(\.id))) else {
                throw AutonomousOrchestrationError.invalidRequest("The autonomous run document has an invalid schema or duplicate records.")
            }
            try document.runs.forEach(validate)
            return document
        } catch let error as AutonomousOrchestrationError {
            throw error
        } catch {
            throw AgentBridgeError.persistence("The autonomous run document is malformed.")
        }
    }

    private static func write(_ document: Document, directoryDescriptor: Int32) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(document)
            try AgentBridgePrivateJSONDocument.write(
                data,
                fileName: fileName,
                maximumBytes: maximumStoredBytes,
                directoryDescriptor: directoryDescriptor
            )
        } catch let error as AgentBridgeError {
            throw error
        } catch let error as AutonomousOrchestrationError {
            throw error
        } catch {
            throw AgentBridgeError.persistence("Could not write the autonomous run document.")
        }
    }

    private static func validate(_ record: AutonomousRunRecord) throws {
        let validatedTasks = try AutonomousValidation.validate(tasks: record.plan.tasks, changeScope: record.plan.changeScope)
        try AutonomousValidation.validateLimits(record.plan.limits)
        guard record.id == record.plan.id,
              record.planDigest == record.plan.reviewDigest,
              record.planDigest.count == 64,
              record.plan.sourceRepositoryFingerprint.isIntact,
              record.plan.sourceRepositoryFingerprint.sourceRepositoryPath == record.plan.sourceRepositoryPath,
              record.plan.sourceRepositoryFingerprint.headCommit.lowercased() == record.plan.baseCommit.lowercased(),
              record.sourceRepositoryFingerprintBefore == record.plan.sourceRepositoryFingerprint,
              record.sourceRepositoryFingerprintAfter?.isIntact ?? true,
              (1...record.plan.limits.maxProviderInvocations).contains(record.providerInvocationsStarted),
              (0...record.plan.limits.maxReviewRounds).contains(record.currentReviewRound),
              record.events.count <= maximumEventsPerRun,
              Set(record.taskProgress.map(\.id)).count == record.taskProgress.count,
              Set(record.plan.tasks.map(\.id)) == Set(record.taskProgress.map(\.id)) else {
            throw AutonomousOrchestrationError.invalidRequest("The autonomous run record failed integrity checks.")
        }
        let expectedAgents = record.plan.tasks.filter { $0.role != .reviewer }.count + record.plan.limits.maxReviewRounds
        let taskIDs = Set(record.plan.tasks.map(\.id))
        let reviewers = record.plan.plannedAgents.filter { $0.role == .reviewer }
        let roleIDs = Set(record.plan.roleProfiles.map { $0.binding.role })
        let sessionIDs = [record.plan.plannerSessionID] + record.plan.plannedAgents.map(\.sessionID)
        let taskByID = Dictionary(uniqueKeysWithValues: validatedTasks.map { ($0.id, $0) })
        guard record.plan.plannedAgents.count == expectedAgents,
              record.plan.roleProfiles.count == AutonomousRole.allCases.count,
              roleIDs == Set(AutonomousRole.allCases),
              record.plan.plannerBinding.role == .planner,
              record.plan.roleProfiles.first(where: { $0.binding.role == .planner })?.binding == record.plan.plannerBinding,
              record.plan.plannerBinding.extensionIDs.isEmpty,
              record.plan.plannedAgents.allSatisfy({ taskIDs.contains($0.taskID) }),
              Set(sessionIDs).count == sessionIDs.count,
              record.plan.plannedAgents.allSatisfy({ taskByID[$0.taskID]?.role == $0.role }),
              record.plan.plannedAgents.filter({ $0.role != .reviewer }).allSatisfy({ $0.roundIndex == nil }),
              reviewers.count == record.plan.limits.maxReviewRounds,
              Set(reviewers.compactMap(\.roundIndex)) == Set(1...record.plan.limits.maxReviewRounds),
              record.plan.plannedAgents.filter({ $0.role != .reviewer }).map(\.taskID).sorted()
                == record.plan.tasks.filter({ $0.role != .reviewer }).map(\.id).sorted() else {
            throw AutonomousOrchestrationError.invalidRequest("The autonomous session assignments do not match the plan's role and round limits.")
        }
        guard record.events.allSatisfy({ $0.message.utf8.count <= 16 * 1_024 }),
              record.taskProgress.allSatisfy({ $0.summary.utf8.count <= 8_000 }) else {
            throw AutonomousOrchestrationError.invalidRequest("The autonomous run record exceeds text limits.")
        }
        try AutonomousValidation.validateOutputSharing(
            tasks: validatedTasks,
            roleProfiles: record.plan.roleProfiles,
            shareOutputs: record.plan.shareOutputsWithDependencies,
            shareDiff: record.plan.shareDiffWithReviewer
        )
        try AutonomousValidation.validateInvocationBudget(
            researcherCount: validatedTasks.filter { $0.role == .researcher }.count,
            limits: record.plan.limits
        )
        try AutonomousValidation.validateDesktopControlConfiguration(
            activations: record.plan.extensionActivations,
            scope: record.plan.desktopControlScope,
            separateFromGit: record.plan.desktopControlSeparateFromGit
        )
        if record.plan.saveRunSummaryToMemory {
            guard let destinationID = record.plan.memoryDestinationProfileID,
                  record.plan.roleProfiles.contains(where: {
                      $0.binding.accountProfileID == destinationID && $0.profile.allowsSharedMemory
                  }) else {
                throw AutonomousOrchestrationError.invalidRequest("The approved memory destination is not a consenting role profile.")
            }
        } else if record.plan.memoryDestinationProfileID != nil {
            throw AutonomousOrchestrationError.invalidRequest("The autonomous plan has an unconsented project-memory destination.")
        }
        let hasMemoryConsent = record.plan.roleProfiles.contains(where: { $0.profile.allowsSharedMemory })
        guard hasMemoryConsent == (record.plan.projectMemorySnapshot != nil) else {
            throw AutonomousOrchestrationError.invalidRequest("The approved project-memory snapshot does not match the role-profile consent manifest.")
        }
        if let memory = record.plan.projectMemorySnapshot {
            guard memory.isIntact,
                  memory.repositoryPath.utf8.count <= 4_096,
                  memory.snapshotCommit.lowercased() == record.plan.baseCommit.lowercased(),
                  memory.revision >= 0,
                  memory.notes.utf8.count <= SharedMemoryStore.maximumStoredBytes,
                  memory.turns.count <= SharedMemoryStore.maximumStoredTurns,
                  memory.turns.allSatisfy({
                      $0.userText.utf8.count <= SharedMemoryStore.maximumStoredBytes
                          && $0.assistantText.utf8.count <= SharedMemoryStore.maximumStoredBytes
                          && $0.userText == OutputRedactor.redact($0.userText)
                          && $0.assistantText == OutputRedactor.redact($0.assistantText)
                  }) else {
                throw AutonomousOrchestrationError.invalidRequest("The frozen project-memory snapshot is invalid or exceeds its size limits.")
            }
        }
        guard record.plan.baseCommit.count == 40 || record.plan.baseCommit.count == 64,
              record.plan.baseCommit.utf8.allSatisfy({
                  ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 70) || ($0 >= 97 && $0 <= 102)
              }) else {
            throw AutonomousOrchestrationError.invalidRequest("The autonomous plan has an invalid base commit.")
        }
        if record.plan.verification.mode == .custom {
            guard let path = record.plan.verification.executablePath,
                  let digest = record.plan.verification.executableDigest,
                  digest.count == 64,
                  digest.utf8.allSatisfy({
                      ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
                  }),
                  path.hasPrefix("/") else {
                throw AutonomousOrchestrationError.invalidRequest("The autonomous plan has an invalid custom verification binding.")
            }
        }
        let plannedAgentKeys = Set(record.plan.plannedAgents.map { "\($0.role.rawValue):\($0.taskID):\($0.roundIndex ?? 0)" })
        let bindingsByRole = Dictionary(uniqueKeysWithValues: record.plan.roleProfiles.map { ($0.binding.role, $0.binding) })
        let expectedActivationIDs = Set(record.plan.plannedAgents.flatMap { agent in
            (bindingsByRole[agent.role]?.extensionIDs ?? []).map {
                "\(agent.role.rawValue):\(agent.taskID):\(agent.roundIndex ?? 0):\($0)"
            }
        })
        let actualActivationIDs = Set(record.plan.extensionActivations.map(\.id))
        guard record.plan.extensionActivations.count <= record.plan.plannedAgents.count * 16,
              actualActivationIDs.count == record.plan.extensionActivations.count,
              expectedActivationIDs == actualActivationIDs,
              record.plan.extensionActivations.allSatisfy({ activation in
                  let key = "\(activation.role.rawValue):\(activation.taskID):\(activation.roundIndex ?? 0)"
                  let digestIsValid = activation.configurationDigest.count == 64
                      && activation.configurationDigest.utf8.allSatisfy({
                          ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
                      })
                  let reviewDigestIsValid = activation.reviewedDigest.map { value in
                      value.count == 64 && value.utf8.allSatisfy {
                          ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
                      }
                  } ?? true
                  let executableDigestIsValid = [activation.executableDigest, activation.proxyExecutableDigest]
                      .compactMap { $0 }
                      .allSatisfy { value in
                          value.count == 64 && value.utf8.allSatisfy {
                              ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
                          }
                      }
                  let skillDigestIsValid = activation.skillDigest.map { value in
                      value.count == 64 && value.utf8.allSatisfy {
                          ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
                      }
                  } ?? true
                  return activation.extensionID.utf8.count <= 160
                      && plannedAgentKeys.contains(key)
                      && bindingsByRole[activation.role]?.extensionIDs.contains(activation.extensionID) == true
                      && activation.taskID.utf8.count <= 64
                      && activation.name.utf8.count <= 256
                      && activation.summary.utf8.count <= 4_096
                      && digestIsValid
                      && reviewDigestIsValid
                      && executableDigestIsValid
                      && skillDigestIsValid
                      && activation.arguments.count <= 128
                      && activation.arguments.allSatisfy({ $0.utf8.count <= 8_192 })
                      && activation.entrypointPins.count <= 16
                      && activation.entrypointPins.allSatisfy({
                          $0.path.hasPrefix("/") && $0.path.utf8.count <= 4_096
                              && $0.digest.count == 64
                              && $0.digest.utf8.allSatisfy {
                                  ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
                              }
                      })
                      && (activation.commandPath?.utf8.count ?? 0) <= 4_096
                      && (activation.proxyExecutablePath?.utf8.count ?? 0) <= 4_096
                      && (activation.targetBundleID?.utf8.count ?? 0) <= 255
                      && activation.permissions.count <= 32
                      && activation.allowedActions.count <= 512
                      && activation.targetScope.count <= 64
                      && (activation.maximumToolCallsPerRun.map { (1...128).contains($0) } ?? true)
                      && (activation.maximumToolResponseBytes.map { (64 * 1_024...8 * 1_024 * 1_024).contains($0) } ?? true)
                      && (activation.maximumTotalToolResponseBytes.map { (64 * 1_024...32 * 1_024 * 1_024).contains($0) } ?? true)
                      && ((activation.kind == "skill" && activation.skillDigest != nil && activation.entrypointPins.isEmpty && activation.maximumToolCallsPerRun == nil)
                          || (activation.kind != "skill" && activation.skillDigest == nil && activation.maximumToolCallsPerRun != nil
                              && activation.maximumToolResponseBytes != nil
                              && activation.maximumTotalToolResponseBytes != nil))
                      && activation.permissions.allSatisfy({ $0.utf8.count <= 512 })
                      && activation.allowedActions.allSatisfy({ $0.utf8.count <= 256 })
                      && activation.targetScope.allSatisfy({ $0.utf8.count <= 2_048 })
              }) else {
            throw AutonomousOrchestrationError.invalidRequest("The approved extension manifest exceeds its supported scope or size limits.")
        }
        if record.status == .running {
            guard record.runningProcessID != nil, record.runningProcessStartToken != nil else {
                throw AutonomousOrchestrationError.invalidRequest("A running autonomous record has no process liveness binding.")
            }
        }
        if record.status == .approved || record.status == .running || record.status == .completed {
            guard record.approvedAt != nil else {
                throw AutonomousOrchestrationError.invalidRequest("An approved or running autonomous record has no approval timestamp.")
            }
        }
        if record.status == .completed {
            guard record.reviewVerdict == .pass,
                  let digest = record.diffDigest,
                  digest.count == 64,
                  record.plan.verification.mode == .none || record.verificationPassed == true else {
                throw AutonomousOrchestrationError.invalidRequest("A completed autonomous run lacks unchanged-diff review or required verification evidence.")
            }
            guard record.sourceRepositoryFingerprintAfter == record.plan.sourceRepositoryFingerprint,
                  (record.plan.saveRunSummaryToMemory ? record.memorySummarySaved != nil : record.memorySummarySaved == nil) else {
                throw AutonomousOrchestrationError.invalidRequest("A completed autonomous run lacks final source fingerprint or approved memory-save evidence.")
            }
        }
    }

    private static func markInterrupted(_ record: AutonomousRunRecord) -> AutonomousRunRecord {
        guard record.status == .running else { return record }
        var interrupted = record
        interrupted.status = .interrupted
        interrupted.resultSummary = "The previous process stopped while this run was active. It was not replayed. Create and approve a new plan to continue."
        return interrupted
    }

    private static func appendEvent(_ record: inout AutonomousRunRecord, kind: String, message: String) {
        record.events.append(AutonomousRunEvent(kind: kind, message: message))
        if record.events.count > maximumEventsPerRun {
            record.events.removeFirst(record.events.count - maximumEventsPerRun)
        }
    }

    private static func processIdentity(for pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, infoSize)
        if result == infoSize {
            return "\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)"
        }
        return nil
    }

    private static func processIsAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private struct Document: Codable {
        let version: Int
        var runs: [AutonomousRunRecord]
        var cancellationRequests: Set<UUID>

        init(version: Int = 1, runs: [AutonomousRunRecord] = [], cancellationRequests: Set<UUID> = []) {
            self.version = version
            self.runs = runs
            self.cancellationRequests = cancellationRequests
        }

        private enum CodingKeys: String, CodingKey {
            case version
            case runs
            case cancellationRequests
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            runs = try container.decode([AutonomousRunRecord].self, forKey: .runs)
            cancellationRequests = Set(try container.decodeIfPresent([UUID].self, forKey: .cancellationRequests) ?? [])
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(version, forKey: .version)
            try container.encode(runs, forKey: .runs)
            try container.encode(cancellationRequests.sorted { $0.uuidString < $1.uuidString }, forKey: .cancellationRequests)
        }
    }
}
