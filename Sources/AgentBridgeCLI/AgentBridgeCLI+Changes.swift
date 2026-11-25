import Darwin
import Foundation
import AgentBridgeCore

extension AgentBridgeCLI {
    static func changesCommand(_ arguments: [String], service: BridgeService) async throws {
        guard let action = arguments.first else {
            throw AgentBridgeError.invalidInput("Usage: agentbridge changes draft|plan|approve|run|fix|diff|restore|restore-all|export|verify|accept|apply|pr|explain|summarize ...")
        }
        switch action {
        case "draft":
            try await changesDraft(arguments, service: service)
        case "plan":
            try await changesPlan(arguments, service: service)
        case "approve":
            try await changesApprove(arguments, service: service)
        case "run":
            try await changesRun(arguments, service: service)
        case "fix":
            try await changesFix(arguments, service: service)
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
            print("To commit, push and open a pull request, run `agentbridge changes pr \(sessionID.uuidString.lowercased())` to review it first.")
        case "pr":
            try await changesPullRequest(arguments, service: service)
        case "explain":
            try await changesExplain(arguments, service: service)
        case "summarize":
            try await changesSummarize(arguments, service: service)
        default:
            throw AgentBridgeError.invalidInput("Unknown changes subcommand \(action).")
        }
    }

    /// Without `--confirm` this prints what would be committed, pushed and opened
    /// and changes nothing. With it, it runs the steps that are not done yet.
    static func changesPullRequest(_ arguments: [String], service: BridgeService) async throws {
        let usage = "Usage: agentbridge changes pr SESSION-ID [--remote NAME] [--base BRANCH] [--title TEXT] [--body-file PATH] [--message-file PATH] [--no-draft] [--draft-text-with-local [--preview]] [--confirm]"
        guard arguments.count >= 2, let sessionID = UUID(uuidString: arguments[1]) else {
            throw AgentBridgeError.invalidInput(usage)
        }
        var remote: String?
        var base: String?
        var title: String?
        var bodyPath: String?
        var messagePath: String?
        var draft = true
        var confirmed = false
        var draftTextWithLocal = false
        var previewLocal = false
        var index = 2
        while index < arguments.count {
            let option = arguments[index]
            index += 1
            switch option {
            case "--no-draft": draft = false; continue
            case "--confirm": confirmed = true; continue
            case "--draft-text-with-local": draftTextWithLocal = true; continue
            case "--preview": previewLocal = true; continue
            default: break
            }
            guard index < arguments.count else { throw AgentBridgeError.invalidInput("\(option) needs a value.") }
            let value = arguments[index]
            index += 1
            switch option {
            case "--remote": remote = value
            case "--base": base = value
            case "--title": title = value
            case "--body-file": bodyPath = value
            case "--message-file": messagePath = value
            default: throw AgentBridgeError.invalidInput("Unknown changes pr option \(option).")
            }
        }
        if previewLocal {
            guard draftTextWithLocal, !confirmed else { throw AgentBridgeError.invalidInput("--preview goes with --draft-text-with-local and without --confirm.") }
            printLocalHelperPreview(try await service.localHelperPullRequestPreview(sessionID: sessionID))
            return
        }
        guard !(draftTextWithLocal && confirmed) else {
            throw AgentBridgeError.invalidInput("A local model draft is never committed unread. Run without --confirm to see the draft, save the text you want in files, then confirm with --message-file, --body-file and --title.")
        }
        let preview = try await service.pullRequestPreview(sessionID: sessionID, remote: remote, base: base)
        guard let selectedRemote = preview.selectedRemote else {
            throw AgentBridgeError.invalidInput("The source repository has no remote to push to. Add one with `git remote add`, then try again.")
        }
        guard let chosenBase = preview.proposedBase else {
            throw AgentBridgeError.invalidInput("The remote's default branch could not be found. Pass the base branch with --base.")
        }
        // The local model drafts only the text that no option or file gave; without
        // a draft, the proposed text is kept and the reason is printed.
        var proposed = PullRequestDraftText(commitMessage: preview.commitMessage, title: preview.pullRequestTitle, body: preview.pullRequestBody)
        if draftTextWithLocal {
            let cancellation = CancellationFlag()
            let signalSources = makeCancellationSignalSources(cancellation)
            defer { signalSources.forEach { $0.cancel() } }
            FileHandle.standardError.write(Data("• Asking the local model to draft the commit and pull request text…\n".utf8))
            let outcome = try await service.draftPullRequestTextWithLocalModel(sessionID: sessionID, cancellation: cancellation)
            if let note = outcome.preview?.truncationNotes.first { print(note) }
            if let text = outcome.draft {
                proposed = text
                print("The commit message, title and description below are the local model's draft. Read them before you confirm.")
                if text.commitSubjectIsLong { print("The commit subject is longer than 72 characters.") }
            } else {
                print("Kept the proposed text. \(outcome.fallbackReason ?? "")")
            }
        }
        let request = PullRequestRequest(
            remote: selectedRemote,
            base: chosenBase,
            commitMessage: try messagePath.map { try readPullRequestTextFile($0, label: "Commit message") } ?? proposed.commitMessage,
            title: title ?? proposed.title,
            body: try bodyPath.map { try readPullRequestTextFile($0, label: "Pull request body") } ?? proposed.body,
            draft: draft
        )
        printPullRequestPreview(preview, request: request)
        guard confirmed else {
            print("\nNothing was committed, pushed or opened. Run the same command with --confirm to do it.")
            return
        }
        switch preview.gitHubCLI {
        case .notInstalled:
            throw AgentBridgeError.invalidInput("The GitHub CLI (gh) is not installed. Install it with `brew install gh`, then try again.")
        case .notAuthenticated:
            throw AgentBridgeError.invalidInput("The GitHub CLI is not signed in. Sign in with `gh auth login` in Terminal, then try again.")
        case .ready:
            break
        }
        let cancellation = CancellationFlag()
        let signalSources = makeCancellationSignalSources(cancellation)
        defer { signalSources.forEach { $0.cancel() } }
        print("")
        let outcome = try await service.openPullRequest(sessionID: sessionID, request: request, cancellation: cancellation) { step in
            FileHandle.standardError.write(Data("• \(pullRequestStepName(step))…\n".utf8))
        }
        for result in outcome.steps {
            let state = switch result.outcome {
            case .done: "done"
            case .alreadyDone: "already done earlier"
            case .reusedExisting: "an open pull request already existed"
            }
            print("\(pullRequestStepName(result.step)): \(state) (\(result.detail))")
        }
        print("Pull request: \(outcome.pullRequestURL)")
        print("Nothing was merged.")
    }

