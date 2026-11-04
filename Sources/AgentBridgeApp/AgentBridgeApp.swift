import Combine
import SwiftUI

/// Owns one `AppModel` per window. `AppModel.init` opens the store and
/// refreshes, so it must run once per window; `@StateObject` guarantees that,
/// while a plain `@State` initial value could be evaluated again.
@MainActor
private final class AppModelOwner: ObservableObject {
    let model = AppModel()
}

@main
struct AgentBridgeApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 980, minHeight: 700)
        }
        .windowResizability(.contentSize)
    }
}

struct ContentView: View {
    @StateObject private var owner = AppModelOwner()

    var body: some View {
        MainWindowView(model: owner.model)
    }
}
