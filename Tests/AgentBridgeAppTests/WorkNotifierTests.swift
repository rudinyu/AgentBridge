import AgentBridgeCore
import XCTest
@testable import AgentBridgeApp

@MainActor
final class WorkNotifierTests: XCTestCase {
    private let sessionID = UUID()

    private func work(_ outcome: FinishedWork.Outcome, cancelledByUser: Bool = false, path: String = "/Users/someone/Projects/acme-app") -> FinishedWork {
        FinishedWork(outcome: outcome, target: .session(sessionID), repositoryPath: path, providers: [.codex], cancelledByUser: cancelledByUser)
    }

    func testEveryEndedOutcomeNotifiesWhileInTheBackground() {
        let outcomes: [FinishedWork.Outcome] = [
            .changeRun(succeeded: true), .changeRun(succeeded: false),
            .verification(passed: true), .verification(passed: false),
            .autonomousWorkflow(.completed), .autonomousWorkflow(.failed), .autonomousWorkflow(.cancelled),
            .autonomousWorkflow(.timedOut), .autonomousWorkflow(.blocked), .autonomousWorkflow(.interrupted),
            .autonomousWorkflow(nil)
        ]
        for outcome in outcomes {
            XCTAssertTrue(WorkNotifier.shouldNotify(work(outcome), isEnabled: true, appIsActive: false), "\(outcome)")
        }
    }

    func testAUserCancelOnlySilencesChangeRunsAndVerifications() {
        XCTAssertFalse(WorkNotifier.shouldNotify(work(.changeRun(succeeded: false), cancelledByUser: true), isEnabled: true, appIsActive: false))
        XCTAssertFalse(WorkNotifier.shouldNotify(work(.verification(passed: false), cancelledByUser: true), isEnabled: true, appIsActive: false))
        // A workflow notifies however it ended, a cancel included.
        XCTAssertTrue(WorkNotifier.shouldNotify(work(.autonomousWorkflow(.cancelled), cancelledByUser: true), isEnabled: true, appIsActive: false))
    }

    func testNothingIsSentWhileFrontmostOrWithTheSettingOff() {
        XCTAssertFalse(WorkNotifier.shouldNotify(work(.changeRun(succeeded: true)), isEnabled: true, appIsActive: true))
        XCTAssertFalse(WorkNotifier.shouldNotify(work(.changeRun(succeeded: true)), isEnabled: false, appIsActive: false))

        var sent: [WorkNotificationContent] = []
        var active = true
        var askedWhetherActive = false
        let notifier = WorkNotifier(defaults: nil, isAppActive: { askedWhetherActive = true; return active }, deliver: { sent.append($0) })
        XCTAssertFalse(notifier.isEnabled, "The setting is off by default.")
        active = false
        notifier.workFinished(work(.verification(passed: true)), language: .english)
        XCTAssertEqual(sent, [])
        XCTAssertFalse(askedWhetherActive, "A disabled notifier does not ask AppKit anything.")
    }

    func testTheSettingIsOffByDefaultAndReadFromItsOwnKey() throws {
        let suite = "WorkNotifierTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(WorkNotifier(defaults: defaults, isAppActive: { false }, deliver: { _ in }).isEnabled)
        defaults.set(true, forKey: WorkNotifier.preferenceKey)
        XCTAssertTrue(WorkNotifier(defaults: defaults, isAppActive: { false }, deliver: { _ in }).isEnabled)
        XCTAssertNotEqual(WorkNotifier.preferenceKey, AppLanguage.preferenceKey)
    }

    func testTitlesSayWhatHappened() {
        XCTAssertEqual(WorkNotifier.title(for: .changeRun(succeeded: true)), "Change run finished")
        XCTAssertEqual(WorkNotifier.title(for: .changeRun(succeeded: false)), "Change run failed")
        XCTAssertEqual(WorkNotifier.title(for: .verification(passed: true)), "Verification passed")
        XCTAssertEqual(WorkNotifier.title(for: .verification(passed: false)), "Verification failed")
        XCTAssertEqual(WorkNotifier.title(for: .autonomousWorkflow(.cancelled)), "Autonomous workflow cancelled")
        XCTAssertEqual(WorkNotifier.title(for: .autonomousWorkflow(.running)), "Autonomous workflow ended")
    }

    func testEveryTitleHasATraditionalChineseTranslation() {
        let outcomes: [FinishedWork.Outcome] = [
            .changeRun(succeeded: true), .changeRun(succeeded: false),
            .verification(passed: true), .verification(passed: false),
            .autonomousWorkflow(.completed), .autonomousWorkflow(.failed), .autonomousWorkflow(.cancelled),
            .autonomousWorkflow(.timedOut), .autonomousWorkflow(.blocked), .autonomousWorkflow(.interrupted),
            .autonomousWorkflow(nil)
        ]
        let table = AppLocalization.chineseTable
        for outcome in outcomes {
            let title = WorkNotifier.title(for: outcome)
            XCTAssertNotNil(table[title], title)
            XCTAssertEqual(WorkNotifier.content(for: work(outcome), language: .traditionalChinese).title, table[title])
        }
    }

