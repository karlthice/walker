import CoreLocation
import SwiftUI

/// Tracking, access, your data and credits; opened from the gear on the map.
struct SettingsView: View {
    @Environment(LocationService.self) private var service
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false
    @State private var deleteError: String?
    private let photos = PhotoLibrary.shared

    var body: some View {
        @Bindable var service = service
        NavigationStack {
            Form {
                Section {
                    Toggle("Track in background", isOn: $service.isEnabled)
                } footer: {
                    Text("Walker clears the fog wherever you go, even when the app is closed. Turn this off to pause.")
                }

                Section {
                    LabeledContent("Location", value: service.authorization.label)
                    if service.isAuthorized {
                        LabeledContent("Precise location", value: service.preciseLocation ? "On" : "Off")
                    }
                    if let title = locationButtonTitle {
                        Button(title) { service.requestPermission() }
                    }
                    LabeledContent("Photos", value: photoAccessLabel)
                    if let title = photosButtonTitle {
                        Button(title) { openSettings() }
                    }
                } header: {
                    Text("Access")
                } footer: {
                    if let warning = locationWarning {
                        Text(warning).foregroundStyle(.orange)
                    } else {
                        Text("Your tracks and photos never leave this iPhone.")
                    }
                }

                Section {
                    Button("Delete All Data", role: .destructive) { confirmingDelete = true }
                        // On the button, so the confirmation points at it.
                        .confirmationDialog("Delete all data?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                            Button("Delete All Data", role: .destructive) { deleteAll() }
                        } message: {
                            Text("Your tracks, the explored map and your stats will be removed from this iPhone. This can't be undone.")
                        }
                } footer: {
                    Text("Removes your tracks, the explored map and your stats from this iPhone. Your photos are not touched.")
                }

                Section("About") {
                    LabeledContent("Version", value: Self.version)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Country borders from Natural Earth. City boundaries © OpenStreetMap contributors.")
                        Link("openstreetmap.org/copyright", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                    }
                    .font(.footnote)
                    Text("© 2026 Stratos ehf.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                #if DEBUG
                DiagnosticsSection()
                #endif
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Couldn't delete your data", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(deleteError ?? "")
            }
            .task {
                // Reads the current access only; asking happens from the map's photo button.
                photos.refreshAccess()
            }
        }
    }

    private func deleteAll() {
        do {
            try service.deleteAllData()
        } catch {
            deleteError = "Try again after unlocking your iPhone. (\(error.localizedDescription))"
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    private var locationButtonTitle: String? {
        switch service.authorization {
        case .notDetermined: "Allow Location Access"
        case .authorizedWhenInUse: "Allow Access Always"
        case .denied, .restricted: "Open Settings"
        default: nil
        }
    }

    private var locationWarning: String? {
        switch service.authorization {
        case .authorizedWhenInUse:
            "Walker needs \"Always\" access to clear fog while the app is closed."
        case .denied, .restricted:
            "Walker can't clear the fog without location access."
        default:
            service.isAuthorized && !service.preciseLocation
                ? "Turn on Precise Location in Settings; approximate location is too coarse to clear fog."
                : nil
        }
    }

    private var photoAccessLabel: String {
        switch photos.access {
        case .authorized: "All photos"
        case .limited: "Selected photos"
        case .denied: "Denied"
        case .restricted: "Restricted"
        default: "Not asked"
        }
    }

    private var photosButtonTitle: String? {
        switch photos.access {
        case .limited: "Allow Access to All Photos"
        case .denied, .restricted: "Open Settings for Photos"
        default: nil
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

#if DEBUG
/// What the Status tab showed during development, plus the event log.
private struct DiagnosticsSection: View {
    @Environment(LocationService.self) private var service
    @State private var storedPoints = 0
    @State private var exploredTiles = 0

    var body: some View {
        Section("Diagnostics") {
            LabeledContent("State", value: service.state.rawValue)
            if let point = service.lastAccepted {
                LabeledContent("Last point") {
                    Text(point.timestamp, style: .relative) + Text(" ago")
                }
                LabeledContent("Accuracy", value: "±\(Int(point.accuracy)) m")
            }
            LabeledContent("Stored points", value: "\(storedPoints)")
            LabeledContent("Explored tiles", value: "\(exploredTiles)")
            LabeledContent("Accepted / rejected", value: "\(service.acceptedThisSession) / \(service.rejectedThisSession)")
            NavigationLink("Log") { LogView() }
        }
        .task(id: service.revision) {
            storedPoints = service.store.pointCount()
            exploredTiles = service.store.tileCount(zoom: FogGrid.fineTileZoom)
        }
    }
}
#endif
