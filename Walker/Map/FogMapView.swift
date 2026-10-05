import MapKit
import SwiftUI

struct FogMapView: View {
    @Environment(LocationService.self) private var service
    @AppStorage("showRawPath") private var showPoints = false
    @State private var points: [LocationPoint] = []

    var body: some View {
        // Showing the raw path lifts the fog, so the path can be seen against the whole map.
        FogMap(revision: service.revision, points: showPoints ? points : [], showsFog: !showPoints)
            .ignoresSafeArea(edges: .top)
            .overlay(alignment: .topLeading) {
                Button {
                    showPoints.toggle()
                } label: {
                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                        .font(.title3)
                        .foregroundStyle(showPoints ? Color.orange : Color.primary)
                        .frame(width: 44, height: 44)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
                .accessibilityLabel(showPoints ? "Hide raw points" : "Show raw points")
                .padding()
            }
            .task(id: "\(showPoints)-\(service.revision)") {
                if showPoints {
                    points = service.store.points(since: .distantPast)
                }
            }
    }
}

private struct FogMap: UIViewRepresentable {
    let revision: Int
    let points: [LocationPoint]
    let showsFog: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.showsScale = true
        map.setUserTrackingMode(.follow, animated: false)
        map.addOverlay(context.coordinator.fog, level: .aboveLabels)

        let button = MKUserTrackingButton(mapView: map)
        button.backgroundColor = .secondarySystemBackground
        button.layer.cornerRadius = 10
        button.translatesAutoresizingMaskIntoConstraints = false
        map.addSubview(button)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 44),
            button.heightAnchor.constraint(equalToConstant: 44),
            button.trailingAnchor.constraint(equalTo: map.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            button.bottomAnchor.constraint(equalTo: map.safeAreaLayoutGuide.bottomAnchor, constant: -16),
        ])
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        let fogShown = map.overlays.contains { $0 === coordinator.fog }
        if showsFog && !fogShown {
            map.insertOverlay(coordinator.fog, at: 0, level: .aboveLabels)
        } else if !showsFog && fogShown {
            map.removeOverlay(coordinator.fog)
        }
        if coordinator.revision != revision {
            coordinator.revision = revision
            coordinator.reader.invalidateAll()
            coordinator.fogRenderer?.setNeedsDisplay()
        }
        if coordinator.pathPoints != points {
            coordinator.pathPoints = points
            if let path = coordinator.path {
                map.removeOverlay(path)
                coordinator.path = nil
            }
            if points.count > 1 {
                let path = MKPolyline(coordinates: points.map(\.coordinate), count: points.count)
                map.addOverlay(path, level: .aboveLabels)
                coordinator.path = path
            }
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        let fog = FogOverlay()
        let reader = TileReader()
        var fogRenderer: FogRenderer?
        var path: MKPolyline?
        var pathPoints: [LocationPoint] = []
        var revision = -1

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let overlay = overlay as? FogOverlay {
                let renderer = FogRenderer(overlay: overlay, reader: reader)
                fogRenderer = renderer
                return renderer
            }
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = .systemOrange
                renderer.lineWidth = 2
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}
