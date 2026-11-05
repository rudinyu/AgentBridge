import CryptoKit
import Darwin
import Foundation

enum AutonomousValidation {
    static let maximumTasks = 8
    static let maximumPromptBytes = 16 * 1_024
    static let maximumReviewDiffBytes = 192 * 1_024
    static let maximumAgentOutputBytes = 24 * 1_024

    static func validate(tasks: [AutonomousTaskDefinition], changeScope: AutonomousChangeScope) throws -> [AutonomousTaskDefinition] {
        guard (3...maximumTasks).contains(tasks.count),
              Set(tasks.map(\.id)).count == tasks.count else {
            throw AutonomousOrchestrationError.invalidPlannerOutput("The DAG must contain 3 to 8 unique tasks.")
        }
        for task in tasks {
            guard isValidTaskID(task.id), task.title.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count <= 240,
                  !task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  task.prompt.utf8.count <= maximumPromptBytes,
                  !task.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  task.role != .planner,
                  Set(task.dependencies).count == task.dependencies.count,
                  task.dependencies.allSatisfy({ dependency in
                      dependency != task.id && isValidTaskID(dependency)
                          && tasks.contains(where: { candidate in candidate.id == dependency })
                  }) else {
                throw AutonomousOrchestrationError.invalidPlannerOutput("A task has an invalid identifier, title, prompt, or dependency list.")
            }
        }
        let implementers = tasks.filter { $0.role == .implementer }
        let reviewers = tasks.filter { $0.role == .reviewer }
        let researchers = tasks.filter { $0.role == .researcher }
        guard implementers.count == 1, reviewers.count == 1, !researchers.isEmpty else {
            throw AutonomousOrchestrationError.invalidPlannerOutput("The DAG requires at least one researcher, exactly one implementer, and exactly one reviewer.")
        }
        let implementerID = implementers[0].id
        let reviewer = reviewers[0]
        guard reviewer.dependencies.contains(implementerID) else {
            throw AutonomousOrchestrationError.invalidPlannerOutput("The reviewer must depend on the implementer.")
        }
        guard changeScope.title.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count <= 400,
              !changeScope.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              changeScope.summary.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count <= 10_000,
              !changeScope.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (1...32).contains(changeScope.steps.count),
              changeScope.steps.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 2_000 }) else {
            throw AutonomousOrchestrationError.invalidPlannerOutput("The change scope needs a title, summary, and 1 to 32 bounded steps.")
        }
        let byID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        for task in tasks {
            guard task.dependencies.allSatisfy({ byID[$0] != nil }) else {
                throw AutonomousOrchestrationError.invalidPlannerOutput("A task refers to an unknown dependency.")
            }
            if task.role == .researcher,
               task.dependencies.contains(where: { byID[$0]?.role != .researcher }) {
                throw AutonomousOrchestrationError.invalidPlannerOutput("Research tasks cannot depend on write or review tasks.")
            }
            if task.role == .implementer,
               task.dependencies.contains(where: { byID[$0]?.role == .reviewer || byID[$0]?.role == .implementer }) {
                throw AutonomousOrchestrationError.invalidPlannerOutput("The implementer cannot depend on a writer or reviewer task.")
            }
            if task.role == .reviewer,
               task.dependencies.contains(where: { byID[$0]?.role == .reviewer }) {
                throw AutonomousOrchestrationError.invalidPlannerOutput("Review tasks cannot depend on other review tasks.")
            }
        }
        try validateAcyclic(tasks: tasks)
        return tasks.sorted { $0.id < $1.id }
    }

    static func validateInvocationBudget(researcherCount: Int, limits: AutonomousRunLimits) throws {
        let minimum = 1 + researcherCount + (2 * limits.maxReviewRounds)
        guard minimum <= limits.maxProviderInvocations else {
            throw AutonomousOrchestrationError.providerInvocationLimitExceeded
        }
    }

    static func validateDesktopControlConfiguration(
        activations: [AutonomousExtensionActivationSnapshot],
        scope: String?,
        separateFromGit: Bool
    ) throws {
        let macControl = activations.filter { $0.kind == "macControl" }
        guard macControl.allSatisfy({
            $0.targetBundleID?.isEmpty == false
                && ($0.accessMode == "observe" || $0.accessMode == "control")
                && !$0.allowedActions.isEmpty
        }) else {
            throw AutonomousOrchestrationError.invalidRequest("MacControl must bind an exact target, access mode, and non-empty action allowlist.")
        }
        let controls = macControl.filter { $0.accessMode == "control" }
        guard macControl.filter({ $0.role != .implementer }).allSatisfy({ $0.accessMode == "observe" }) else {
            throw AutonomousOrchestrationError.invalidRequest("Research and review agents can only receive observe-only MacControl grants.")
        }
        guard controls.allSatisfy({ $0.role == .implementer }) else {
            throw AutonomousOrchestrationError.invalidRequest("Only the implementer may receive a MacControl control grant.")
        }
        let normalizedScope = scope?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (controls.isEmpty && normalizedScope == nil && !separateFromGit)
                || (!controls.isEmpty && normalizedScope.map({ !$0.isEmpty && $0.utf8.count <= 4_000 }) == true && separateFromGit) else {
            throw AutonomousOrchestrationError.invalidRequest("A control grant requires a bounded user-reviewed desktop scope declared separate from Git/source repository access.")
        }
    }

    static func validateLimits(_ limits: AutonomousRunLimits) throws {
        guard (1...3).contains(limits.maxConcurrentAgents),
              (1...3).contains(limits.maxReviewRounds),
              (30...3_600).contains(limits.maxDurationSeconds),
              (1...24).contains(limits.maxProviderInvocations),
              (1...128).contains(limits.maxMCPToolCallsPerServer) else {
            throw AutonomousOrchestrationError.invalidRequest("The stored autonomous execution limits are out of bounds.")
        }
    }

    static func validateOutputSharing(
        tasks: [AutonomousTaskDefinition],
        roleProfiles: [AutonomousRoleProfileSnapshot],
        shareOutputs: Bool,
        shareDiff: Bool
    ) throws {
        let byRole = Dictionary(uniqueKeysWithValues: roleProfiles.map { ($0.binding.role, $0.profile) })
        if shareOutputs {
            var bindingByTask: [String: AccountProfile] = [:]
            for task in tasks {
                guard let profile = byRole[task.role] else {
                    throw AutonomousOrchestrationError.invalidRequest("Every task role needs an explicit profile binding.")
                }
                bindingByTask[task.id] = profile
            }
            for task in tasks {
                for dependency in task.dependencies {
                    guard let source = bindingByTask[dependency], let target = bindingByTask[task.id],
                          source.allowsSharedMemory, target.allowsSharedMemory else {
                        throw AutonomousOrchestrationError.invalidRequest("Every dependency-output source and recipient profile must allow shared memory.")
                    }
                }
            }
        }
        guard shareDiff, byRole[.implementer]?.allowsSharedMemory == true,
              byRole[.reviewer]?.allowsSharedMemory == true else {
            throw AutonomousOrchestrationError.invalidRequest("The implementer and reviewer profiles must both allow sharing the exact diff with the reviewer.")
        }
    }

    static func boundedRedacted(_ text: String, maximumBytes: Int) -> String {
        let redacted = OutputRedactor.redact(text)
        guard redacted.utf8.count > maximumBytes else { return redacted }
        var result = String.UnicodeScalarView()
        var bytes = 0
        for scalar in redacted.unicodeScalars {
            let count = String(scalar).utf8.count
            if bytes + count > maximumBytes { break }
            result.append(scalar)
            bytes += count
        }
        return String(result)
    }

    static func isValidTaskID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...64).contains(bytes.count),
              let first = bytes.first,
              isLowerAlphaNumeric(first) else { return false }
        return bytes.allSatisfy { isLowerAlphaNumeric($0) || $0 == 45 || $0 == 46 || $0 == 95 }
    }

    static func isValidExtensionID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 160 && !value.contains("\0")
            && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    static func executableDigest(at url: URL) throws -> String {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              metadata.st_size >= 0, metadata.st_size <= 128 * 1_024 * 1_024,
              FileManager.default.isExecutableFile(atPath: url.path) else {
            throw AutonomousOrchestrationError.invalidRequest("The verification executable must be a regular executable file no larger than 128 MiB.")
        }
        let descriptor = url.path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        guard descriptor >= 0 else {
            throw AutonomousOrchestrationError.invalidRequest("The verification executable could not be opened safely.")
        }
        defer { _ = close(descriptor) }
        var openedMetadata = stat()
        guard fstat(descriptor, &openedMetadata) == 0,
              (openedMetadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              openedMetadata.st_nlink == 1,
              openedMetadata.st_size == metadata.st_size else {
            throw AutonomousOrchestrationError.invalidRequest("The verification executable changed while it was being fingerprinted.")
        }
        var data = Data()
        data.reserveCapacity(Int(openedMetadata.st_size))
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw AutonomousOrchestrationError.invalidRequest("The verification executable could not be read safely.")
            }
            guard data.count + count <= 128 * 1_024 * 1_024 else {
                throw AutonomousOrchestrationError.invalidRequest("The verification executable exceeds the fingerprint size limit.")
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        var finalMetadata = stat()
        guard fstat(descriptor, &finalMetadata) == 0,
              finalMetadata.st_size == openedMetadata.st_size,
              data.count == Int(openedMetadata.st_size) else {
            throw AutonomousOrchestrationError.invalidRequest("The verification executable changed while it was being fingerprinted.")
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }

    private static func validateAcyclic(tasks: [AutonomousTaskDefinition]) throws {
        let byID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        var visiting = Set<String>()
        var visited = Set<String>()
        func visit(_ id: String) throws {
            if visited.contains(id) { return }
            guard visiting.insert(id).inserted else {
                throw AutonomousOrchestrationError.invalidPlannerOutput("The task graph contains a dependency cycle.")
            }
            for dependency in byID[id]?.dependencies ?? [] { try visit(dependency) }
            visiting.remove(id)
            visited.insert(id)
        }
        for task in tasks { try visit(task.id) }
    }

    private static func isLowerAlphaNumeric(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 122)
    }
}

