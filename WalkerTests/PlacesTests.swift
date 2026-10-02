import CoreLocation
import Foundation
import Testing
@testable import Walker

private final class BundleToken {}

private func reykjavikAreas() throws -> [AdminArea] {
    let url = try #require(Bundle(for: BundleToken.self).url(forResource: "reykjavik-overpass", withExtension: "json"))
    return try JSONDecoder().decode(OverpassResponse.self, from: Data(contentsOf: url)).areas
}

private let miðborgPoint = CLLocationCoordinate2D(latitude: 64.1466, longitude: -21.9426)
private let vesturbærPoint = CLLocationCoordinate2D(latitude: 64.1440, longitude: -21.9620)

struct OverpassParsingTests {
    @Test func parsesBoundariesWithAreas() throws {
        let areas = try reykjavikAreas()
        #expect(Set(areas.map(\.name)) == ["Reykjavíkurborg", "Miðborg", "Vesturbær", "Miðbær"])

        let city = try #require(areas.first { $0.id == 2580605 })
        #expect(city.level == 6)
        let shape = try #require(city.shape)
        #expect(shape.rings.count == 7) // mainland plus islands
        #expect(abs(shape.area / 1e6 - 243.0) < 1)

        let miðborg = try #require(areas.first { $0.name == "Miðborg" }?.shape)
        #expect(abs(miðborg.area / 1e6 - 3.9) < 0.1)
        #expect(miðborg.contains(miðborgPoint))
        #expect(!miðborg.contains(vesturbærPoint))
    }

    @Test func parsesPointPlaces() throws {
        let json = #"{"elements":[{"type":"node","id":42,"lat":36.5613,"lon":136.6562,"tags":{"place":"quarter","name":"片町","name:en":"Katamachi"}}]}"#
        let areas = try JSONDecoder().decode(OverpassResponse.self, from: Data(json.utf8)).areas
        let place = try #require(areas.first)
        #expect(place.id == -42)
        #expect(place.placeKind == "quarter")
        #expect(place.englishName == "Katamachi")
        #expect(place.centre?.latitude == 36.5613)
    }

    @Test func picksCityLevel() {
        func area(_ level: Int) -> AdminArea { AdminArea(id: Int64(level), name: "\(level)", level: level) }
        // Iceland: country 2, region 5, municipality 6, districts 9 and 10.
        #expect(AdminArea.city(in: [2, 5, 6, 9, 10].map(area))?.level == 6)
        // Japan: prefecture 4, city 7.
        #expect(AdminArea.city(in: [2, 4, 7].map(area))?.level == 7)
        #expect(AdminArea.city(in: [2].map(area)) == nil)
    }
}

struct RingAssemblyTests {
    private func c(_ lat: Double, _ lon: Double) -> CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }

    @Test func joinsWaysInAnyDirection() {
        // A square split into three ways, one reversed.
        let rings = PlaceShape.assembleRings([
            [c(0, 0), c(0, 1)],
            [c(1, 1), c(1, 0), c(0, 0)],
            [c(1, 1), c(0, 1)],
        ])
        #expect(rings.count == 1)
        #expect(rings[0].count == 8)
        #expect(PolygonMath.contains(rings: rings, longitude: 0.5, latitude: 0.5))
    }

    @Test func dropsRingsThatCannotClose() {
        #expect(PlaceShape.assembleRings([[c(0, 0), c(0, 1), c(1, 1)]]).isEmpty)
    }

    @Test func holesAreExcluded() {
        let outer: [Double] = [0, 0, 4, 0, 4, 4, 0, 4]
        let hole: [Double] = [1, 1, 3, 1, 3, 3, 1, 3]
        #expect(!PolygonMath.contains(rings: [outer, hole], longitude: 2, latitude: 2))
        #expect(PolygonMath.contains(rings: [outer, hole], longitude: 0.5, latitude: 2))
    }
}

