import AppKit
import Combine
import SwiftUI
import UserNotifications

/// Sets the notification delegate before launch finishes, so a click that
/// launches the app is still delivered.
final class AgentBridgeAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // UNUserNotificationCenter stops the process when it is not running from an
        // app bundle, as with `swift run`.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        UNUserNotificationCenter.current().delegate = WorkNotificationDelegate.shared
    }
}

/// Owns one `AppModel` per window. `AppModel.init` opens the store and
/// refreshes, so it must run once per window; `@StateObject` guarantees that,
/// while a plain `@State` initial value could be evaluated again.
@MainActor
private final class AppModelOwner: ObservableObject {
    let model = AppModel()
}

@main
struct AgentBridgeApp: App {
    @NSApplicationDelegateAdaptor(AgentBridgeAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1160, minHeight: 780)
        }
        // The header draws its own title, so hide the system one and leave room
        // under the window buttons instead of relying on the OS default, which
        // lets content run underneath the title bar.
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}

struct ContentView: View {
    @StateObject private var owner = AppModelOwner()

    var body: some View {
        MainWindowView(model: owner.model)
    }
}