    func testTheBodyIsOnlyTheFolderNameAndProviders() {
        let content = WorkNotifier.content(for: work(.changeRun(succeeded: true)), language: .english)
        XCTAssertEqual(content.body, "acme-app · Codex")
        XCTAssertEqual(content.userInfo, ["agentBridgeSessionID": sessionID.uuidString])

        let runID = UUID()
        let workflow = FinishedWork(
            outcome: .autonomousWorkflow(.completed),
            target: .autonomousRun(runID),
            repositoryPath: "/repos/acme-app/",
            providers: [.claude, .codex, .claude]
        )
        XCTAssertEqual(WorkNotifier.content(for: workflow, language: .english).body, "acme-app · Codex, Claude")
        XCTAssertEqual(
            WorkNotifier.content(for: FinishedWork(outcome: .verification(passed: true), target: .session(sessionID), repositoryPath: "/r/x", providers: [.local]), language: .traditionalChinese).body,
            "x · 本機模型"
        )
    }

    func testNotificationTextNeverCarriesPromptsOutputOrPaths() {
        // Work values that look like prompts, model output, errors or diffs must
        // not reach the notification; only the folder name may.
        let secretParent = "/Users/someone/secret-client"
        let path = "\(secretParent)/acme-app"
        let leaks = ["secret-client", "/Users", "someone", "API_KEY=sk-123", "diff --git", "Traceback"]
        let outcomes: [FinishedWork.Outcome] = [
            .changeRun(succeeded: false), .verification(passed: false), .autonomousWorkflow(.failed), .autonomousWorkflow(nil)
        ]
        for outcome in outcomes {
            for language in AppLanguage.allCases {
                let content = WorkNotifier.content(for: work(outcome, path: path), language: language)
                for leak in leaks {
                    XCTAssertFalse(content.title.contains(leak), "\(outcome) title: \(content.title)")
                    XCTAssertFalse(content.body.contains(leak), "\(outcome) body: \(content.body)")
                }
                XCTAssertTrue(content.body.hasPrefix("acme-app"))
                XCTAssertFalse(content.userInfo.values.contains { $0.contains("acme-app") })
            }
        }
    }

    func testClickTargetsRoundTripThroughUserInfo() {
        let runID = UUID()
        XCTAssertEqual(WorkNotificationTarget(userInfo: WorkNotificationTarget.session(sessionID).userInfo), .session(sessionID))
        XCTAssertEqual(WorkNotificationTarget(userInfo: WorkNotificationTarget.autonomousRun(runID).userInfo), .autonomousRun(runID))
        // Usage alerts and anything malformed carry no target.
        XCTAssertNil(WorkNotificationTarget(userInfo: [:]))
        XCTAssertNil(WorkNotificationTarget(userInfo: ["agentBridgeSessionID": "not-a-uuid"]))
        XCTAssertNil(WorkNotificationTarget(userInfo: ["agentBridgeSessionID": 42]))
    }

    func testAClickForAMissingSessionOrRunSelectsNothing() throws {
        let model = try makeTestAppModel(sessions: [
            SessionRecord(provider: .codex, sourceRepositoryPath: "/tmp/repo", workspacePath: "/tmp/ws", snapshotCommit: String(repeating: "a", count: 40), sourceWasDirty: false)
        ])
        let selectedBefore = model.selectedSessionID
        let runBefore = model.selectedAutonomousRunID
        XCTAssertFalse(model.openFinishedWork(.session(UUID())))
        XCTAssertFalse(model.openFinishedWork(.autonomousRun(UUID())))
        XCTAssertEqual(model.selectedSessionID, selectedBefore)
        XCTAssertEqual(model.selectedAutonomousRunID, runBefore)
        XCTAssertFalse(model.isProjectConversationActive)
        XCTAssertNil(model.openedFinishedWork)
    }

    func testAClickForAnExistingSessionOpensIt() throws {
        let model = try makeTestAppModel(sessions: [
            SessionRecord(provider: .codex, sourceRepositoryPath: "/tmp/repo-a", workspacePath: "/tmp/ws-a", snapshotCommit: String(repeating: "a", count: 40), sourceWasDirty: false),
            SessionRecord(provider: .claude, sourceRepositoryPath: "/tmp/repo-b", workspacePath: "/tmp/ws-b", snapshotCommit: String(repeating: "b", count: 40), sourceWasDirty: false)
        ])
        let other = try XCTUnwrap(model.sessions.first { $0.id != model.selectedSessionID })
        XCTAssertTrue(model.openFinishedWork(.session(other.id)))
        XCTAssertEqual(model.selectedSessionID, other.id)
        XCTAssertTrue(model.isProjectConversationActive)
        XCTAssertEqual(model.openedFinishedWork, .session(other.id))
    }

    func testTheTestModelNeverSends() throws {
        let model = try makeTestAppModel()
        XCTAssertFalse(model.workNotifier.isEnabled)
        XCTAssertFalse(model.workNotifier === WorkNotifier.shared)
    }
}
