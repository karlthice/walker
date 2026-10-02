import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            Tab("Status", systemImage: "location.circle") { StatusView() }
            Tab("Track", systemImage: "map") { TrackView() }
            Tab("Log", systemImage: "list.bullet.rectangle") { LogView() }
        }
    }
}
