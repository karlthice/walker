import CoreLocation
import SwiftUI

struct StatusView: View {
    @Environment(LocationService.self) private var service
    @State private var storedPoints = 0
    @State private var exploredTiles = 0

    var body: some View {
        @Bindable var service = service
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Location access", value: service.authorization.label)
                    LabeledContent("Precise location", value: service.preciseLocation ? "On" : "Off")
                    if let title = permissionButtonTitle {
                        Button(title) { service.requestPermission() }
                    }
                } header: {
                    Text("Permission")
                } footer: {
                    if let warning = permissionWarning {
                        Text(warning).foregroundStyle(.orange)
                    }
                }

                Section("Tracking") {
                    Toggle("Track in background", isOn: $service.isEnabled)
                    LabeledContent("State", value: service.state.rawValue)
                    if let point = service.lastAccepted {
                        LabeledContent("Last point") {
                            Text(point.timestamp, style: .relative) + Text(" ago")
                        }
                        LabeledContent("Accuracy", value: "±\(Int(point.accuracy)) m")
                    }
                }

                Section("Data") {
                    LabeledContent("Stored points", value: "\(storedPoints)")
                    LabeledContent("Explored tiles", value: "\(exploredTiles)")
                    LabeledContent("Accepted this session", value: "\(service.acceptedThisSession)")
                    LabeledContent("Rejected this session", value: "\(service.rejectedThisSession)")
                }
            }
            .navigationTitle("Walker")
            .task(id: service.revision) {
                storedPoints = service.store.pointCount()
                exploredTiles = service.store.tileCount(zoom: FogGrid.fineCellZoom - FogGrid.tileShift)
            }
        }
    }

    private var permissionButtonTitle: String? {
        switch service.authorization {
        case .notDetermined: "Allow location access"
        case .authorizedWhenInUse: "Allow access Always"
        case .denied, .restricted: "Open Settings"
        default: nil
        }
    }

    private var permissionWarning: String? {
        if service.authorization == .authorizedWhenInUse {
            return "Walker needs \"Always\" access to clear fog while the app is closed."
        }
        if service.isAuthorized && !service.preciseLocation {
            return "Turn on Precise Location in Settings; approximate location is too coarse to clear fog."
        }
        return nil
    }
}
