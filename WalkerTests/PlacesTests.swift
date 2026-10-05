import CoreLocation
import Foundation
import Testing
@testable import Walker

private final class BundleToken {}

private func fixture(_ name: String) throws -> OSMPlace? {
    let url = try #require(Bundle(for: BundleToken.self).url(forResource: name, withExtension: "json"))
    return try NominatimResponse.decode(Data(contentsOf: url))
}

private let miðborgPoint = CLLocationCoordinate2D(latitude: 64.1466, longitude: -21.9426)
private let vesturbærPoint = CLLocationCoordinate2D(latitude: 64.1440, longitude: -21.9620)

struct NominatimParsingTests {
    @Test func parsesCityBoundary() throws {
        let city = try #require(try fixture("nominatim-reykjavik-city"))
        #expect(city.id == 2580605)
        #expect(city.name == "Reykjavíkurborg")
        #expect(city.englishName == "Reykjavik")
        let shape = try #require(city.shape)
        #expect(shape.rings.count >= 2) // mainland plus islands
        #expect(abs(shape.area / 1e6 - 243) < 3)
        #expect(shape.contains(miðborgPoint))
        #expect(shape.contains(vesturbærPoint))
    }

    @Test func parsesNeighbourhoodBoundary() throws {
        let miðbær = try #require(try fixture("nominatim-reykjavik-midbaer"))
        #expect(miðbær.name == "Miðbær")
        #expect(miðbær.englishName == nil)
        let shape = try #require(miðbær.shape)
        #expect(shape.contains(miðborgPoint))
        #expect(!shape.contains(vesturbærPoint))
        #expect(shape.area > 100_000 && shape.area < 2_000_000)
    }

    @Test func parsesPointWithoutBoundary() throws {
        let quarter = try #require(try fixture("nominatim-kanazawa-quarter"))
        #expect(quarter.id == -8423933937)
        #expect(quarter.name == "柿木畠")
        #expect(quarter.englishName == "Kakinokibatake")
        #expect(quarter.shape == nil)
    }

    @Test func nothingAtSea() throws {
        #expect(try fixture("nominatim-ocean") == nil)
    }

    @Test func idsDoNotCollideAcrossTypes() {
        #expect(OSMPlace.id(type: "relation", osmID: 5) == 5)
        #expect(OSMPlace.id(type: "node", osmID: 5) == -5)
        #expect(OSMPlace.id(type: "way", osmID: 5) == 5 + OSMPlace.wayOffset)
    }
}

struct PolygonTests {
    @Test func holesAreExcluded() {
        let outer: [Double] = [0, 0, 4, 0, 4, 4, 0, 4]
        let hole: [Double] = [1, 1, 3, 1, 3, 3, 1, 3]
        #expect(!PolygonMath.contains(rings: [outer, hole], longitude: 2, latitude: 2))
        #expect(PolygonMath.contains(rings: [outer, hole], longitude: 0.5, latitude: 2))
    }

    @Test func intersectionOfOverlappingSquares() {
        // Two 0.1° squares at the equator overlapping by half.
        let a: [Double] = [0, 0, 0.1, 0, 0.1, 0.1, 0, 0.1]
        let b: [Double] = [0.05, 0, 0.15, 0, 0.15, 0.1, 0.05, 0.1]
        let expected = 0.5 * PolygonMath.ringArea(a)
        #expect(abs(PolygonMath.intersectionArea([a], [b]) - expected) / expected < 0.01)
        #expect(PolygonMath.intersectionArea([a], [[1, 1, 1.1, 1, 1.1, 1.1]]) == 0)
    }

    @Test func reykjavikKeepsItsBoundaryArea() throws {
        let city = try #require(try fixture("nominatim-reykjavik-city")?.shape)
        let iceland = try #require(CountryIndex.shared?.countries.first { $0.code == "ISL" })
        #expect(PlaceResolver.landArea(of: city, country: iceland) == city.area)
    }

    @Test func boundaryReachingOutToSeaIsClipped() throws {
        // A box from inland Iceland far out into the ocean to the west.
        let ring: [Double] = [-24.5, 64.0, -21.0, 64.0, -21.0, 64.3, -24.5, 64.3]
        let shape = PlaceShape(rings: [ring], area: PolygonMath.ringArea(ring))
        let iceland = try #require(CountryIndex.shared?.countries.first { $0.code == "ISL" })
        let land = PlaceResolver.landArea(of: shape, country: iceland)
        #expect(land < shape.area * 0.8)
        #expect(land > 0)
    }

