import SwiftUI

struct RootView: View {
    @Environment(LocationService.self) private var service
    /// Remembered across launches; can also be set with the launch argument `-selectedTab stats`.
    @AppStorage("selectedTab") private var selectedTab = "map"

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Map", systemImage: "map", value: "map") { FogMapView() }
            Tab("Stats", systemImage: "chart.bar", value: "stats") { StatsView() }
        }
        // Until location access has been asked for; answering the iOS prompt dismisses it.
        .fullScreenCover(isPresented: .constant(service.authorization == .notDetermined)) {
            WelcomeView()
                .environment(service)
        }
        .onAppear {
            // Status and Log were tabs before they moved into Settings.
            if selectedTab != "map" && selectedTab != "stats" {
                selectedTab = "map"
            }
        }
    }
}
