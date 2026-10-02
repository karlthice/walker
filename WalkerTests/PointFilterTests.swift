import CoreLocation
import Testing
@testable import Walker

struct PointFilterTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// 0.001° of latitude is ~111 m.
    private func fix(lat: Double, accuracy: Double = 20, after seconds: TimeInterval) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: -21.9),
            altitude: 0,
            horizontalAccuracy: accuracy,
            verticalAccuracy: -1,
            timestamp: start.addingTimeInterval(seconds)
        )
    }

    @Test func acceptsFirstAccurateFix() {
        var filter = PointFilter()
        #expect(filter.evaluate(fix(lat: 64.1, after: 0)) == .accept)
    }

    @Test func rejectsCoarseAndInvalidFixes() {
        var filter = PointFilter()
        #expect(filter.evaluate(fix(lat: 64.1, accuracy: 150, after: 0)) == .inaccurate)
        #expect(filter.evaluate(fix(lat: 64.1, accuracy: -1, after: 0)) == .inaccurate)
        #expect(filter.last == nil)
    }

    @Test func rejectsFixesTooCloseToLast() {
        var filter = PointFilter()
        _ = filter.evaluate(fix(lat: 64.1, after: 0))
        // 0.0001° of latitude is ~11 m.
        #expect(filter.evaluate(fix(lat: 64.1001, after: 30)) == .tooClose)
    }

    @Test func acceptsAfterMovingFarEnough() {
        var filter = PointFilter()
        _ = filter.evaluate(fix(lat: 64.1, after: 0))
        #expect(filter.evaluate(fix(lat: 64.101, after: 60)) == .accept)
    }

    @Test func rejectsOutOfOrderFixes() {
        var filter = PointFilter()
        _ = filter.evaluate(fix(lat: 64.1, after: 60))
        #expect(filter.evaluate(fix(lat: 64.2, after: 30)) == .outOfOrder)
    }

    @Test func seedPreventsDuplicateAfterRelaunch() {
        var filter = PointFilter()
        filter.seed(with: LocationPoint(fix(lat: 64.1, after: 0)))
        #expect(filter.evaluate(fix(lat: 64.1001, after: 10)) == .tooClose)
    }
}