    static func pullRequestStepName(_ step: PullRequestStep) -> String {
        switch step {
        case .commit: "Commit"
        case .push: "Push"
        case .pullRequest: "Pull request"
        }
    }

    private static func printPullRequestPreview(_ preview: PullRequestPreview, request: PullRequestRequest) {
        let remoteURL = preview.remotes.first(where: { $0.name == request.remote })?.pushURL ?? ""
        print("Branch: \(preview.branchName)")
        print("Worktree: \(preview.worktreePath)")
        print("Remotes:")
        for remote in preview.remotes {
            print("  \(remote.name == request.remote ? "*" : " ") \(remote.name)  \(remote.pushURL)")
        }
        print("Push: \(preview.branchName) to \(request.remote) (\(remoteURL)), without force")
        print("Base branch: \(request.base)")
        print("Draft: \(request.draft ? "yes" : "no")")
        switch preview.gitHubCLI {
        case .notInstalled: print("GitHub CLI: not installed (install it with `brew install gh`)")
        case .notAuthenticated: print("GitHub CLI: not signed in (sign in with `gh auth login` in Terminal)")
        case .ready(let path): print("GitHub CLI: signed in (\(path))")
        }
        if !preview.completedSteps.isEmpty {
            print("Already done: \(preview.completedSteps.map(pullRequestStepName).joined(separator: ", "))")
        }
        if preview.appliedCommit == nil {
            print("Files to commit (\(preview.changedFiles.count)):")
            preview.changedFiles.forEach { print("  \($0)") }
        }
        if !preview.worktreeMatchesVerifiedDiff {
            print("Warning: the apply worktree no longer matches the verified changes, so the commit will be refused.")
        }
        print("\n--- Commit message ---\n\(request.commitMessage)")
        print("--- Pull request title ---\n\(request.title)")
        print("--- Pull request body ---\n\(request.body)")
        print("This commits in the apply worktree, pushes the branch to \(remoteURL) and opens a pull request on GitHub. Your code leaves this Mac. Nothing is merged.")
    }

