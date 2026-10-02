import SwiftUI

struct RootView: View {
    /// Remembered across launches; can also be set with the launch argument `-selectedTab stats`.
    @AppStorage("selectedTab") private var selectedTab = "map"

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Map", systemImage: "map", value: "map") { FogMapView() }
            Tab("Stats", systemImage: "chart.bar", value: "stats") { StatsView() }
            Tab("Status", systemImage: "location.circle", value: "status") { StatusView() }
            Tab("Log", systemImage: "list.bullet.rectangle", value: "log") { LogView() }
        }
    }
}