    @Test func edgeIndexAgreesWithPointInPolygon() throws {
        let miðbær = try #require(try fixture("nominatim-reykjavik-midbaer")?.shape)
        let index = EdgeIndex(shape: miðbær)
        var grid = ExploredGrid()
        try grid.revealCircle(center: miðborgPoint, radius: 300)
        var checked = 0
        for (key, bits) in grid.tiles where key.zoom == FogGrid.fineTileZoom {
            let inside = index.inside(tileX: key.x, tileY: key.y, bits: bits)
            let bounds = EdgeIndex.bounds(tileX: key.x, tileY: key.y)
            let width = (bounds.maxLon - bounds.minLon) / 32
            for cell in 0..<1024 where bits.contains(column: cell % 32, row: cell / 32) {
                let centre = CLLocationCoordinate2D(
                    latitude: FogGrid.latitude(ofCellY: Double(key.y * 32 + cell / 32) + 0.5),
                    longitude: bounds.minLon + (Double(cell % 32) + 0.5) * width
                )
                #expect(inside[cell] == miðbær.contains(centre))
                checked += 1
            }
        }
        #expect(checked > 1000)
    }
}

/// Stands in for Nominatim: Reykjavíkurborg inside its boundary, nothing elsewhere.
private actor FakeLookup: PlaceLookup {
    let city: OSMPlace
    private(set) var calls = 0

    init() throws {
        city = try #require(try fixture("nominatim-reykjavik-city"))
    }

    func city(at coordinate: CLLocationCoordinate2D) async throws -> OSMPlace? {
        calls += 1
        return city.shape?.contains(coordinate) == true ? city : nil
    }
}

@MainActor
struct PlaceResolverTests {
    private func makeStore() throws -> (URL, PointStore) {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "walker.sqlite")
        let store = PointStore(url: url)
        try Revealer(store: store).rebuild()
        return (url, store)
    }

    private func walk(_ store: PointStore, _ points: [CLLocationCoordinate2D]) throws {
        var time = Date()
        for point in points {
            store.insert(LocationPoint(timestamp: time, latitude: point.latitude, longitude: point.longitude, accuracy: 10))
            time += 300
        }
        try Revealer(store: store).catchUp()
    }

    @Test func resolvesCitiesWithOneLookupPerCity() async throws {
        let (url, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try walk(store, [miðborgPoint, vesturbærPoint])
        let total = store.dailyStats().reduce(0) { $0 + $1.totals.area }

        let lookup = try FakeLookup()
        let resolver = PlaceResolver(databaseURL: url, lookup: lookup)
        let countries = try #require(CountryIndex.shared)

        try await resolver.resolveCities(country: "ISL", countries: countries) { _ in }
        // Every tile after the first is covered by the cached boundary.
        #expect(await lookup.calls == 1)
        let city = try #require(try await resolver.cityStats(country: "ISL").first)
        #expect(city.name == "Reykjavíkurborg")
        #expect(city.englishName == "Reykjavik")
        #expect(abs(city.exploredArea - total) / total < 0.01)
        #expect(city.fraction > 0)

        // Nothing changed, so another pass makes no lookups.
        try await resolver.resolveCities(country: "ISL", countries: countries) { _ in }
        #expect(await lookup.calls == 1)
    }

    @Test func reportsProgress() async throws {
        let (url, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try walk(store, [miðborgPoint, vesturbærPoint])

        let resolver = PlaceResolver(databaseURL: url, lookup: try FakeLookup())
        let updates = Updates()
        try await resolver.resolveCities(country: "ISL", countries: try #require(CountryIndex.shared)) { await updates.add($0) }
        let all = await updates.all
        #expect(all.first?.done == 0)
        #expect(all.last.map { $0.done == $0.total } == true)
        #expect(all.contains { $0.status != nil })
    }
}

private actor Updates {
    var all: [ResolveProgress] = []
    func add(_ update: ResolveProgress) { all.append(update) }
}
