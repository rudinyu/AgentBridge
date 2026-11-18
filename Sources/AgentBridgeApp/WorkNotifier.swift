import AppKit
import AgentBridgeCore
import Foundation
import Observation
import UserNotifications

/// What a finished-work notification opens when clicked.
enum WorkNotificationTarget: Equatable, Sendable {
    case session(UUID)
    case autonomousRun(UUID)

    private static let sessionKey = "agentBridgeSessionID"
    private static let autonomousRunKey = "agentBridgeAutonomousRunID"

    /// Only IDs go into `userInfo`; they say nothing about the work itself.
    var userInfo: [String: String] {
        switch self {
        case .session(let id): [Self.sessionKey: id.uuidString]
        case .autonomousRun(let id): [Self.autonomousRunKey: id.uuidString]
        }
    }

    /// The target a clicked notification names, or nil for anything else, such
    /// as a usage alert, which carries no ID.
    init?(userInfo: [AnyHashable: Any]) {
        if let raw = userInfo[Self.sessionKey] as? String, let id = UUID(uuidString: raw) {
            self = .session(id)
        } else if let raw = userInfo[Self.autonomousRunKey] as? String, let id = UUID(uuidString: raw) {
            self = .autonomousRun(id)
        } else {
            return nil
        }
    }
}

/// A change run, verification or autonomous workflow this app started that has
/// just ended. It holds only what a notification may show: the repository path
/// (cut to its folder name when shown) and the providers, never prompts or output.
struct FinishedWork: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case changeRun(succeeded: Bool)
        case verification(passed: Bool)
        /// Nil when the run's final status could not be read.
        case autonomousWorkflow(AutonomousRunStatus?)
    }

    var outcome: Outcome
    var target: WorkNotificationTarget
    var repositoryPath: String
    var providers: [AgentProvider]
    /// The user stopped a change run or verification themselves, so they already know.
    var cancelledByUser = false
}

/// The title and body of one notification, already in the app language.
struct WorkNotificationContent: Equatable, Sendable {
    let title: String
    let body: String
    let userInfo: [String: String]
}

/// Sends a macOS notification when long-running work ends while the app is in
/// the background, and opens that work when the notification is clicked. The
/// setting is app-wide, so one instance serves every window.
@MainActor
@Observable
final class WorkNotifier {
    static let preferenceKey = "notifyWhenWorkFinishes"
    static let shared = WorkNotifier(defaults: .standard)

    private(set) var isEnabled: Bool
    /// Why the setting could not be turned on, in English; shown localized.
    var status = ""

    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let isAppActive: @MainActor () -> Bool
    @ObservationIgnored private let deliver: @MainActor (WorkNotificationContent) -> Void
    @ObservationIgnored private var models: [WeakAppModel] = []
    /// A click that arrived before any window's model was ready, such as one
    /// that launched the app.
    @ObservationIgnored private var pendingTarget: WorkNotificationTarget?

    /// `defaults` nil keeps the setting in memory only, for tests.
    init(
        defaults: UserDefaults?,
        isAppActive: @escaping @MainActor () -> Bool = { NSApp?.isActive ?? false },
        deliver: @escaping @MainActor (WorkNotificationContent) -> Void = WorkNotifier.postToNotificationCenter
    ) {
        self.defaults = defaults
        self.isAppActive = isAppActive
        self.deliver = deliver
        isEnabled = defaults?.bool(forKey: Self.preferenceKey) ?? false
    }

    // MARK: Decisions

    /// Notify only for work the user did not stop themselves, only with the
    /// setting on, and only while they are not looking at the app.
    nonisolated static func shouldNotify(_ work: FinishedWork, isEnabled: Bool, appIsActive: Bool) -> Bool {
        guard isEnabled, !appIsActive else { return false }
        switch work.outcome {
        case .changeRun, .verification: return !work.cancelledByUser
        // A workflow ending for any reason is worth knowing about.
        case .autonomousWorkflow: return true
        }
    }

