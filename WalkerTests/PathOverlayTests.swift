import CoreLocation
import Foundation
import Testing
@testable import Walker

struct PathOverlayTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func point(_ coordinate: CLLocationCoordinate2D, hoursAgo: Double) -> LocationPoint {
        LocationPoint(timestamp: now.addingTimeInterval(-hoursAgo * 3600), latitude: coordinate.latitude,
                      longitude: coordinate.longitude, accuracy: 10)
    }

    @Test func stepsByAge() {
        #expect(PathAge.step(age: 0) == 0)
        #expect(PathAge.step(age: 23 * 3600) == 0)
        #expect(PathAge.step(age: 25 * 3600) == 1)
        #expect(PathAge.step(age: 4 * 86_400) == 6)
        #expect(PathAge.step(age: 7 * 86_400) == PathAge.steps)
        #expect(PathAge.step(age: 30 * 86_400) == PathAge.steps)
    }

    @Test func recentIsWiderAndDarker() {
        #expect(PathAge.width(step: 0) > PathAge.width(step: PathAge.steps))
        var recent: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        var old = recent
        PathAge.color(step: 0).getRed(&recent.0, green: &recent.1, blue: &recent.2, alpha: &recent.3)
        PathAge.color(step: PathAge.steps).getRed(&old.0, green: &old.1, blue: &old.2, alpha: &old.3)
        #expect(recent.0 + recent.1 + recent.2 < old.0 + old.1 + old.2)
        // Still clearly visible at a week old.
        #expect(old.3 >= 0.85)
    }

    @Test func splitsByAgeStepWithSharedEnds() {
        // A walk spanning the 24-hour mark: one minute between points, 50 m apart.
        let points = (0..<4).map { i in point(offset(reykjavik, east: Double(i) * 50), hoursAgo: 24.02 - Double(i) / 60) }
        let paths = PathAge.polylines(for: points, byAge: true, now: now)
        #expect(paths.count == 2)
        // Oldest first, so the newest draws on top.
        #expect(paths.map(\.step) == [1, 0])
        // The pieces share the point where the style changes, so the line has no gap.
        let total = paths.reduce(0) { $0 + $1.pointCount }
        #expect(total == points.count + 1)
    }

    @Test func breaksWhereTheFogIsntJoined() {
        let morning = point(reykjavik, hoursAgo: 5)
        let walk = point(offset(reykjavik, east: 50), hoursAgo: 4.98)
        // Hours later and 5 km away: not joined.
        let evening = point(offset(reykjavik, north: 5000), hoursAgo: 1)
        let later = point(offset(reykjavik, north: 5050), hoursAgo: 0.98)
        let paths = PathAge.polylines(for: [morning, walk, evening, later], byAge: false, now: now)
        #expect(paths.count == 2)
        #expect(paths.allSatisfy { $0.step == nil && $0.pointCount == 2 })
    }
}
