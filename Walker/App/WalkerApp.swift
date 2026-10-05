import SwiftUI
import UIKit

@main
struct WalkerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(LocationService.shared)
        }
        .onChange(of: scenePhase) { _, phase in
            // Lets gaps in the path be matched against when the app was open.
            switch phase {
            case .active: LocationService.shared.log(.info, "App opened")
            case .background: LocationService.shared.log(.info, "App in background")
            default: break
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Location services must be restarted here: when iOS relaunches the app in the
    /// background for a location event, no scene (and no SwiftUI view) is created.
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let service = LocationService.shared
        if launchOptions?[.location] != nil {
            service.log(.launch, "Relaunched in background by a location event")
        } else {
            // applicationState is always .background here under the scene lifecycle, so it can't tell us more.
            service.log(.launch, "Launched")
        }
        service.bootstrap()
        return true
    }
}
