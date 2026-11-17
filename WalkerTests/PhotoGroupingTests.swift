import CoreLocation
import MapKit
import Testing
@testable import Walker

struct PhotoGroupingTests {
    private let pins = [
        // Two photos a few metres apart in Miðborg, one in Vesturbær (~1 km west), one far away.
        PhotoPin(id: "old", latitude: 64.14660, longitude: -21.94260, date: Date(timeIntervalSinceNow: -9 * 86400)),
        PhotoPin(id: "new", latitude: 64.14662, longitude: -21.94262, date: Date(timeIntervalSinceNow: -1 * 86400)),
        PhotoPin(id: "west", latitude: 64.14400, longitude: -21.96200, date: nil),
        PhotoPin(id: "kanazawa", latitude: 36.5613, longitude: 136.6562, date: nil),
    ]

    private var points: [MKMapPoint] { pins.map { MKMapPoint($0.coordinate) } }

    /// About 2 km of Reykjavík across a 400 pt wide map.
    private var reykjavik: MKMapRect {
        let centre = MKMapPoint(CLLocationCoordinate2D(latitude: 64.145, longitude: -21.95))
        let width = 2000 * MKMapPointsPerMeterAtLatitude(64.145)
        return MKMapRect(x: centre.x - width / 2, y: centre.y - width, width: width, height: width * 2)
    }

    @Test func nearbyPhotosShareAPinNewestFirst() {
        let cell = PhotoGrouping.cellSize(visibleWidth: reykjavik.width, viewWidth: 400)
        let groups = PhotoGrouping.groups(pins: pins, points: points, in: reykjavik, cellSize: cell, minSpacing: cell * 0.7)
        #expect(groups.count == 2)
        let stack = groups.first { $0.members.count == 2 }
        #expect(stack.map { $0.members.map { pins[$0].id } } == ["new", "old"])
        #expect(groups.contains { $0.members.map { pins[$0].id } == ["west"] })
    }

    @Test func photosOutsideTheAreaAreLeftOut() {
        let cell = PhotoGrouping.cellSize(visibleWidth: reykjavik.width, viewWidth: 400)
        let groups = PhotoGrouping.groups(pins: pins, points: points, in: reykjavik, cellSize: cell, minSpacing: cell * 0.7)
        #expect(!groups.contains { $0.members.contains(3) })
    }

    @Test func zoomedOutEverythingNearbyIsOneStack() {
        // A whole country across the screen: the Reykjavík photos merge.
        let wide = reykjavik.insetBy(dx: -reykjavik.width * 200, dy: -reykjavik.height * 100)
        let cell = PhotoGrouping.cellSize(visibleWidth: wide.width, viewWidth: 400)
        let groups = PhotoGrouping.groups(pins: pins, points: points, in: wide, cellSize: cell, minSpacing: cell * 0.7)
        #expect(groups.contains { Set($0.members) == [0, 1, 2] })
    }

    @Test func photosEitherSideOfACellEdgeMerge() {
        // Two photos a metre apart, placed on either side of a cell boundary.
        let cell = 1024.0
        let edge = (MKMapPoint(pins[0].coordinate).x / cell).rounded(.down) * cell
        let y = MKMapPoint(pins[0].coordinate).y
        let points = [MKMapPoint(x: edge - 0.5, y: y), MKMapPoint(x: edge + 0.5, y: y)]
        let pair = [pins[0], pins[1]]
        let area = MKMapRect(x: edge - 10 * cell, y: y - 10 * cell, width: 20 * cell, height: 20 * cell)
        let merged = PhotoGrouping.groups(pins: pair, points: points, in: area, cellSize: cell, minSpacing: cell * 0.7)
        #expect(merged.count == 1)
        #expect(merged.first?.members == [1, 0])
        let apart = PhotoGrouping.groups(pins: pair, points: points, in: area, cellSize: cell, minSpacing: 0)
        #expect(apart.count == 2)
    }

    @Test func cellSizeIsAPowerOfTwoAndStableWithinAZoomLevel() {
        let a = PhotoGrouping.cellSize(visibleWidth: 10_000, viewWidth: 400)
        let b = PhotoGrouping.cellSize(visibleWidth: 10_300, viewWidth: 400)
        #expect(a == b)
        #expect(log2(a) == log2(a).rounded())
    }
}