struct NeighbourhoodSelectionTests {
    @Test func sparseBoundariesWithoutPointsGiveNone() throws {
        let areas = try reykjavikAreas()
        let city = try #require(areas.first { $0.id == 2580605 })
        // The fixture has only two of Reykjavík's ten districts (7 of 243 km²) and no points.
        #expect(AdminArea.neighbourhoods(in: areas, city: city) == .none)
    }

    @Test func boundariesWinWhenTheyCoverTheCity() throws {
        let square: [Double] = [0, 0, 1, 0, 1, 1, 0, 1]
        let left: [Double] = [0, 0, 0.5, 0, 0.5, 1, 0, 1]
        let right: [Double] = [0.5, 0, 1, 0, 1, 1, 0.5, 1]
        func shape(_ ring: [Double]) -> PlaceShape { PlaceShape(rings: [ring], area: PolygonMath.ringArea(ring)) }
        let city = AdminArea(id: 1, name: "City", level: 7, shape: shape(square))
        let areas = [
            city,
            AdminArea(id: 2, name: "West", level: 9, shape: shape(left)),
            AdminArea(id: 3, name: "East", level: 9, shape: shape(right)),
            AdminArea(id: 4, name: "Block", level: 10, shape: shape(left)),
            AdminArea(id: -5, name: "Quarter", level: 0, centre: .init(latitude: 0.5, longitude: 0.5), placeKind: "quarter"),
        ]
        guard case .boundaries(let found) = AdminArea.neighbourhoods(in: areas, city: city) else {
            Issue.record("Expected boundaries")
            return
        }
        #expect(Set(found.map(\.name)) == ["West", "East"])
    }

    @Test func pointsWhenBoundariesAreSparse() {
        let square: [Double] = [0, 0, 1, 0, 1, 1, 0, 1]
        let corner: [Double] = [0, 0, 0.1, 0, 0.1, 0.1, 0, 0.1]
        func shape(_ ring: [Double]) -> PlaceShape { PlaceShape(rings: [ring], area: PolygonMath.ringArea(ring)) }
        let city = AdminArea(id: 1, name: "Kanazawa", level: 7, shape: shape(square))
        func quarter(_ id: Int64, _ lat: Double) -> AdminArea {
            AdminArea(id: -id, name: "Q\(id)", level: 0, centre: .init(latitude: lat, longitude: 0.5), placeKind: "quarter")
        }
        let areas = [city, AdminArea(id: 2, name: "Corner", level: 9, shape: shape(corner)),
                     quarter(10, 0.2), quarter(11, 0.5), quarter(12, 0.8),
                     AdminArea(id: -13, name: "Outside", level: 0, centre: .init(latitude: 2, longitude: 2), placeKind: "quarter")]
        guard case .points(let found) = AdminArea.neighbourhoods(in: areas, city: city) else {
            Issue.record("Expected points")
            return
        }
        #expect(found.map(\.name) == ["Q10", "Q11", "Q12"])
    }
}

struct LandAreaTests {
    @Test func intersectionOfOverlappingSquares() {
        // Two 0.1° squares at the equator overlapping by half: about 0.5 × 11.13 km × 11.13 km.
        let a: [Double] = [0, 0, 0.1, 0, 0.1, 0.1, 0, 0.1]
        let b: [Double] = [0.05, 0, 0.15, 0, 0.15, 0.1, 0.05, 0.1]
        let expected = 0.5 * PolygonMath.ringArea(a)
        #expect(abs(PolygonMath.intersectionArea([a], [b]) - expected) / expected < 0.01)
        #expect(PolygonMath.intersectionArea([a], [[1, 1, 1.1, 1, 1.1, 1.1]]) == 0)
    }

