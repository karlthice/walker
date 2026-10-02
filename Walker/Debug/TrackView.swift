import MapKit
import SwiftUI

/// Debug map of stored points, each drawn with the reveal radius (a preview of the fog clearing).
struct TrackView: View {
    enum Range: String, CaseIterable, Identifiable {
        case day = "24 h"
        case week = "7 days"
        case all = "All"

        var id: Self { self }

        var since: Date {
            switch self {
            case .day: .now.addingTimeInterval(-86_400)
            case .week: .now.addingTimeInterval(-7 * 86_400)
            case .all: .distantPast
            }
        }
    }

    private static let maxCircles = 2000

    @Environment(LocationService.self) private var service
    @State private var range = Range.day
    @State private var points: [LocationPoint] = []
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)

    var body: some View {
        NavigationStack {
            Map(position: $position) {
                UserAnnotation()
                if points.count > 1 {
                    MapPolyline(coordinates: points.map(\.coordinate))
                        .stroke(.blue, lineWidth: 2)
                }
                ForEach(points.suffix(Self.maxCircles)) { point in
                    MapCircle(center: point.coordinate, radius: LocationService.revealRadius)
                        .foregroundStyle(.blue.opacity(0.12))
                }
            }
            .mapControls {
                MapUserLocationButton()
                MapCompass()
                MapScaleView()
            }
            .safeAreaInset(edge: .top) {
                Picker("Range", selection: $range) {
                    ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
            }
            .navigationTitle("\(points.count) points")
            .navigationBarTitleDisplayMode(.inline)
            .task(id: "\(range.rawValue)-\(service.revision)") {
                points = service.store.points(since: range.since)
            }
        }
    }
}
