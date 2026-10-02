import CoreLocation
import Testing
@testable import Walker

@MainActor
struct RevealerTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func point(_ coordinate: CLLocationCoordinate2D, after seconds: TimeInterval) -> LocationPoint {
        LocationPoint(timestamp: start.addingTimeInterval(seconds), latitude: coordinate.latitude, longitude: coordinate.longitude, accuracy: 10)
    }

    private func explored(_ coordinate: CLLocationCoordinate2D, in store: PointStore) throws -> Bool {
        let position = FogGrid.cellPosition(of: coordinate)
        let x = Int(position.x), y = Int(position.y)
        let bits = try store.loadTile(TileKey(cellZoom: 21, cellX: x, cellY: y))
        return bits?.contains(column: x & 31, row: y & 31) ?? false
    }

    private func allTiles(in store: PointStore) throws -> [TileKey: TileBits] {
        let rows = try store.requireDatabase().query("SELECT z, x, y, bits FROM tiles") { row in
            (TileKey(zoom: Int(row.int(0)), x: Int(row.int(1)), y: Int(row.int(2))), TileBits(data: row.blob(3)))
        }
        return Dictionary(uniqueKeysWithValues: rows.compactMap { key, bits in bits.map { (key, $0) } })
    }

    @Test func connectsOnlyPlausibleConsecutivePoints() {
        let a = point(reykjavik, after: 0)
        #expect(Revealer.shouldConnect(a, point(offset(reykjavik, east: 1000), after: 300)))
        // Too long a gap.
        #expect(!Revealer.shouldConnect(a, point(offset(reykjavik, east: 1000), after: 11 * 60)))
        // 1 km in 10 s is 360 km/h.
        #expect(!Revealer.shouldConnect(a, point(offset(reykjavik, east: 1000), after: 10)))
        // Out of order.
        #expect(!Revealer.shouldConnect(point(reykjavik, after: 60), a))
    }

    @Test func catchUpRevealsStripBetweenPoints() throws {
        let store = PointStore(url: nil)
        let revealer = Revealer(store: store)
        try revealer.rebuild()

        store.insert(point(reykjavik, after: 0))
        store.insert(point(offset(reykjavik, east: 2000), after: 120))
        #expect(try revealer.catchUp() == 2)

        #expect(try explored(offset(reykjavik, east: 1000), in: store))
        #expect(try revealer.catchUp() == 0)
    }

    @Test func gapLeavesTheMiddleFogged() throws {
        let store = PointStore(url: nil)
        let revealer = Revealer(store: store)
        try revealer.rebuild()

        store.insert(point(reykjavik, after: 0))
        store.insert(point(offset(reykjavik, east: 2000), after: 3600))
        try revealer.catchUp()

        #expect(try explored(reykjavik, in: store))
        #expect(try explored(offset(reykjavik, east: 2000), in: store))
        #expect(try !explored(offset(reykjavik, east: 1000), in: store))
    }

    @Test func incrementalMatchesRebuild() throws {
        let store = PointStore(url: nil)
        let revealer = Revealer(store: store)
        try revealer.rebuild()

        // A wandering walk with one long gap and one GPS jump.
        var coordinate = reykjavik
        var time: TimeInterval = 0
        for i in 0..<200 {
            coordinate = offset(coordinate, north: Double(i % 7) * 15 - 40, east: 60)
            time += i == 100 ? 3600 : 50
            if i == 150 { coordinate = offset(coordinate, north: 5000) }
            store.insert(point(coordinate, after: time))
            try revealer.catchUp()
        }
        let incremental = try allTiles(in: store)

        #expect(try revealer.rebuild() == 200)
        #expect(try allTiles(in: store) == incremental)
        #expect(!incremental.isEmpty)
    }

    @Test func versionMismatchNeedsRebuild() throws {
        let store = PointStore(url: nil)
        let revealer = Revealer(store: store)
        #expect(try revealer.needsRebuild())
        try revealer.rebuild()
        #expect(try !revealer.needsRebuild())
    }
}
