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

/// Stands in for Nominatim with the Reykjavík fixtures: the city; the district Miðborg inside its
/// boundary, or a boundary-less district point "Vesturbær" elsewhere; and at neighbourhood level
/// Miðbær inside its boundary, or a boundary-less point "Melar" elsewhere.
private actor FakeLookup: PlaceLookup {
    let city: OSMPlace
    let miðborg: OSMPlace
    let miðbær: OSMPlace
    /// Answer district lookups with the city itself, as for a city without districts.
    var noDistricts = false
    private(set) var calls: [Int: Int] = [:]

    init() throws {
        city = try #require(try fixture("nominatim-reykjavik-city"))
        miðborg = try #require(try fixture("nominatim-reykjavik-midborg"))
        miðbær = try #require(try fixture("nominatim-reykjavik-midbaer"))
    }

    func withoutDistricts() { noDistricts = true }

    func place(at coordinate: CLLocationCoordinate2D, zoom: Int) async throws -> OSMPlace? {
        calls[zoom, default: 0] += 1
        guard city.shape?.contains(coordinate) == true else { return nil }
        switch zoom {
        case PlaceLevel.city.zoom:
            return city
        case PlaceLevel.district.zoom:
            if noDistricts { return city }
            if miðborg.shape?.contains(coordinate) == true { return miðborg }
            return OSMPlace(id: -2, name: "Vesturbær", shape: nil, centre: vesturbærPoint)
        default:
            if miðbær.shape?.contains(coordinate) == true { return miðbær }
            return OSMPlace(id: -1, name: "Melar", shape: nil, centre: vesturbærPoint)
        }
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

    private func sum(_ stats: [PlaceStat]) -> Double { stats.reduce(0) { $0 + $1.exploredArea } }

    @Test func resolvesCityDistrictAndNeighbourhood() async throws {
        let (url, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try walk(store, [miðborgPoint, vesturbærPoint])
        let total = store.dailyStats().reduce(0) { $0 + $1.totals.area }

        let lookup = try FakeLookup()
        let resolver = PlaceResolver(databaseURL: url, lookup: lookup)
        let countries = try #require(CountryIndex.shared)

        try await resolver.resolveCities(country: "ISL", countries: countries) { _ in }
        // Every tile after the first is covered by the cached boundary.
        #expect(await lookup.calls[PlaceLevel.city.zoom] == 1)
        let city = try #require(try await resolver.cityStats(country: "ISL").first)
        #expect(city.name == "Reykjavíkurborg")
        #expect(abs(city.exploredArea - total) / total < 0.01)
        #expect((city.fraction ?? 0) > 0)

        try await resolver.resolveChildren(of: city.id, level: .district) { _ in }
        let districts = try await resolver.childStats(of: city.id, level: .district)
        #expect(Set(districts.map(\.name)) == ["Miðborg", "Vesturbær"])
        let miðborg = try #require(districts.first { $0.name == "Miðborg" })
        #expect((miðborg.fraction ?? 0) > 0)
        #expect(districts.first { $0.name == "Vesturbær" }?.fraction == nil)
        #expect(abs(sum(districts) - city.exploredArea) / city.exploredArea < 0.01)

        try await resolver.resolveChildren(of: miðborg.id, level: .neighbourhood) { _ in }
        let neighbourhoods = try await resolver.childStats(of: miðborg.id, level: .neighbourhood)
        #expect(neighbourhoods.contains { $0.name == "Miðbær" && ($0.fraction ?? 0) > 0 })
        #expect(neighbourhoods.allSatisfy { $0.name != "Melar" || $0.fraction == nil })
        #expect(abs(sum(neighbourhoods) - miðborg.exploredArea) / miðborg.exploredArea < 0.01)

        // Nothing changed, so another pass makes no lookups.
        let before = await lookup.calls
        try await resolver.resolveCities(country: "ISL", countries: countries) { _ in }
        try await resolver.resolveChildren(of: city.id, level: .district) { _ in }
        try await resolver.resolveChildren(of: miðborg.id, level: .neighbourhood) { _ in }
        #expect(await lookup.calls == before)

        // Lower levels don't change the numbers above them.
        #expect(try await resolver.cityStats(country: "ISL").first?.exploredArea == city.exploredArea)
        #expect(try await resolver.childStats(of: city.id, level: .district).first(where: { $0.name == "Miðborg" })?.exploredArea == miðborg.exploredArea)
    }

    @Test func cityWithoutDistrictsHasNeighbourhoodsDirectly() async throws {
        let (url, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try walk(store, [miðborgPoint, vesturbærPoint])

        let lookup = try FakeLookup()
        await lookup.withoutDistricts()
        let resolver = PlaceResolver(databaseURL: url, lookup: lookup)
        try await resolver.resolveCities(country: "ISL", countries: try #require(CountryIndex.shared)) { _ in }
        let city = try #require(try await resolver.cityStats(country: "ISL").first)

        try await resolver.resolveChildren(of: city.id, level: .district) { _ in }
        #expect(try await resolver.childStats(of: city.id, level: .district).isEmpty)
        // Remembered gaps: about one lookup per ~1 km block walked, not one per map tile.
        let tiles = try Database(path: url.path).query("SELECT COUNT(*) FROM tiles WHERE z = ?", [.int(Int64(FogGrid.fineTileZoom))]) { $0.int(0) }.first ?? 0
        let calls = await lookup.calls[PlaceLevel.district.zoom] ?? 0
        #expect(calls > 0 && calls < tiles / 2)

        try await resolver.resolveChildren(of: city.id, level: .neighbourhood) { _ in }
        let neighbourhoods = try await resolver.childStats(of: city.id, level: .neighbourhood)
        #expect(Set(neighbourhoods.map(\.name)) == ["Miðbær", "Melar"])
        #expect(neighbourhoods.first { $0.name == "Melar" }?.fraction == nil)
        #expect(abs(sum(neighbourhoods) - city.exploredArea) / city.exploredArea < 0.01)
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
