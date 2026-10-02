import SwiftUI
import UIKit

@main
struct WalkerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(LocationService.shared)
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
