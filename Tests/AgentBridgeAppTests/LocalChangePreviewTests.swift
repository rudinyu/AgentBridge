import AgentBridgeCore
import XCTest
@testable import AgentBridgeApp

@MainActor
final class LocalChangePreviewTests: XCTestCase {
    func testRunAndFailedVerificationPreviewsStaySeparateAndIncludeTheRightFiles() async throws {
        let model = try makeTestAppModel()
        let service = try XCTUnwrap(model.service)
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalChangePreviewTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: source) }
        try Data("Read me\n".utf8).write(to: source.appendingPathComponent("README.md"))
        try Data("Original changelog\n".utf8).write(to: source.appendingPathComponent("CHANGELOG.md"))
        try runFixtureGit(["init", "-q", source.path])
        try runFixtureGit(["-C", source.path, "add", "README.md", "CHANGELOG.md"])
        try runFixtureGit(["-C", source.path, "commit", "-q", "-m", "initial"])

        var settings = try service.settings()
        settings.localModel = LocalModelSettings(
            backend: .ollama,
            endpoint: "http://127.0.0.1:11434",
            model: "fixture-local",
            contextWindowTokens: 8_192,
            maxOutputTokens: 1_024
        )
        try service.saveSettings(settings)
        let session = try await service.createSession(sourcePath: source.path, provider: .local, accessMode: .isolatedChanges)
        let plan = try service.createChangePlan(
            sessionID: session.id,
            title: "Update files",
            summary: "Edit the selected inputs.",
            steps: ["Make the requested edits."]
        )
        _ = try service.approveChangePlan(sessionID: session.id, planID: plan.id, reviewedDigest: plan.reviewDigest)

        let workspace = URL(fileURLWithPath: session.workspacePath, isDirectory: true)
        try Data("Changed before verification\n".utf8).write(to: workspace.appendingPathComponent("CHANGELOG.md"))
        var failedSession = try XCTUnwrap(service.store.session(id: session.id))
        let failedAt = Date()
        failedSession.lastChangeRunAt = failedAt
        failedSession.verificationPassed = false
        failedSession.verificationCompletedAt = failedAt.addingTimeInterval(1)
        try service.store.saveSession(failedSession)
        let diff = try await service.changesDiff(sessionID: session.id)

        model.selectedSessionID = session.id
        model.refresh()
        model.changes.loadChangePlanDraftFromSelectedSession()
        try await waitUntil {
            !model.changes.isLoadingLocalFileCandidates
                && (!model.changes.localFileCandidates.isEmpty || model.changes.localFileCandidatesError != nil)
        }
        XCTAssertNil(model.changes.localFileCandidatesError, model.changes.localFileCandidatesError ?? "")
        XCTAssertEqual(model.changes.localFileCandidates.map(\.path), ["CHANGELOG.md", "README.md"])
        // A changed file the picker cannot offer is left out of the fix, not forced in.
        try Data([0x00, 0xFF, 0x00]).write(to: workspace.appendingPathComponent("logo.bin"))
        model.changes.changeDiff = diff
        model.changes.verificationResult = VerificationResult(
            command: VerificationCommand(executablePath: "/bin/false", arguments: [], workingDirectoryPath: session.workspacePath),
            exitCode: 1,
            durationSeconds: 0.1,
            standardOutput: "",
            standardError: "fixture failure detail",
            wasCancelled: false,
            timedOut: false
        )
        model.prompt = "Apply the ordinary approved change request."
        model.changes.selectedLocalPaths = ["README.md"]
        model.changes.localNewFilePathsText = "notes/new.txt"
        model.changes.localFixNote = "Keep the fix narrow."
        model.changes.refreshLocalPreviews()

        try await waitUntil {
            (model.changes.localChangePreview != nil && model.changes.localFixPreview != nil
                && !model.changes.isLoadingLocalChangePreview && !model.changes.isLoadingLocalFixPreview)
                || model.changes.localChangePreviewError != nil || model.changes.localFixPreviewError != nil
        }

        let changePreview = try XCTUnwrap(
            model.changes.localChangePreview,
            model.changes.localChangePreviewError ?? "Expected a normal change preview."
        )
        let fixPreview = try XCTUnwrap(
            model.changes.localFixPreview,
            model.changes.localFixPreviewError ?? "Expected a failed-verification fix preview."
        )
        XCTAssertEqual(changePreview.files.map(\.path), ["README.md"])
        XCTAssertEqual(fixPreview.files.map(\.path), ["CHANGELOG.md", "README.md"])
        XCTAssertEqual(fixPreview.skippedChangedPaths, ["logo.bin"])
        XCTAssertTrue(changePreview.skippedChangedPaths.isEmpty)
        XCTAssertTrue(changePreview.fitsAllBudgets)
        XCTAssertGreaterThan(fixPreview.totalInputBytes, changePreview.totalInputBytes)
        XCTAssertNil(model.changes.localChangePreviewError)
        XCTAssertNil(model.changes.localFixPreviewError)

        var sessionAfterRun = try XCTUnwrap(service.store.session(id: session.id))
        sessionAfterRun.approvedChangePlanDigest = nil
        sessionAfterRun.approvedChangePlanMemoryDigest = nil
        try service.store.saveSession(sessionAfterRun)
        model.refresh()
        model.changes.refreshLocalPreviews()
        try await waitUntil {
            model.changes.localChangePreview == nil
                && model.changes.localFixPreview == nil
                && !model.changes.isLoadingLocalChangePreview
                && !model.changes.isLoadingLocalFixPreview
        }

        try await waitUntil { !model.changeDiffLoadsInFlight.contains(session.id) }
        model.changes.approveChangePlan()
        try await waitUntil {
            (model.changes.localChangePreview != nil && model.changes.localFixPreview != nil
                && !model.changes.isLoadingLocalChangePreview && !model.changes.isLoadingLocalFixPreview)
                || model.changes.localChangePreviewError != nil || model.changes.localFixPreviewError != nil
        }
        XCTAssertNotNil(model.changes.localChangePreview, model.changes.localChangePreviewError ?? "Reapproval should refresh the change preview.")
        XCTAssertNotNil(model.changes.localFixPreview, model.changes.localFixPreviewError ?? "Reapproval should refresh the fix preview.")
    }

    func testPreviewRefreshesAreDebouncedAndCancellable() async throws {
        let debouncer = DebouncedTask(delayNanoseconds: 50_000_000)
        var runs: [Int] = []
        for value in 1...5 {
            debouncer.schedule { _ in runs.append(value) }
        }
        try await waitUntil { !runs.isEmpty }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(runs, [5], "Only the latest refresh in a burst runs.")

        debouncer.schedule { _ in runs.append(6) }
        debouncer.cancel()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(runs, [5], "A cancelled refresh never starts.")

        var started = false
        var sawSuperseded = false
        var gateOpen = false
        debouncer.schedule { isCurrent in
            started = true
            while !gateOpen { try? await Task.sleep(nanoseconds: 5_000_000) }
            sawSuperseded = !isCurrent()
        }
        // Cancel only once the refresh is running; a fixed sleep can cancel it before
        // the debounce delay ends on a slow machine, and then it never starts.
        try await waitUntil { started }
        debouncer.cancel()
        gateOpen = true
        try await waitUntil { sawSuperseded }
    }

    private struct Timeout: Error {}

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            guard Date() < deadline else { throw Timeout() }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