    private static func readPullRequestTextFile(_ path: String, label: String) throws -> String {
        guard !path.isEmpty else { throw AgentBridgeError.invalidInput("\(label) needs a file path.") }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let data = try BoundedDescriptorFileReader.read(at: url, maximumBytes: 60_000)
        guard let text = String(data: data, encoding: .utf8) else { throw AgentBridgeError.invalidInput("\(label) must be UTF-8 text.") }
        return text
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

    /// Prints a drafted plan without saving it; `changes plan` saves it.
    static func changesDraft(_ arguments: [String], service: BridgeService) async throws {
        guard (arguments.count == 2 || (arguments.count == 3 && arguments[2] == "--json")),
              let sessionID = UUID(uuidString: arguments[1]) else {
            throw AgentBridgeError.invalidInput("Usage: agentbridge changes draft SESSION-ID [--json] < request.txt")
        }
        let request = try readBoundedStandardInput(maximumBytes: BridgeService.maximumChangePlanRequestBytes, label: "Change request")
        let cancellation = CancellationFlag()
        let signalSources = makeCancellationSignalSources(cancellation)
        defer { signalSources.forEach { $0.cancel() } }
        let draft = try await service.draftChangePlan(sessionID: sessionID, request: request, cancellation: cancellation) { progress in
            FileHandle.standardError.write(Data("• \(OutputRedactor.redact(progress))\n".utf8))
        }
        if arguments.count == 3 {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            FileHandle.standardOutput.write(try encoder.encode(draft) + Data("\n".utf8))
            return
        }
        print("Drafted plan (not saved):")
        print("Title: \(draft.title)\nSummary: \(draft.summary)\nSteps:")
        for (offset, step) in draft.steps.enumerated() { print("  \(offset + 1). \(step)") }
        print("Nothing was saved or approved. Edit the plan as needed, then save it with `changes plan`.")
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
        guard arguments.count >= 4,
              let sessionID = UUID(uuidString: arguments[1]),
              let planID = UUID(uuidString: arguments[2]) else {
            throw AgentBridgeError.invalidInput("Usage: agentbridge changes run SESSION-ID PLAN-ID REVIEW-DIGEST [--file PATH ...] [--new-file PATH ...] [--preview] < request.txt")
        }
        let session = try requireSession(sessionID, service: service)
        if session.provider == .local {
            var files: [String] = []
            var newFiles: [String] = []
            var previewOnly = false
            var index = 4
            while index < arguments.count {
                let option = arguments[index]
                index += 1
                switch option {
                case "--file": files.append(try nextOptionValue(option, arguments: arguments, index: &index))
                case "--new-file": newFiles.append(try nextOptionValue(option, arguments: arguments, index: &index))
                case "--preview": previewOnly = true
                default: throw AgentBridgeError.invalidInput("Unknown Local changes run option \(option).")
                }
            }
            let request = try readBoundedStandardInput(maximumBytes: 8_000, label: "Change request")
            let digest = arguments[3].lowercased()
            if previewOnly {
                let preview = try await service.previewLocalChangeInput(
                    sessionID: sessionID,
                    planID: planID,
                    reviewedDigest: digest,
                    request: request,
                    filePaths: files,
                    newFilePaths: newFiles
                )
                printLocalChangePreview(preview)
                return
            }
            let cancellation = CancellationFlag()
            let signalSources = makeCancellationSignalSources(cancellation)
            defer { signalSources.forEach { $0.cancel() } }
            let result = try await service.runLocalChanges(
                sessionID: sessionID,
                request: request,
                planID: planID,
                reviewedDigest: digest,
                filePaths: files,
                newFilePaths: newFiles,
                cancellation: cancellation
            ) { progress in
                FileHandle.standardError.write(Data("• \(OutputRedactor.redact(progress))\n".utf8))
            }
            print("Local model summary: \(OutputRedactor.redact(result.summary))")
            result.changedPaths.forEach { print("  \($0)") }
            return
        }
        guard arguments.count == 4 else {
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

    static func changesFix(_ arguments: [String], service: BridgeService) async throws {
        guard arguments.count >= 2, let sessionID = UUID(uuidString: arguments[1]) else {
            throw AgentBridgeError.invalidInput("Usage: agentbridge changes fix SESSION-ID [--file PATH ...] [--new-file PATH ...] [--command LABEL] [--exit-code N] [--note TEXT] < verification-output.txt")
        }
        var files: [String] = []
        var newFiles: [String] = []
        var command = ".codex/ci.sh"
        var exitCode: Int32?
        var note = ""
        var index = 2
        while index < arguments.count {
            let option = arguments[index]
            index += 1
            switch option {
            case "--file": files.append(try nextOptionValue(option, arguments: arguments, index: &index))
            case "--new-file": newFiles.append(try nextOptionValue(option, arguments: arguments, index: &index))
            case "--command": command = try nextOptionValue(option, arguments: arguments, index: &index)
            case "--exit-code":
                guard let value = Int32(try nextOptionValue(option, arguments: arguments, index: &index)) else {
                    throw AgentBridgeError.invalidInput("--exit-code needs an integer.")
                }
                exitCode = value
            case "--note": note = try nextOptionValue(option, arguments: arguments, index: &index)
            default: throw AgentBridgeError.invalidInput("Unknown changes fix option \(option).")
            }
        }
        let output = try readBoundedStandardInput(maximumBytes: 2 * 1_024 * 1_024, label: "Verification output")
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentBridgeError.invalidInput("Pipe the failed verification output to standard input, as for `changes explain`.")
        }
        let failure = LocalHelperVerificationFailure(commandLabel: command, exitCode: exitCode, output: output)
        let cancellation = CancellationFlag()
        let signalSources = makeCancellationSignalSources(cancellation)
        defer { signalSources.forEach { $0.cancel() } }
        let result = try await service.fixLocalChanges(
            sessionID: sessionID,
            failure: failure,
            note: note,
            filePaths: files,
            newFilePaths: newFiles,
            cancellation: cancellation
        ) { progress in
            FileHandle.standardError.write(Data("• \(OutputRedactor.redact(progress))\n".utf8))
        }
        print("Local model summary: \(OutputRedactor.redact(result.summary))")
        result.changedPaths.forEach { print("  \($0)") }
        printSkippedChangedPaths(result.skippedChangedPaths)
    }

    private static func printLocalChangePreview(_ preview: LocalChangeInputPreview) {
        print("Local model input: \(preview.totalInputBytes) / \(preview.budgetBytes) bytes")
        for file in preview.files {
            print("  \(file.byteCount) bytes  \(file.path)")
        }
        print("Output reserve: up to \(preview.estimatedOutputBytes) / \(preview.outputBudgetBytes) bytes (selected files returned in full)")
        printSkippedChangedPaths(preview.skippedChangedPaths)
        if preview.overBudgetBytes > 0 { print("Over budget by \(preview.overBudgetBytes) bytes; nothing was sent.") }
        if preview.overOutputBudgetBytes > 0 {
            print("Output reserve short by \(preview.overOutputBudgetBytes) bytes; nothing was sent. Select fewer or smaller files, or raise it with `agentbridge local configure --max-output N`.")
        }
        if preview.fitsAllBudgets { print("Within budget; nothing was sent.") }
        printLocalChangeBatches(preview)
    }

    static func printLocalChangeBatches(_ preview: LocalChangeInputPreview) {
        if !preview.suggestedBatches.isEmpty {
            print("Suggested split: \(preview.suggestedBatches.count) runs that each fit. Run them one at a time with these --file options; each run needs the plan approved again.")
            for (index, batch) in preview.suggestedBatches.enumerated() {
                print("  Run \(index + 1): " + batch.map { "--file \($0)" }.joined(separator: " "))
            }
        }
        if !preview.filesTooLargeAlone.isEmpty {
            print("Too large to send even on their own (raise the context window or output reserve, or leave them out):")
            preview.filesTooLargeAlone.forEach { print("  \($0)") }
        }
    }

    private static func printSkippedChangedPaths(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        print("Changed files left out (binary, over 256 KiB, ignored or not selectable; not modifiable this round):")
        paths.forEach { print("  \($0)") }
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
