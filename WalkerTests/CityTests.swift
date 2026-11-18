import CoreLocation
import Foundation
import Testing
@testable import Walker

private let miðborgPoint = CLLocationCoordinate2D(latitude: 64.1466, longitude: -21.9426)
private let vesturbærPoint = CLLocationCoordinate2D(latitude: 64.1440, longitude: -21.9620)

struct CityIndexTests {
    private let index = CityIndex.shared!

    @Test func bundlesCuratedCities() throws {
        let reykjavik = try #require(index.cities.first { $0.name == "Reykjavík" })
        #expect(reykjavik.country == "ISL")
        #expect(reykjavik.localName == "Reykjavíkurborg")
        #expect(abs(reykjavik.area / 1e6 - 243) < 5)
        #expect(reykjavik.edges.shape.contains(miðborgPoint))
        #expect(index.cities.filter { $0.country == "ESP" }.count == 8)
    }

    @Test func everyCityIsInAKnownCountryOnce() {
        let codes = Set(CountryIndex.shared!.countries.map(\.code))
        #expect(index.cities.allSatisfy { codes.contains($0.country) })
        #expect(Set(index.cities.map(\.id)).count == index.cities.count)
    }

    @Test func seaIsLeftOutOfCityArea() throws {
        // Kanazawa's boundary reaches ~260 km² out to sea; its land is about 468 km².
        let kanazawa = try #require(index.cities.first { $0.name == "Kanazawa" })
        #expect(abs(kanazawa.area / 1e6 - 468) < 30)
    }

    @Test func edgeIndexAgreesWithPointInPolygon() throws {
        let reykjavik = try #require(index.cities.first { $0.name == "Reykjavík" })
        var grid = ExploredGrid()
        // Downtown Reykjavík, where the boundary follows the harbour.
        try grid.revealCircle(center: CLLocationCoordinate2D(latitude: 64.1510, longitude: -21.9420), radius: 400)
        var checked = 0
        for (key, bits) in grid.tiles where key.zoom == FogGrid.fineTileZoom {
            let inside = reykjavik.edges.inside(tileX: key.x, tileY: key.y, bits: bits)
            let bounds = EdgeIndex.bounds(tileX: key.x, tileY: key.y)
            let width = (bounds.maxLon - bounds.minLon) / 32
            for cell in 0..<1024 where bits.contains(column: cell % 32, row: cell / 32) {
                let centre = CLLocationCoordinate2D(
                    latitude: FogGrid.latitude(ofCellY: Double(key.y * 32 + cell / 32) + 0.5),
                    longitude: bounds.minLon + (Double(cell % 32) + 0.5) * width
                )
                #expect(inside[cell] == reykjavik.edges.shape.contains(centre))
                checked += 1
            }
        }
        #expect(checked > 1000)
    }
}

struct PolygonTests {
    @Test func holesAreExcluded() {
        let outer: [Double] = [0, 0, 4, 0, 4, 4, 0, 4]
        let hole: [Double] = [1, 1, 3, 1, 3, 3, 1, 3]
        #expect(!PolygonMath.contains(rings: [outer, hole], longitude: 2, latitude: 2))
        #expect(PolygonMath.contains(rings: [outer, hole], longitude: 0.5, latitude: 2))
    }
}

@MainActor
struct CityStatsTests {
    private func makeStore() throws -> (URL, PointStore) {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "walker.sqlite")
        let store = PointStore(url: url)
        try Revealer(store: store).rebuild()
        return (url, store)
    }

    private func walk(_ store: PointStore, _ points: [CLLocationCoordinate2D], from start: Date = Date()) throws {
        var time = start
        for point in points {
            store.insert(LocationPoint(timestamp: time, latitude: point.latitude, longitude: point.longitude, accuracy: 10))
            time += 300
        }
        try Revealer(store: store).catchUp()
    }

    private func totalArea(_ store: PointStore) -> Double {
        store.dailyStats().reduce(0) { $0 + $1.totals.area }
    }

    /// A city list with one square city, as cities.json has it.
    private func boxCity(_ name: String, around centre: CLLocationCoordinate2D, size: Double = 0.02) throws -> CityIndex {
        let (lon, lat) = (centre.longitude, centre.latitude)
        let ring = [lon - size, lat - size, lon + size, lat - size, lon + size, lat + size, lon - size, lat + size]
        let json = """
            [{"id":1,"name":"\(name)","local":null,"country":"ISL","area":1000000,"rings":[\(ring)]}]
            """
        return try CityIndex(data: Data(json.utf8))
    }

    @Test func splitsExploredAreaIntoCities() throws {
        let (url, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try walk(store, [miðborgPoint, vesturbærPoint])

        let stats = try StatsCalculator.cityStats(databaseURL: url, country: "ISL", cities: try #require(CityIndex.shared))
        let city = try #require(stats.first)
        #expect(city.name == "Reykjavík")
        #expect(abs(city.exploredArea - totalArea(store)) / totalArea(store) < 0.02)
        #expect(city.fraction > 0)
    }

    @Test func listsCitiesNotVisitedYet() throws {
        let (url, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try walk(store, [miðborgPoint])

        let spain = try StatsCalculator.cityStats(databaseURL: url, country: "ESP", cities: try #require(CityIndex.shared))
        #expect(spain.count == 8)
        #expect(spain.allSatisfy { $0.exploredArea == 0 })
        #expect(spain.map(\.name) == spain.map(\.name).sorted())
    }

    @Test func newlyExploredCellsAreAdded() throws {
        let (url, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let cities = try boxCity("Box", around: miðborgPoint)
        try walk(store, [miðborgPoint])
        let first = try #require(try StatsCalculator.cityStats(databaseURL: url, country: "ISL", cities: cities).first)
        #expect(abs(first.exploredArea - totalArea(store)) / totalArea(store) < 0.01)

        try walk(store, [vesturbærPoint], from: Date() + 600)
        let second = try #require(try StatsCalculator.cityStats(databaseURL: url, country: "ISL", cities: cities).first)
        #expect(second.exploredArea > first.exploredArea * 1.5)
        #expect(abs(second.exploredArea - totalArea(store)) / totalArea(store) < 0.01)
    }

    @Test func changedCityListIsRemeasured() throws {
        let (url, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try walk(store, [miðborgPoint])

        let here = try boxCity("Here", around: miðborgPoint)
        #expect(try StatsCalculator.cityStats(databaseURL: url, country: "ISL", cities: here).first?.exploredArea ?? 0 > 0)
        // Same id, moved away: the saved areas belong to the old list and must not carry over.
        let away = try boxCity("Away", around: CLLocationCoordinate2D(latitude: 65.68, longitude: -18.09))
        #expect(try StatsCalculator.cityStats(databaseURL: url, country: "ISL", cities: away).first?.exploredArea == 0)
    }
}
