import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            Tab("Map", systemImage: "map") { FogMapView() }
            Tab("Status", systemImage: "location.circle") { StatusView() }
            Tab("Log", systemImage: "list.bullet.rectangle") { LogView() }
        }
    }
}
