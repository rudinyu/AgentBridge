import Darwin
import Foundation
import AgentBridgeCore

extension AgentBridgeCLI {
    static func autonomousCommand(_ arguments: [String], service: BridgeService) async throws {
        guard let action = arguments.first else {
            throw AgentBridgeError.invalidInput("Usage: agentbridge autonomous plan|approve|run|status|cancel ...")
        }
        switch action {
        case "plan":
            try await autonomousPlan(arguments, service: service)
        case "approve":
            try await autonomousApprove(arguments, service: service)
        case "run":
            try await autonomousRun(arguments, service: service)
        case "status":
            try await autonomousStatus(arguments, service: service)
        case "cancel":
            guard arguments.count == 3,
                  let runID = UUID(uuidString: arguments[1]),
                  arguments[2] == "--confirm" else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge autonomous cancel RUN-ID --confirm")
            }
            try service.cancelAutonomousRun(id: runID)
            print("Cancellation requested for autonomous run \(runID.uuidString.lowercased()); active role sessions are being cancelled.")
        default:
            throw AgentBridgeError.invalidInput("Unknown autonomous action. Use plan, approve, run, status, or cancel.")
        }
    }

    static func autonomousRole(for option: String) throws -> AutonomousRole {
        switch option {
        case "--researcher": return .researcher
        case "--implementer": return .implementer
        case "--reviewer": return .reviewer
        default: throw AgentBridgeError.invalidInput("Unknown autonomous role \(option).")
        }
    }

    static func parseProviderProfile(_ value: String) throws -> (AgentProvider, UUID) {
        let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let provider = AgentProvider(rawValue: String(parts[0])),
              let profileID = UUID(uuidString: String(parts[1])) else {
            throw AgentBridgeError.invalidInput("Provider profile must use PROVIDER:PROFILE-UUID, such as codex:00000000-0000-0000-0000-000000000001.")
        }
        return (provider, profileID)
    }

    static func nextOptionValue(_ option: String, arguments: [String], index: inout Int) throws -> String {
        guard index < arguments.count, !arguments[index].hasPrefix("--") else {
            throw AgentBridgeError.invalidInput("\(option) requires a value.")
        }
        let value = arguments[index]
        index += 1
        return value
    }

    static func parseInteger(_ value: String, option: String) throws -> Int {
        guard let parsed = Int(value) else { throw AgentBridgeError.invalidInput("\(option) requires an integer.") }
        return parsed
    }

    static func printAutonomousPlan(_ record: AutonomousRunRecord) {
        let plan = record.plan
        print("Run: \(record.id.uuidString.lowercased())")
        print("Status: \(record.status.rawValue)")
        print("Goal: \(OutputRedactor.redact(plan.goal))")
        print("Source: \(plan.sourceRepositoryPath) @ \(plan.baseCommit)")
        print("Source repository fingerprint: \(plan.sourceRepositoryFingerprint.overallDigest)")
        print("  HEAD \(plan.sourceRepositoryFingerprint.headCommit) · status \(plan.sourceRepositoryFingerprint.statusDigest)")
        print("  tracked diff \(plan.sourceRepositoryFingerprint.trackedDiffDigest) · untracked paths \(plan.sourceRepositoryFingerprint.untrackedPathsDigest) · untracked contents \(plan.sourceRepositoryFingerprint.untrackedContentDigest)")
        print("  Checked before execution and after desktop control/final work; agents use an isolated snapshot.")
        if let desktopScope = plan.desktopControlScope {
            print("Desktop control scope: \(OutputRedactor.redact(desktopScope)) · separate from Git/source access: \(plan.desktopControlSeparateFromGit)")
        } else {
            print("Desktop control scope: none")
        }
        if let memory = plan.projectMemorySnapshot {
            print("Frozen project memory: \(memory.repositoryPath) @ \(memory.snapshotCommit) · revision \(memory.revision) · SHA-256 \(memory.digest) · truncated \(memory.wasTruncated)")
            print("  Role profiles receiving context: \(plan.roleProfiles.filter { $0.profile.allowsSharedMemory }.map { "\($0.binding.role.rawValue):\($0.binding.provider.rawValue)/\($0.profile.name)" }.joined(separator: ", "))")
            print("  Exact notes: \(OutputRedactor.redact(memory.notes))")
            for turn in memory.turns {
                print("  \(turn.provider.rawValue) memory turn \(turn.id.uuidString.lowercased()) · \(turn.timestamp.formatted()):")
                print("    User: \(OutputRedactor.redact(turn.userText))")
                print("    Assistant: \(OutputRedactor.redact(turn.assistantText))")
            }
        } else {
            print("Frozen project memory: none (no bound profile allows shared memory)")
        }
        print("Save final summary to project memory: \(plan.saveRunSummaryToMemory) · destination \(plan.memoryDestinationProfileID?.uuidString.lowercased() ?? "none")")
        print("Planner: \(plan.plannerBinding.provider.rawValue) / \(plan.plannerBinding.accountProfileID.uuidString.lowercased())")
        print("Concurrency: \(plan.limits.maxConcurrentAgents); review rounds: \(plan.limits.maxReviewRounds); duration: \(plan.limits.maxDurationSeconds)s; provider calls: \(plan.limits.maxProviderInvocations)")
        print("Dependency outputs shared: \(plan.shareOutputsWithDependencies); exact diff shared with reviewer: \(plan.shareDiffWithReviewer)")
        print("Verification: \(plan.verification.mode.rawValue)\(plan.verification.executablePath.map { " · \($0)" } ?? "")")
        if let disclosure = plan.verification.executionTrustDisclosure {
            print("Verification trust: \(disclosure)")
        }
        for binding in plan.roleProfiles {
            print("Role \(binding.binding.role.rawValue): \(binding.binding.provider.rawValue) / \(binding.profile.name) / \(binding.profile.id.uuidString.lowercased()) · shared memory \(binding.profile.allowsSharedMemory ? "allowed" : "off") · extensions \(binding.binding.extensionIDs.joined(separator: ", "))")
        }
        print("\nChange scope: \(plan.changeScope.title)\n\(OutputRedactor.redact(plan.changeScope.summary))")
        for (offset, step) in plan.changeScope.steps.enumerated() { print("  \(offset + 1). \(OutputRedactor.redact(step))") }
        print("\nTask plan:")
        for task in plan.tasks {
            print("  \(task.id) [\(task.role.rawValue)] \(OutputRedactor.redact(task.title)) · dependencies: \(task.dependencies.joined(separator: ", "))")
            print("    \(OutputRedactor.redact(task.prompt))")
        }
        if !plan.extensionActivations.isEmpty {
            print("\nExtension activation manifest:")
            for activation in plan.extensionActivations {
                print("  \(activation.role.rawValue) / \(activation.taskID) / \(activation.extensionID) · \(activation.kind) · config \(activation.configurationDigest)")
                if let reviewedDigest = activation.reviewedDigest { print("    review digest: \(reviewedDigest)") }
                if let commandPath = activation.commandPath { print("    command: \(commandPath) \(activation.arguments.map(\.debugDescription).joined(separator: " "))") }
                for pin in activation.entrypointPins {
                    print("    pinned entrypoint: \(pin.path) · SHA-256 \(pin.digest)")
                }
                if let executableDigest = activation.executableDigest { print("    executable SHA-256: \(executableDigest)") }
                if let targetBundleID = activation.targetBundleID { print("    target bundle ID: \(targetBundleID) · access: \(activation.accessMode ?? "unknown")") }
                if let proxyPath = activation.proxyExecutablePath { print("    AgentBridge proxy: \(proxyPath) · SHA-256 \(activation.proxyExecutableDigest ?? "unknown")") }
                if !activation.permissions.isEmpty { print("    permissions: \(activation.permissions.joined(separator: ", "))") }
                if !activation.allowedActions.isEmpty { print("    allowed actions/tools: \(activation.allowedActions.joined(separator: ", "))") }
                if !activation.targetScope.isEmpty { print("    target scope: \(activation.targetScope.joined(separator: ", "))") }
                if let disclosure = activation.dataDisclosure { print("    data disclosure: \(OutputRedactor.redact(disclosure))") }
                if let callLimit = activation.maximumToolCallsPerRun,
                   let perResultLimit = activation.maximumToolResponseBytes,
                   let totalLimit = activation.maximumTotalToolResponseBytes {
                    print("    tool response limits: \(callLimit) calls · \(perResultLimit) bytes/result · \(totalLimit) bytes/run")
                }
            }
        }
        print("\nReview digest: \(record.planDigest)")
        print("Inspect all scope and verification details, then approve with: autonomous approve \(record.id.uuidString.lowercased()) --digest \(record.planDigest) --confirm")
    }

    static func printAutonomousStatus(_ record: AutonomousRunRecord) {
        print("\(record.id.uuidString.lowercased())  \(record.status.rawValue)  digest=\(record.planDigest)")
        print("  Goal: \(OutputRedactor.redact(record.plan.goal))")
        print("  Review round: \(record.currentReviewRound)/\(record.plan.limits.maxReviewRounds) · provider invocations: \(record.providerInvocationsStarted)/\(record.plan.limits.maxProviderInvocations)")
        for progress in record.taskProgress {
            print("  [\(progress.status.rawValue)] \(progress.id): \(OutputRedactor.redact(progress.summary))")
        }
        if let diffDigest = record.diffDigest { print("  Final diff: \(diffDigest) · review: \(record.reviewVerdict?.rawValue ?? "pending") · verification: \(record.verificationPassed.map(String.init) ?? "not run")") }
        if let writerSessionID = record.writerSessionID { print("  Writer session: \(writerSessionID.uuidString.lowercased())") }
        if let resultSummary = record.resultSummary { print("  Result: \(OutputRedactor.redact(resultSummary))") }
        if record.plan.saveRunSummaryToMemory {
            print("  Project memory summary saved: \(record.memorySummarySaved.map(String.init) ?? "pending")")
        }
    }

    static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        FileHandle.standardOutput.write(try encoder.encode(value))
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    static func autonomousPlan(_ arguments: [String], service: BridgeService) async throws {
        var sourcePath: String?
        var plannerBinding: (AgentProvider, UUID)?
        var roleBindings: [AutonomousRole: (AgentProvider, UUID)] = [:]
        var extensions: [AutonomousRole: [String]] = [:]
        var maxConcurrentAgents = 3
        var maxReviewRounds = 2
        var maxDurationSeconds = 1_800
        var maxProviderInvocations = 20
        var shareDependencies = false
        var shareDiffWithReviewer = false
        var desktopControlScope: String?
        var desktopControlSeparateFromGit = false
        var saveRunSummaryToMemory = false
        var memoryDestinationProfileID: UUID?
        var verificationMode: AutonomousVerificationSelection.Mode = .projectCI
        var verificationExecutable: String?
        var verificationArguments: [String] = []
        var emitJSON = false
        var index = 1
        while index < arguments.count {
            let option = arguments[index]
            index += 1
            switch option {
            case "--source":
                sourcePath = try nextOptionValue(option, arguments: arguments, index: &index)
            case "--planner":
                plannerBinding = try parseProviderProfile(try nextOptionValue(option, arguments: arguments, index: &index))
            case "--researcher", "--implementer", "--reviewer":
                let role = try autonomousRole(for: option)
                roleBindings[role] = try parseProviderProfile(try nextOptionValue(option, arguments: arguments, index: &index))
            case "--researcher-extension", "--implementer-extension", "--reviewer-extension":
                let role: AutonomousRole
                switch option {
                case "--researcher-extension": role = .researcher
                case "--implementer-extension": role = .implementer
                default: role = .reviewer
                }
                extensions[role, default: []].append(try nextOptionValue(option, arguments: arguments, index: &index))
            case "--max-concurrent":
                maxConcurrentAgents = try parseInteger(try nextOptionValue(option, arguments: arguments, index: &index), option: option)
            case "--max-review-rounds":
                maxReviewRounds = try parseInteger(try nextOptionValue(option, arguments: arguments, index: &index), option: option)
            case "--max-duration-seconds":
                maxDurationSeconds = try parseInteger(try nextOptionValue(option, arguments: arguments, index: &index), option: option)
            case "--max-provider-invocations":
                maxProviderInvocations = try parseInteger(try nextOptionValue(option, arguments: arguments, index: &index), option: option)
            case "--share-dependencies": shareDependencies = true
            case "--share-diff-with-reviewer": shareDiffWithReviewer = true
            case "--desktop-control-scope": desktopControlScope = try nextOptionValue(option, arguments: arguments, index: &index)
            case "--confirm-desktop-separate-from-git": desktopControlSeparateFromGit = true
            case "--save-summary-to-memory": saveRunSummaryToMemory = true
            case "--memory-destination":
                let rawValue = try nextOptionValue(option, arguments: arguments, index: &index)
                guard let profileID = UUID(uuidString: rawValue) else { throw AgentBridgeError.invalidInput("--memory-destination requires a profile UUID.") }
                memoryDestinationProfileID = profileID
            case "--verification":
                guard let mode = AutonomousVerificationSelection.Mode(rawValue: try nextOptionValue(option, arguments: arguments, index: &index)) else {
                    throw AgentBridgeError.invalidInput("--verification must be none, projectCI, or custom.")
                }
                verificationMode = mode
            case "--verify-command": verificationExecutable = try nextOptionValue(option, arguments: arguments, index: &index)
            case "--verify-arg": verificationArguments.append(try nextOptionValue(option, arguments: arguments, index: &index))
            case "--json": emitJSON = true
            default: throw AgentBridgeError.invalidInput("Unknown autonomous plan option \(option).")
            }
        }
        guard let sourcePath, let plannerBinding,
              let researcherBinding = roleBindings[.researcher],
              let implementerBinding = roleBindings[.implementer],
              let reviewerBinding = roleBindings[.reviewer] else {
            throw AgentBridgeError.invalidInput("Plan needs --source, --planner PROVIDER:PROFILE-ID, and provider/profile bindings for --researcher, --implementer, and --reviewer.")
        }
        guard shareDiffWithReviewer else {
            throw AgentBridgeError.invalidInput("Add --share-diff-with-reviewer to explicitly allow the exact implementation diff to be reviewed by the selected reviewer profile.")
        }
        guard (desktopControlScope != nil) == desktopControlSeparateFromGit else {
            throw AgentBridgeError.invalidInput("Desktop control requires both --desktop-control-scope and --confirm-desktop-separate-from-git.")
        }
        guard saveRunSummaryToMemory == (memoryDestinationProfileID != nil) else {
            throw AgentBridgeError.invalidInput("Saving a run summary requires both --save-summary-to-memory and --memory-destination PROFILE-ID.")
        }
        let goal = try readBoundedStandardInput(maximumBytes: 8_000, label: "Autonomous goal")
        let planner = try AutonomousRoleBinding(role: .planner, provider: plannerBinding.0, accountProfileID: plannerBinding.1)
        let bindings = try [
            AutonomousRoleBinding(role: .researcher, provider: researcherBinding.0, accountProfileID: researcherBinding.1, extensionIDs: extensions[.researcher] ?? []),
            AutonomousRoleBinding(role: .implementer, provider: implementerBinding.0, accountProfileID: implementerBinding.1, extensionIDs: extensions[.implementer] ?? []),
            AutonomousRoleBinding(role: .reviewer, provider: reviewerBinding.0, accountProfileID: reviewerBinding.1, extensionIDs: extensions[.reviewer] ?? [])
        ]
        let limits = try AutonomousRunLimits(
            maxConcurrentAgents: maxConcurrentAgents,
            maxReviewRounds: maxReviewRounds,
            maxDurationSeconds: maxDurationSeconds,
            maxProviderInvocations: maxProviderInvocations
        )
        let verification: AutonomousVerificationSelection
        switch verificationMode {
        case .none:
            guard verificationExecutable == nil, verificationArguments.isEmpty else {
                throw AgentBridgeError.invalidInput("--verify-command and --verify-arg require --verification custom.")
            }
            verification = .none
        case .projectCI:
            guard verificationExecutable == nil, verificationArguments.isEmpty else {
                throw AgentBridgeError.invalidInput("--verify-command and --verify-arg require --verification custom.")
            }
            verification = .projectCI
        case .custom:
            guard let verificationExecutable else {
                throw AgentBridgeError.invalidInput("--verification custom requires --verify-command EXECUTABLE; use repeated --verify-arg for separate argv values.")
            }
            verification = try .custom(executablePath: verificationExecutable, arguments: verificationArguments)
        }
        let request = try AutonomousRunRequest(
            goal: goal,
            sourceRepositoryPath: sourcePath,
            planner: planner,
            roleBindings: bindings,
            limits: limits,
            shareOutputsWithDependencies: shareDependencies,
            shareDiffWithReviewer: true,
            desktopControlScope: desktopControlScope,
            desktopControlSeparateFromGit: desktopControlSeparateFromGit,
            saveRunSummaryToMemory: saveRunSummaryToMemory,
            memoryDestinationProfileID: memoryDestinationProfileID,
            verification: verification
        )
        let record = try await service.prepareAutonomousRun(request)
        if emitJSON {
            try printJSON(record)
        } else {
            printAutonomousPlan(record)
            print("Planning started a real provider request using the selected official CLI subscription profile. The plan is not approved yet.")
        }
    }

    static func autonomousApprove(_ arguments: [String], service: BridgeService) async throws {
        guard arguments.count == 5,
              let runID = UUID(uuidString: arguments[1]),
              arguments[2] == "--digest",
              arguments[4] == "--confirm" else {
            throw AgentBridgeError.invalidInput("Usage: agentbridge autonomous approve RUN-ID --digest REVIEW-DIGEST --confirm")
        }
        guard let record = try service.autonomousRun(id: runID) else {
            throw AgentBridgeError.invalidInput("Autonomous run not found.")
        }
        guard record.planDigest == arguments[3].lowercased() else {
            throw AgentBridgeError.invalidInput("The reviewed digest does not match the saved autonomous plan.")
        }
        _ = try service.approveAutonomousRun(id: runID, reviewedDigest: record.planDigest)
        print("Approved the reviewed plan and its bounded repair and verification loop for digest \(record.planDigest).")
    }

    static func autonomousRun(_ arguments: [String], service: BridgeService) async throws {
        guard arguments.count == 4,
              let runID = UUID(uuidString: arguments[1]),
              arguments[2] == "--digest" else {
            throw AgentBridgeError.invalidInput("Usage: agentbridge autonomous run RUN-ID --digest REVIEW-DIGEST")
        }
        let cancellation = CancellationFlag()
        let signalSources = makeCancellationSignalSources(cancellation)
        defer { signalSources.forEach { $0.cancel() } }
        let record = try await service.runAutonomousRun(
            id: runID,
            reviewedDigest: arguments[3].lowercased(),
            cancellation: cancellation
        )
        try printJSON(record)
    }

    static func autonomousStatus(_ arguments: [String], service: BridgeService) async throws {
        let remainder = Array(arguments.dropFirst())
        let identifiers = remainder.filter { !$0.hasPrefix("--") }
        let options = Set(remainder.filter { $0.hasPrefix("--") })
        guard options.isSubset(of: ["--json"]), identifiers.count <= 1 else {
            throw AgentBridgeError.invalidInput("Usage: agentbridge autonomous status [RUN-ID] [--json]")
        }
        let records: [AutonomousRunRecord]
        if let identifier = identifiers.first {
            guard let id = UUID(uuidString: identifier) else { throw AgentBridgeError.invalidInput("RUN-ID must be a UUID.") }
            guard let record = try service.autonomousRun(id: id) else {
                throw AgentBridgeError.invalidInput("Autonomous run not found.")
            }
            records = [record]
        } else {
            records = try service.autonomousRuns()
        }
        if options.contains("--json") {
            try printJSON(records)
        } else if records.isEmpty {
            print("No autonomous runs yet.")
        } else {
            for record in records { printAutonomousStatus(record) }
        }
    }
}
