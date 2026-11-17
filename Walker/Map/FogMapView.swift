import MapKit
import SwiftUI

struct FogMapView: View {
    @Environment(LocationService.self) private var service
    @AppStorage("showRawPath") private var showPoints = false
    @AppStorage("pathByAge") private var pathByAge = true
    @AppStorage("showPhotos") private var showPhotos = false
    @State private var points: [LocationPoint] = []
    @State private var openPhotos: PhotoSelection?
    @State private var photoAccessAlert = false
    private let photos = PhotoLibrary.shared

    var body: some View {
        // Showing the raw path lifts the fog, so the path can be seen against the whole map.
        FogMap(revision: service.revision, points: showPoints ? points : [], pathByAge: pathByAge, showsFog: !showPoints,
               photos: showPhotos ? photos.pins : [], photoVersion: showPhotos ? photos.version : -1,
               openPhotos: { openPhotos = PhotoSelection(pins: $0) })
            .ignoresSafeArea(edges: .top)
            .overlay(alignment: .topLeading) {
                VStack(spacing: 8) {
                    mapButton("photo.on.rectangle.angled", isOn: showPhotos,
                              label: showPhotos ? "Hide photos" : "Show photos") {
                        Task { await togglePhotos() }
                    }
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
            .task(id: showPhotos) {
                // Loads only if access was granted before; never asks on its own.
                guard showPhotos else { return }
                photos.refreshAccess()
                if photos.canRead {
                    photos.loadIfNeeded()
                } else {
                    // Access was taken away in Settings since photos were turned on.
                    showPhotos = false
                }
            }
            .fullScreenCover(item: $openPhotos) { selection in
                PhotoViewer(pins: selection.pins)
            }
            .alert("Walker can't see your photos", isPresented: $photoAccessAlert) {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Allow access to Photos in Settings to show your photos on the map. They never leave this iPhone.")
            }
    }

    private func togglePhotos() async {
        if showPhotos {
            showPhotos = false
            return
        }
        photos.refreshAccess()
        if photos.access == .notDetermined {
            await photos.requestAccess()
        }
        if photos.canRead {
            showPhotos = true
            photos.loadIfNeeded()
        } else {
            photoAccessAlert = true
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
    let photos: [PhotoPin]
    /// Changes whenever `photos` does, so pins are only synced then, not on every location fix.
    let photoVersion: Int
    let openPhotos: ([PhotoPin]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.showsScale = true
        map.setUserTrackingMode(.follow, animated: false)
        map.register(PhotoGroupView.self, forAnnotationViewWithReuseIdentifier: PhotoGroupView.reuseID)
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
        coordinator.openPhotos = openPhotos
        if coordinator.photoVersion != photoVersion {
            coordinator.photoVersion = photoVersion
            coordinator.syncPhotos(photos, on: map)
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
        var photoVersion = -1
        var openPhotos: ([PhotoPin]) -> Void = { _ in }
        private var photoPins: [PhotoPin] = []
        private var photoPoints: [MKMapPoint] = []
        private var photoGroups: [String: (group: PhotoGrouping.Group, annotation: PhotoGroupAnnotation)] = [:]

        /// Called when the library changed. Groups refer to pins by position, so they're rebuilt.
        func syncPhotos(_ pins: [PhotoPin], on map: MKMapView) {
            map.removeAnnotations(photoGroups.values.map(\.annotation))
            photoGroups = [:]
            photoPins = pins
            photoPoints = pins.map { MKMapPoint($0.coordinate) }
            regroupPhotos(on: map)
        }

        /// Replaces only the pins whose group changed, so the rest keep their views and thumbnails.
        private func regroupPhotos(on map: MKMapView) {
            var wanted: [String: PhotoGrouping.Group] = [:]
            if !photoPins.isEmpty, map.bounds.width > 0 {
                let visible = map.visibleMapRect
                let cell = PhotoGrouping.cellSize(visibleWidth: visible.width, viewWidth: map.bounds.width)
                let spacing = visible.width / map.bounds.width * PhotoGrouping.minSpacingPoints
                // Half a screen around the visible area, so short pans don't show empty edges.
                let rect = visible.insetBy(dx: -visible.width / 2, dy: -visible.height / 2)
                for group in PhotoGrouping.groups(pins: photoPins, points: photoPoints, in: rect, cellSize: cell,
                                                  minSpacing: spacing) {
                    wanted[group.key] = group
                }
            }
            var removed: [PhotoGroupAnnotation] = []
            for (key, current) in photoGroups where wanted[key] != current.group {
                removed.append(current.annotation)
                photoGroups[key] = nil
            }
            var added: [PhotoGroupAnnotation] = []
            for (key, group) in wanted where photoGroups[key] == nil {
                let annotation = PhotoGroupAnnotation(key: key, pins: group.members.map { photoPins[$0] }, coordinate: group.coordinate)
                photoGroups[key] = (group, annotation)
                added.append(annotation)
            }
            map.removeAnnotations(removed)
            map.addAnnotations(added)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            regroupPhotos(on: mapView)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            // nil for the user location keeps the standard dot, which the heading beam attaches to.
            guard annotation is PhotoGroupAnnotation else { return nil }
            return mapView.dequeueReusableAnnotationView(withIdentifier: PhotoGroupView.reuseID, for: annotation)
        }

        func mapView(_ mapView: MKMapView, didSelect annotation: MKAnnotation) {
            if annotation is MKUserLocation {
                // The dot sits on top of the photos taken where you are (often home), so a tap
                // there is for those photos.
                let dot = mapView.convert(annotation.coordinate, toPointTo: mapView)
                guard let group = photoGroups.values.map(\.annotation).first(where: {
                    mapView.view(for: $0)?.frame.contains(dot) == true
                }) else { return }
                mapView.deselectAnnotation(annotation, animated: false)
                open(group, on: mapView)
            } else if let group = annotation as? PhotoGroupAnnotation {
                // Deselect so the same pin can be tapped again.
                mapView.deselectAnnotation(annotation, animated: false)
                open(group, on: mapView)
            }
        }

        private func open(_ group: PhotoGroupAnnotation, on mapView: MKMapView) {
            let rect = group.pins.reduce(MKMapRect.null) {
                $0.union(MKMapRect(origin: MKMapPoint($1.coordinate), size: MKMapSize(width: 0, height: 0)))
            }
            let span = MKMapPoint(x: rect.minX, y: rect.minY).distance(to: MKMapPoint(x: rect.maxX, y: rect.maxY))
            if span < Self.sameSpot {
                // Zooming in wouldn't separate them, so show them all.
                openPhotos(group.pins)
            } else {
                mapView.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 100, left: 70, bottom: 100, right: 70), animated: true)
            }
        }

        /// Photos in a stack closer together than this open together instead of zooming in.
        private static let sameSpot: CLLocationDistance = 40

        func mapView(_ mapView: MKMapView, didAdd views: [MKAnnotationView]) {
            // Keep the location dot above photo pins.
            mapView.view(for: mapView.userLocation)?.zPriority = .max
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
