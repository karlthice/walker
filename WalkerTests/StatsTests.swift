import CoreLocation
import Foundation
import Testing
@testable import Walker

struct AreaTests {
    @Test func cellAreaAtEquatorAndReykjavik() {
        let n = FogGrid.cellCount(zoom: 21)
        #expect(abs(FogGrid.cellArea(row: n / 2) - 19.11 * 19.11) < 1)
        let row = Int(FogGrid.cellPosition(of: reykjavik).y)
        let size = FogGrid.cellSize(atLatitude: reykjavik.latitude)
        #expect(abs(size - 8.34) < 0.01)
        #expect(abs(FogGrid.cellArea(row: row) - size * size) < 0.01)
    }

    @Test func latitudeRoundTrips() {
        let y = FogGrid.cellPosition(of: reykjavik).y
        #expect(abs(FogGrid.latitude(ofCellY: y) - reykjavik.latitude) < 1e-9)
    }

    @Test func newlyExploredAreaCountsEachCellOnce() throws {
        var grid = ExploredGrid()
        try grid.revealCircle(center: reykjavik, radius: 150)
        let circle = Double.pi * 150 * 150
        #expect(abs(grid.newlyExploredArea - circle) / circle < 0.05)

        let before = grid.newlyExploredArea
        try grid.revealCircle(center: reykjavik, radius: 150)
        #expect(grid.newlyExploredArea == before)
    }

    @Test func rowCountsSumToTotal() {
        var bits = TileBits()
        bits.insert(column: 0, row: 0)
        bits.insert(column: 31, row: 1)
        bits.insert(column: 4, row: 1)
        bits.insert(column: 9, row: 31)
        #expect(bits.count(row: 0) == 1)
        #expect(bits.count(row: 1) == 2)
        #expect(bits.count(row: 31) == 1)
        #expect((0..<32).reduce(0) { $0 + bits.count(row: $1) } == bits.count)
    }
}

@MainActor
struct DailyStatsTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    private func point(_ coordinate: CLLocationCoordinate2D, at date: Date) -> LocationPoint {
        LocationPoint(timestamp: date, latitude: coordinate.latitude, longitude: coordinate.longitude, accuracy: 10)
    }

    private func noon(daysAgo: Int) -> Date {
        let today = calendar.startOfDay(for: .now)
        return calendar.date(byAdding: DateComponents(day: -daysAgo, hour: 12), to: today)!
    }

    @Test func recordsAreaAndDistancePerDay() throws {
        let store = PointStore(url: nil)
        let revealer = Revealer(store: store)
        try revealer.rebuild()

        let start = noon(daysAgo: 1)
        store.insert(point(reykjavik, at: start))
        store.insert(point(offset(reykjavik, east: 1000), at: start.addingTimeInterval(120)))
        store.insert(point(offset(reykjavik, north: 3000), at: noon(daysAgo: 0)))
        try revealer.catchUp()

        let days = store.dailyStats()
        #expect(days.count == 2)
        let yesterday = try #require(days.first)
        #expect(calendar.isDate(yesterday.day, inSameDayAs: start))
        #expect(abs(yesterday.totals.distance - 1000) < 5)
        let strip = 2 * 150 * 1000 + Double.pi * 150 * 150
        #expect(abs(yesterday.totals.area - strip) / strip < 0.05)

        // Today's point is hours later, so it's a lone circle with no distance.
        let today = try #require(days.last)
        #expect(today.totals.distance == 0)
        #expect(abs(today.totals.area - Double.pi * 150 * 150) / (Double.pi * 150 * 150) < 0.05)
    }

    @Test func rebuildReproducesDailyTotals() throws {
        let store = PointStore(url: nil)
        let revealer = Revealer(store: store)
        try revealer.rebuild()

        var coordinate = reykjavik
        var time = noon(daysAgo: 3)
        for i in 0..<120 {
            coordinate = offset(coordinate, north: 30, east: Double(i % 5) * 40 - 60)
            time += i % 40 == 39 ? 86_400 : 45
            store.insert(point(coordinate, at: time))
            try revealer.catchUp()
        }
        let incremental = store.dailyStats()

        try revealer.rebuild()
        let rebuilt = store.dailyStats()
        #expect(rebuilt.count == incremental.count)
        for (a, b) in zip(incremental, rebuilt) {
            #expect(a.day == b.day)
            #expect(abs(a.totals.area - b.totals.area) < 1e-6)
            #expect(abs(a.totals.distance - b.totals.distance) < 1e-6)
        }
    }
}

struct CountryIndexTests {
    private let index = CountryIndex.shared!

    @Test func findsCountries() {
        #expect(index.country(at: reykjavik)?.code == "ISL")
        #expect(index.country(at: CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522))?.code == "FRA")
        #expect(index.country(at: CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060))?.code == "USA")
    }

    @Test func enclaveIsNotItsSurroundingCountry() {
        // Maseru, Lesotho, which is a hole in South Africa.
        #expect(index.country(at: CLLocationCoordinate2D(latitude: -29.31, longitude: 27.48))?.code == "LSO")
    }

    @Test func nearShoreCountsOpenOceanDoesNot() {
        // Reykjavik harbour, just outside the coarse coastline.
        #expect(index.country(at: CLLocationCoordinate2D(latitude: 64.16, longitude: -21.95))?.code == "ISL")
        #expect(index.country(at: CLLocationCoordinate2D(latitude: 40, longitude: -40)) == nil)
    }
}

@MainActor
struct CountryStatsTests {
    @Test func splitsExploredAreaByCountry() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
            .appending(path: "walker.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = PointStore(url: url)
        let revealer = Revealer(store: store)
        try revealer.rebuild()
        let now = Date()
        store.insert(LocationPoint(timestamp: now, latitude: reykjavik.latitude, longitude: reykjavik.longitude, accuracy: 10))
        store.insert(LocationPoint(timestamp: now.addingTimeInterval(7200), latitude: 48.8566, longitude: 2.3522, accuracy: 10))
        try revealer.catchUp()

        let stats = try StatsCalculator.countryStats(databaseURL: url, countries: CountryIndex.shared!)
        #expect(Set(stats.map(\.code)) == ["ISL", "FRA"])

        let total = store.dailyStats().reduce(0) { $0 + $1.totals.area }
        let split = stats.reduce(0) { $0 + $1.exploredArea }
        #expect(abs(total - split) / total < 1e-9)

        let iceland = try #require(stats.first { $0.code == "ISL" })
        #expect(abs(iceland.fraction - Double.pi * 150 * 150 / 101_164.1e6) / iceland.fraction < 0.05)
    }
}