    /// The English title for an outcome; it is a table key.
    nonisolated static func title(for outcome: FinishedWork.Outcome) -> String {
        switch outcome {
        case .changeRun(let succeeded): succeeded ? "Change run finished" : "Change run failed"
        case .verification(let passed): passed ? "Verification passed" : "Verification failed"
        case .autonomousWorkflow(let status):
            switch status {
            case .completed: "Autonomous workflow finished"
            case .failed: "Autonomous workflow failed"
            case .cancelled: "Autonomous workflow cancelled"
            case .timedOut: "Autonomous workflow timed out"
            case .blocked: "Autonomous workflow blocked"
            case .interrupted: "Autonomous workflow interrupted"
            case .awaitingApproval, .approved, .running, nil: "Autonomous workflow ended"
            }
        }
    }

    /// Notifications show on the lock screen, so the body names only the
    /// repository folder and the providers, never a prompt, output or full path.
    nonisolated static func content(for work: FinishedWork, language: AppLanguage) -> WorkNotificationContent {
        let folder = URL(fileURLWithPath: work.repositoryPath).lastPathComponent
        let providerNames = AgentProvider.allCases
            .filter { work.providers.contains($0) }
            .map { providerName($0, language: language) }
            .joined(separator: ", ")
        let body = [folder.isEmpty || folder == "/" ? nil : folder, providerNames.isEmpty ? nil : providerNames]
            .compactMap { $0 }
            .joined(separator: " · ")
        return WorkNotificationContent(
            title: AppLocalization.display(title(for: work.outcome), language: language),
            body: body,
            userInfo: work.target.userInfo
        )
    }

    nonisolated private static func providerName(_ provider: AgentProvider, language: AppLanguage) -> String {
        switch provider {
        case .codex: "Codex"
        case .claude: "Claude"
        case .local: AppLocalization.display("Local model", language: language)
        }
    }

    // MARK: Sending

    func workFinished(_ work: FinishedWork, language: AppLanguage) {
        // Check the setting first so a disabled notifier never asks AppKit anything.
        guard isEnabled, Self.shouldNotify(work, isEnabled: isEnabled, appIsActive: isAppActive()) else { return }
        deliver(Self.content(for: work, language: language))
    }

    static func postToNotificationCenter(_ content: WorkNotificationContent) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            // Permission can be withdrawn in System Settings after the toggle was turned on.
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let notification = UNMutableNotificationContent()
            notification.title = content.title
            notification.body = content.body
            notification.sound = .default
            notification.userInfo = content.userInfo
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: notification, trigger: nil))
        }
    }

    // MARK: Setting

    /// Turning the setting on asks for permission first; if macOS refuses, the
    /// setting goes back off and the status says why.
    func setEnabled(_ enabled: Bool) {
        status = ""
        guard enabled else {
            store(false)
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            let message = error?.localizedDescription
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let notifier = WorkNotifier.shared
                    notifier.store(granted)
                    if let message {
                        notifier.status = "Could not turn on work notifications: \(message)"
                    } else if !granted {
                        notifier.status = "macOS notification permission was not granted, so work notifications stay off."
                    }
                }
            }
        }
    }

    private func store(_ enabled: Bool) {
        isEnabled = enabled
        defaults?.set(enabled, forKey: Self.preferenceKey)
    }

    // MARK: Clicks

    private struct WeakAppModel {
        weak var model: AppModel?
    }

    /// Each window's model registers so a click can find the one that has the work.
    func register(_ model: AppModel) {
        models.removeAll { $0.model == nil }
        models.append(WeakAppModel(model: model))
        if let target = pendingTarget, model.openFinishedWork(target) {
            pendingTarget = nil
        }
    }

    /// Brings the app forward and opens the work in the first window that has it.
    /// Work that no longer exists only activates the app.
    func open(_ target: WorkNotificationTarget?) {
        NSApp?.activate()
        guard let target else { return }
        let live = models.compactMap(\.model)
        if live.isEmpty {
            pendingTarget = target
            return
        }
        _ = live.first { $0.openFinishedWork(target) }
    }
}

/// Routes clicks on notifications to `WorkNotifier`. Set once at app start;
/// `willPresent` is left out so notifications still stay hidden while the app
/// is frontmost, as usage alerts always have.
final class WorkNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = WorkNotificationDelegate()

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let target = WorkNotificationTarget(userInfo: response.notification.request.content.userInfo)
        await MainActor.run { WorkNotifier.shared.open(target) }
    }
}