    @Test func reykjavikKeepsItsBoundaryArea() throws {
        let city = try #require(try reykjavikAreas().first { $0.id == 2580605 }?.shape)
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
}

struct EdgeIndexTests {
    @Test func splitsTileCellsAlongTheBoundary() throws {
        let areas = try reykjavikAreas()
        let miðborg = try #require(areas.first { $0.name == "Miðborg" }?.shape)
        let index = EdgeIndex(shape: miðborg)

        var grid = ExploredGrid()
        try grid.revealCircle(center: miðborgPoint, radius: 150)
        for (key, bits) in grid.tiles where key.zoom == 16 {
            let inside = index.inside(tileX: key.x, tileY: key.y, bits: bits)
            // Must agree with the plain point-in-polygon test for every explored cell.
            let bounds = EdgeIndex.bounds(tileX: key.x, tileY: key.y)
            let width = (bounds.maxLon - bounds.minLon) / 32
            for cell in 0..<1024 where bits.contains(column: cell % 32, row: cell / 32) {
                let centre = CLLocationCoordinate2D(
                    latitude: FogGrid.latitude(ofCellY: Double(key.y * 32 + cell / 32) + 0.5),
                    longitude: bounds.minLon + (Double(cell % 32) + 0.5) * width
                )
                #expect(inside[cell] == miðborg.contains(centre))
            }
        }
    }
}

/// Stands in for Overpass, answering from the Reykjavík fixture and counting calls.
private actor FakeLookup: PlaceLookup {
    let areas: [AdminArea]
    private(set) var isInCalls = 0
    private(set) var fetchCalls = 0

    init(areas: [AdminArea]) { self.areas = areas }

    func adminAreas(containing coordinate: CLLocationCoordinate2D) async throws -> [AdminArea] {
        isInCalls += 1
        return areas.filter { $0.level == 6 && $0.shape?.contains(coordinate) == true }
            .map { AdminArea(id: $0.id, name: $0.name, level: $0.level) }
    }

    func areaWithSubdivisions(_ id: Int64) async throws -> [AdminArea] {
        fetchCalls += 1
        // Pretend the two districts in the fixture are all of them, by shrinking the coverage bar's denominator.
        return areas.map { area in
            guard area.id == id, var shape = area.shape else { return area }
            shape.area = 1
            return AdminArea(id: area.id, name: area.name, level: area.level, shape: shape)
        }
    }
}

@MainActor
struct PlaceResolverTests {
    @Test func resolvesCityAndNeighbourhoodsWithOneFetch() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "walker.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = PointStore(url: url)
        let revealer = Revealer(store: store)
        try revealer.rebuild()
        let start = Date()
        store.insert(LocationPoint(timestamp: start, latitude: miðborgPoint.latitude, longitude: miðborgPoint.longitude, accuracy: 10))
        store.insert(LocationPoint(timestamp: start.addingTimeInterval(300), latitude: vesturbærPoint.latitude, longitude: vesturbærPoint.longitude, accuracy: 10))
        try revealer.catchUp()

        let lookup = FakeLookup(areas: try reykjavikAreas())
        let resolver = PlaceResolver(databaseURL: url, lookup: lookup)
        let index = try #require(CountryIndex.shared)
        try await resolver.resolve(country: "ISL", countries: index) { _, _ in }

        #expect(await lookup.fetchCalls == 1)

        let cities = try await resolver.cityStats(country: "ISL")
        let city = try #require(cities.first)
        #expect(city.name == "Reykjavíkurborg")
        #expect(city.childCount == 2)
        let total = store.dailyStats().reduce(0) { $0 + $1.totals.area }
        #expect(abs(city.exploredArea - total) / total < 0.01)

        let neighbourhoods = try await resolver.neighbourhoodStats(city: city.id)
        #expect(Set(neighbourhoods.map(\.name)) == ["Miðborg", "Vesturbær"])
        let split = neighbourhoods.reduce(0) { $0 + $1.exploredArea }
        #expect(abs(split - city.exploredArea) / city.exploredArea < 0.01)
        #expect(neighbourhoods.allSatisfy { ($0.fraction ?? 0) > 0 })

        // Nothing changed, so a second pass does no lookups.
        let calls = await lookup.isInCalls
        try await resolver.resolve(country: "ISL", countries: index) { _, _ in }
        #expect(await lookup.isInCalls == calls)
    }
}