struct AutonomousDAGExecutor {
    static func run(
        tasks: [AutonomousTaskDefinition],
        maximumConcurrentTasks: Int,
        cancellation: CancellationFlag,
        shareDependencyOutputs: Bool,
        profileIDForTask: @escaping @Sendable (String) -> UUID,
        operation: @escaping @Sendable (AutonomousTaskDefinition, [AutonomousDependencyOutput]) async throws -> String,
        onStart: @escaping @Sendable (String) -> Void = { _ in },
        onComplete: @escaping @Sendable (String, String) -> Void = { _, _ in }
    ) async throws -> [String: String] {
        guard (1...3).contains(maximumConcurrentTasks) else {
            throw AutonomousOrchestrationError.invalidRequest("Concurrency must be between one and three agents.")
        }
        let nodes = tasks.filter { $0.role == .researcher }
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        guard byID.count == nodes.count,
              nodes.allSatisfy({ task in
                  AutonomousValidation.isValidTaskID(task.id)
                      && task.dependencies.allSatisfy({ byID[$0] != nil })
              }) else {
            throw AutonomousOrchestrationError.invalidRequest("Research DAG contains duplicate tasks or a non-research dependency.")
        }
        var completed: [String: String] = [:]
        var pending = Set(nodes.map(\.id))

        do {
            try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: (String, String).self) { group in
                var running = 0
                while !pending.isEmpty || running > 0 {
                    if cancellation.isCancelled || Task.isCancelled {
                        cancellation.cancel()
                        throw AutonomousOrchestrationError.cancelled
                    }
                    while running < maximumConcurrentTasks, !pending.isEmpty {
                        guard let next = pending.sorted().compactMap({ byID[$0] }).first(where: { task in
                            task.dependencies.allSatisfy { completed[$0] != nil }
                        }) else { break }
                        pending.remove(next.id)
                        let dependencyOutputs = shareDependencyOutputs ? next.dependencies.sorted().compactMap { dependency -> AutonomousDependencyOutput? in
                            guard let output = completed[dependency] else { return nil }
                            return AutonomousDependencyOutput(taskID: dependency, text: output, profileID: profileIDForTask(dependency))
                        } : []
                        onStart(next.id)
                        running += 1
                        group.addTask {
                            (next.id, try await operation(next, dependencyOutputs))
                        }
                    }
                    guard running > 0 else {
                        throw AutonomousOrchestrationError.invalidPlannerOutput("No task is ready; the DAG contains a cycle or an unknown dependency.")
                    }
                    guard let (id, output) = try await group.next() else { break }
                    running -= 1
                    let bounded = AutonomousValidation.boundedRedacted(output, maximumBytes: AutonomousValidation.maximumAgentOutputBytes)
                    completed[id] = bounded
                    onComplete(id, bounded)
                }
                }
            } onCancel: {
                cancellation.cancel()
            }
        } catch {
            cancellation.cancel()
            throw error
        }
        return completed
    }
}
