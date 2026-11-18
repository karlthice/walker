import SwiftUI

/// Shows what happened while the app was in the background: launches, pauses, geofence exits.
struct LogView: View {
    @Environment(LocationService.self) private var service
    @State private var events: [LogEvent] = []

    var body: some View {
        NavigationStack {
            List(events) { event in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(event.kind.rawValue.uppercased())
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(event.kind.color)
                        Spacer()
                        Text(event.timestamp.formatted(date: .abbreviated, time: .standard))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(event.message)
                        .font(.subheadline)
                }
            }
            .overlay {
                if events.isEmpty {
                    ContentUnavailableView("No events yet", systemImage: "list.bullet.rectangle")
                }
            }
            .navigationTitle("Log")
            .task(id: service.revision) {
                events = service.store.recentEvents()
            }
        }
    }
}

private extension LogKind {
    var color: Color {
        switch self {
        case .launch: .purple
        case .auth: .indigo
        case .resume: .green
        case .pause: .orange
        case .geofence: .teal
        case .visit: .blue
        case .info: .secondary
        case .error: .red
        }
    }
}
