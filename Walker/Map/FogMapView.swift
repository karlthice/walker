import MapKit
import SwiftUI

struct FogMapView: View {
    @Environment(LocationService.self) private var service
    @AppStorage("showRawPath") private var showPoints = false
    @AppStorage("pathByAge") private var pathByAge = true
    @State private var points: [LocationPoint] = []

    var body: some View {
        // Showing the raw path lifts the fog, so the path can be seen against the whole map.
        FogMap(revision: service.revision, points: showPoints ? points : [], pathByAge: pathByAge, showsFog: !showPoints)
            .ignoresSafeArea(edges: .top)
            .overlay(alignment: .topLeading) {
                VStack(spacing: 8) {
                    mapButton("point.topleft.down.to.point.bottomright.curvepath", isOn: showPoints,
                              label: showPoints ? "Hide raw path" : "Show raw path") {
                        showPoints.toggle()
                    }
                    if showPoints {
                        mapButton("clock.arrow.circlepath", isOn: pathByAge,
                                  label: pathByAge ? "Draw the path in one style" : "Fade the path by age") {
                            pathByAge.toggle()
                        }
                    }
                }
                .padding()
            }
            .task(id: "\(showPoints)-\(service.revision)") {
                if showPoints {
                    points = service.store.points(since: .distantPast)
                }
            }
    }

    private func mapButton(_ symbol: String, isOn: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(isOn ? Color.orange : Color.primary)
                .frame(width: 44, height: 44)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
        .accessibilityLabel(label)
    }
}

private struct FogMap: UIViewRepresentable {
    let revision: Int
    let points: [LocationPoint]
    let pathByAge: Bool
    let showsFog: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.showsScale = true
        map.setUserTrackingMode(.follow, animated: false)
        map.addOverlay(context.coordinator.fog, level: .aboveLabels)
        context.coordinator.headingBeam = HeadingBeamController(map: map)

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
        if coordinator.pathPoints != points || coordinator.pathByAge != pathByAge {
            coordinator.pathPoints = points
            coordinator.pathByAge = pathByAge
            map.removeOverlays(coordinator.paths)
            coordinator.paths = PathAge.polylines(for: points, byAge: pathByAge)
            map.addOverlays(coordinator.paths, level: .aboveLabels)
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        let fog = FogOverlay()
        let reader = TileReader()
        var fogRenderer: FogRenderer?
        var paths: [PathPolyline] = []
        var pathPoints: [LocationPoint] = []
        var pathByAge = true
        var revision = -1
        var headingBeam: HeadingBeamController?

        func mapView(_ mapView: MKMapView, didAdd views: [MKAnnotationView]) {
            headingBeam?.update()
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            headingBeam?.update()
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let overlay = overlay as? FogOverlay {
                let renderer = FogRenderer(overlay: overlay, reader: reader)
                fogRenderer = renderer
                return renderer
            }
            if let path = overlay as? PathPolyline {
                let renderer = MKPolylineRenderer(polyline: path)
                renderer.strokeColor = PathAge.color(step: path.step)
                renderer.lineWidth = PathAge.width(step: path.step)
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}
