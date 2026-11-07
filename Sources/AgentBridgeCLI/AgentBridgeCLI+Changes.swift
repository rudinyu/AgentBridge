import Darwin
import Foundation
import AgentBridgeCore

extension AgentBridgeCLI {
    static func changesCommand(_ arguments: [String], service: BridgeService) async throws {
        guard let action = arguments.first else {
            throw AgentBridgeError.invalidInput("Usage: agentbridge changes plan|approve|run|diff|restore|restore-all|export|verify|accept|apply ...")
        }
        switch action {
        case "plan":
            try await changesPlan(arguments, service: service)
        case "approve":
            try await changesApprove(arguments, service: service)
        case "run":
            try await changesRun(arguments, service: service)
        case "diff":
            guard arguments.count == 2, let sessionID = UUID(uuidString: arguments[1]) else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge changes diff SESSION-ID")
            }
            let diff = try await service.changesDiff(sessionID: sessionID)
            for file in diff.files {
                print("\n--- \(file.status.rawValue) \(file.path) ---")
                if file.isBinary { print("[binary file]") }
                else if file.isTooLargeToDisplay { print("[diff too long to show; use `changes export` to review it]") }
                else {
                    if file.hasUndecodableText { print("[not UTF-8; some characters are shown as replacements]") }
                    print(file.patch, terminator: "")
                }
            }
            if diff.files.isEmpty { print("The isolated workspace has no differences.") }
            if !diff.partiallyShownFiles.isEmpty {
                print("\n\(diff.partiallyShownFiles.count) file(s) are not fully shown. Review them with `changes export`, then pass --confirm-partial \(diff.digest) to accept or apply.")
            }
            if !diff.ignoredPaths.isEmpty {
                print("\n\(diff.ignoredPaths.count) Git-ignored path(s) are in the workspace but not in this diff. Verification does not see them, and they will not reach your branch:")
                diff.ignoredPaths.forEach { print("  \($0)") }
            }
        case "restore":
            guard arguments.count >= 3, let sessionID = UUID(uuidString: arguments[1]) else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge changes restore SESSION-ID RELATIVE-PATH [RELATIVE-PATH ...]")
            }
            try await service.restoreChangeFiles(sessionID: sessionID, filePaths: Array(arguments.dropFirst(2)))
            print("Restored the listed isolated-workspace files; the source repository was not changed.")
        case "restore-all":
            guard arguments.count == 3, let sessionID = UUID(uuidString: arguments[1]), arguments[2] == "--confirm" else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge changes restore-all SESSION-ID --confirm")
            }
            try await service.restoreAllChanges(sessionID: sessionID)
            print("Restored the isolated workspace to the base commit; the source repository was not changed.")
        case "export":
            guard arguments.count == 3, let sessionID = UUID(uuidString: arguments[1]) else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge changes export SESSION-ID /absolute/path/to/changes.patch")
            }
            let destination = URL(fileURLWithPath: arguments[2]).standardizedFileURL
            guard destination.path.hasPrefix("/"), !destination.path.contains("\0") else {
                throw AgentBridgeError.invalidInput("Patch output needs a valid absolute path.")
            }
            let patch = try await service.exportChangePatch(sessionID: sessionID)
            try writeNewPrivateFile(patch, to: destination)
            print("Exported a \(patch.count)-byte patch to \(destination.path).")
        case "verify":
            try await changesVerify(arguments, service: service)
        case "accept":
            guard arguments.count == 3 || (arguments.count == 5 && arguments[3] == "--confirm-partial"),
                  let sessionID = UUID(uuidString: arguments[1]), arguments[2] == "--confirm" else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge changes accept SESSION-ID --confirm [--confirm-partial DIFF-DIGEST]")
            }
            _ = try await service.acceptChanges(sessionID: sessionID, partiallyShownFilesConfirmedDigest: arguments.count == 5 ? arguments[4] : nil)
            print("Accepted the currently verified isolated diff; the source repository is still unchanged.")
        case "apply":
            guard arguments.count == 3 || (arguments.count == 5 && arguments[3] == "--confirm-partial"),
                  let sessionID = UUID(uuidString: arguments[1]) else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge changes apply SESSION-ID LOCAL-BRANCH [--confirm-partial DIFF-DIGEST]")
            }
            let result = try await service.applyChangesToLocalBranch(
                sessionID: sessionID,
                branchName: arguments[2],
                partiallyShownFilesConfirmedDigest: arguments.count == 5 ? arguments[4] : nil
            )
            print("Created a worktree: \(result.worktreePath) (branch \(result.branchName), \(result.changedFileCount) file(s)).")
            print("The worktree is left uncommitted; AgentBridge did not commit, push or merge.")
        default:
            throw AgentBridgeError.invalidInput("Unknown changes subcommand \(action).")
        }
    }

    static func requireSession(_ id: UUID, service: BridgeService) throws -> SessionRecord {
        guard let session = try service.sessions().first(where: { $0.id == id }) else {
            throw AgentBridgeError.sessionNotFound(id)
        }
        return session
    }

    static func writeNewPrivateFile(_ data: Data, to url: URL) throws {
        let descriptor = url.path.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        }
        guard descriptor >= 0 else {
            throw AgentBridgeError.persistence("Patch output already exists or cannot be created safely.")
        }
        defer { _ = close(descriptor) }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw AgentBridgeError.persistence("Could not secure patch output file.")
        }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw AgentBridgeError.persistence("Could not write patch output file.")
                }
                guard written > 0 else { throw AgentBridgeError.persistence("Patch output write was incomplete.") }
                offset += written
            }
        }
        guard fsync(descriptor) == 0 else { throw AgentBridgeError.persistence("Could not sync patch output file.") }
    }

    static func tasksCommand(_ arguments: [String], service: BridgeService) throws {
        guard arguments.count <= 1 else { throw AgentBridgeError.invalidInput("Usage: agentbridge tasks [SESSION-ID]") }
        let sessionID = arguments.first.flatMap(UUID.init(uuidString:))
        guard arguments.isEmpty || sessionID != nil else { throw AgentBridgeError.invalidInput("SESSION-ID must be a valid UUID.") }
        let records = try service.taskRecords(sessionID: sessionID)
        if records.isEmpty { print("No task records yet."); return }
        for task in records {
            print("\(task.id.uuidString.lowercased())  \(task.status.rawValue)  approval=\(task.approvalState.rawValue)  session=\(task.sessionID.uuidString.lowercased())")
            print("  \(OutputRedactor.redact(task.progressSummary))")
            for reference in task.references {
                print("  \(reference.kind.rawValue): \(OutputRedactor.redact(reference.value))")
            }
        }
    }

    static func changesPlan(_ arguments: [String], service: BridgeService) async throws {
        guard arguments.count >= 2, let sessionID = UUID(uuidString: arguments[1]) else {
            throw AgentBridgeError.invalidInput("Usage: agentbridge changes plan SESSION-ID --title TITLE --summary SUMMARY --step STEP [--step STEP ...]")
        }
        var title: String?
        var summary: String?
        var steps: [String] = []
        var includesSharedMemory = false
        var index = 2
        while index < arguments.count {
            let option = arguments[index]
            index += 1
            if option == "--with-memory" {
                includesSharedMemory = true
                continue
            }
            guard index < arguments.count else { throw AgentBridgeError.invalidInput("\(option) needs a value.") }
            switch option {
            case "--title": title = arguments[index]
            case "--summary": summary = arguments[index]
            case "--step": steps.append(arguments[index])
            default: throw AgentBridgeError.invalidInput("Unknown changes plan option \(option).")
            }
            index += 1
        }
        guard let title, let summary else { throw AgentBridgeError.invalidInput("Specify --title and --summary.") }
        let plan = try service.createChangePlan(
            sessionID: sessionID, title: title, summary: summary, steps: steps, includesSharedMemory: includesSharedMemory
        )
        print("Plan awaiting review: \(plan.id.uuidString.lowercased())")
        print("Title: \(plan.title)\nSummary: \(plan.summary)")
        print("Shared memory: \(plan.includesSharedMemory ? "included, as it is when the plan is approved" : "not included")\nSteps:")
        for (offset, step) in plan.steps.enumerated() { print("  \(offset + 1). \(step)") }
        print("Review digest: \(plan.reviewDigest)")
        print("The plan is not approved; it does not authorize writes yet.")
    }

    static func changesApprove(_ arguments: [String], service: BridgeService) async throws {
        guard arguments.count == 4,
              let sessionID = UUID(uuidString: arguments[1]),
              let planID = UUID(uuidString: arguments[2]) else {
            throw AgentBridgeError.invalidInput("Usage: agentbridge changes approve SESSION-ID PLAN-ID REVIEW-DIGEST")
        }
        let session = try requireSession(sessionID, service: service)
        guard let plan = session.changePlan, plan.id == planID, plan.reviewDigest == arguments[3].lowercased() else {
            throw AgentBridgeError.invalidChangePlan("The plan ID or digest does not match what is currently saved.")
        }
        print("Review the plan below item by item. Change runs unlock only after you approve it explicitly:")
        print("\(plan.title)\n\(plan.summary)")
        for (offset, step) in plan.steps.enumerated() { print("  \(offset + 1). \(step)") }
        print("Type the exact text APPROVE \(plan.reviewDigest) to approve:")
        guard readLine(strippingNewline: true) == "APPROVE \(plan.reviewDigest)" else {
            throw AgentBridgeError.invalidChangePlan("The full review digest was not entered; the plan is still not approved.")
        }
        _ = try service.approveChangePlan(sessionID: sessionID, planID: planID, reviewedDigest: plan.reviewDigest)
        print("Explicitly approved the current work plan.")
    }

    static func changesRun(_ arguments: [String], service: BridgeService) async throws {
        guard arguments.count == 4,
              let sessionID = UUID(uuidString: arguments[1]),
              let planID = UUID(uuidString: arguments[2]) else {
            throw AgentBridgeError.invalidInput("Usage: agentbridge changes run SESSION-ID PLAN-ID REVIEW-DIGEST < prompt.txt")
        }
        let prompt = try readPromptFromStandardInput(maximumBytes: 256_000)
        let cancellation = CancellationFlag()
        let signalSources = makeCancellationSignalSources(cancellation)
        defer { signalSources.forEach { $0.cancel() } }
        let output = try await service.runChanges(
            sessionID: sessionID,
            prompt: prompt,
            planID: planID,
            reviewedDigest: arguments[3].lowercased(),
            cancellation: cancellation
        ) { progress in
            FileHandle.standardError.write(Data("• \(OutputRedactor.redact(progress))\n".utf8))
        }
        FileHandle.standardOutput.write(Data((OutputRedactor.redact(output.text) + "\n").utf8))
    }

    static func changesVerify(_ arguments: [String], service: BridgeService) async throws {
        guard arguments.count >= 2, let sessionID = UUID(uuidString: arguments[1]) else {
            throw AgentBridgeError.invalidInput("Usage: agentbridge changes verify SESSION-ID [--custom /absolute/executable --approve-custom [--arg ARG ...]]")
        }
        var customPath: URL?
        var approved = false
        var verifierArguments: [String] = []
        var index = 2
        while index < arguments.count {
            switch arguments[index] {
            case "--custom":
                index += 1
                guard index < arguments.count, customPath == nil else { throw AgentBridgeError.invalidInput("--custom needs one absolute executable path.") }
                customPath = URL(fileURLWithPath: arguments[index])
            case "--approve-custom": approved = true
            case "--arg":
                index += 1
                guard index < arguments.count else { throw AgentBridgeError.invalidInput("--arg needs one argument value.") }
                verifierArguments.append(arguments[index])
            default: throw AgentBridgeError.invalidInput("Unknown changes verify option \(arguments[index]).")
            }
            index += 1
        }
        guard customPath == nil || approved else {
            throw AgentBridgeError.verificationCommandRejected("Custom verification also needs --approve-custom; each --arg is passed as a separate argv entry and never goes through a shell.")
        }
        let cancellation = CancellationFlag()
        let signalSources = makeCancellationSignalSources(cancellation)
        defer { signalSources.forEach { $0.cancel() } }
        let result = try await service.runVerification(
            sessionID: sessionID,
            customExecutableURL: customPath,
            arguments: verifierArguments,
            customCommandApproved: customPath != nil && approved,
            cancellation: cancellation
        )
        print("Executable: \(OutputRedactor.redact(result.command?.executablePath ?? "not launched"))")
        print("Exit code: \(result.exitCode.map(String.init) ?? "not provided"); duration: \(String(format: "%.3f", result.durationSeconds)) s; succeeded: \(result.succeeded ? "yes" : "no")")
        if let skipped = result.skippedReason { print("Skipped: \(OutputRedactor.redact(skipped))") }
        if !result.standardOutput.isEmpty { print("\n[stdout]\n\(result.standardOutput)") }
        if !result.standardError.isEmpty { FileHandle.standardError.write(Data("\n[stderr]\n\(result.standardError)\n".utf8)) }
    }
}
