import CoreLocation

struct PlaceStat: Identifiable, Hashable, Sendable {
    var id: Int64
    var name: String
    var englishName: String?
    /// m²
    var exploredArea: Double
    /// m²; 0 when the place is a point without a boundary.
    var totalArea: Double
    var childCount: Int

    var fraction: Double? { totalArea > 0 ? exploredArea / totalArea : nil }
}

/// Splits explored area into cities and neighbourhoods using OpenStreetMap boundaries.
///
/// Each explored cell is assigned to the cached city containing it. A cell no cached city
/// contains triggers a lookup of that spot, which fetches and caches the city with all its
/// neighbourhoods, so network requests scale with the number of cities, not tiles. Results
/// are stored per tile and only recomputed when the tile's explored cells change.
actor PlaceResolver {
    static let shared = PlaceResolver(databaseURL: PointStore.defaultURL, lookup: OverpassClient())

    /// Cells farther than this from every neighbourhood point stay unassigned.
    static let maxPointDistance: CLLocationDistance = 1500
    /// A tile spanning several uncached cities gets at most this many lookups per pass.
    private static let maxLookupsPerTile = 2
    /// A city whose land area (clipped to the country's coastline) is below this share of its
    /// boundary area includes sea, like Kanazawa's territorial waters; use the land area then.
    /// The 1:50m coastline is too coarse to clip smaller differences reliably.
    static let seaClipThreshold = 0.8

    private struct City {
        var index: EdgeIndex
        var boundaries: [(id: Int64, index: EdgeIndex)] = []
        var points: [(id: Int64, coordinate: CLLocationCoordinate2D)] = []
    }

    private struct Tile {
        var x: Int
        var y: Int
        var bits: TileBits
    }

    private let databaseURL: URL
    private let lookup: PlaceLookup
    private var db: Database?
    private var cities: [Int64: City]?
    /// Cities whose boundary couldn't be fetched, so they aren't requested again this session.
    private var unavailableCities: Set<Int64> = []
    private var countries: CountryIndex?

    init(databaseURL: URL, lookup: PlaceLookup) {
        self.databaseURL = databaseURL
        self.lookup = lookup
    }

    /// Assigns the country's explored tiles that changed since last time.
    /// `progress` is called with (tiles done, tiles to do).
    func resolve(country: String, countries: CountryIndex, progress: @Sendable (Int, Int) async -> Void) async throws {
        self.countries = countries
        let tiles = try pendingTiles(country: country, countries: countries)
        await progress(0, tiles.count)
        for (index, tile) in tiles.enumerated() {
            try Task.checkCancellation()
            try await resolve(tile, country: country)
            await progress(index + 1, tiles.count)
        }
    }

    func cityStats(country: String) throws -> [PlaceStat] {
        try stats(where: "p.kind = 'city' AND p.country = ?", [.text(country)])
    }

    func neighbourhoodStats(city: Int64) throws -> [PlaceStat] {
        try stats(where: "p.kind = 'neighbourhood' AND p.parent = ?", [.int(city)])
    }

    // MARK: - Resolving

    private func resolve(_ tile: Tile, country: String) async throws {
        let cities = try loadCities()
        let cellCount = FogGrid.cellsPerTile * FogGrid.cellsPerTile
        var owner = [Int64?](repeating: nil, count: cellCount)
        var lookups = 0

        while true {
            for (id, city) in self.cities ?? cities where city.index.intersects(tileX: tile.x, tileY: tile.y) {
                let inside = city.index.inside(tileX: tile.x, tileY: tile.y, bits: tile.bits)
                for cell in 0..<cellCount where inside[cell] && owner[cell] == nil {
                    owner[cell] = id
                }
            }
            guard lookups < Self.maxLookupsPerTile,
                  let cell = (0..<cellCount).first(where: { owner[$0] == nil && tile.bits.contains(column: $0 % 32, row: $0 / 32) })
            else { break }
            lookups += 1

            // An explored cell is somewhere you've been, so it's on land: a good spot to ask about.
            let areas = try await lookup.adminAreas(containing: cellCentre(tile, cell: cell))
            guard let city = AdminArea.city(in: areas),
                  self.cities?[city.id] == nil,
                  !unavailableCities.contains(city.id)
            else { break }
            try await fetchCity(city.id, country: country)
        }

        var totals: [Int64: Double] = [:]
        for (id, city) in self.cities ?? [:] where owner.contains(id) {
            let mine = (0..<cellCount).filter { owner[$0] == id }
            for cell in mine {
                totals[id, default: 0] += FogGrid.cellArea(row: tile.y * FogGrid.cellsPerTile + cell / 32)
            }
            for (cell, neighbourhood) in neighbourhoods(of: city, tile: tile, cells: mine) {
                totals[neighbourhood, default: 0] += FogGrid.cellArea(row: tile.y * FogGrid.cellsPerTile + cell / 32)
            }
        }
        try save(tile, totals: totals)
    }

    /// Which neighbourhood each of the given cells belongs to, if any.
    private func neighbourhoods(of city: City, tile: Tile, cells: [Int]) -> [(Int, Int64)] {
        var result: [(Int, Int64)] = []
        if !city.boundaries.isEmpty {
            var assigned = Set<Int>()
            for (id, index) in city.boundaries where index.intersects(tileX: tile.x, tileY: tile.y) {
                let inside = index.inside(tileX: tile.x, tileY: tile.y, bits: tile.bits)
                for cell in cells where inside[cell] && !assigned.contains(cell) {
                    assigned.insert(cell)
                    result.append((cell, id))
                }
            }
        } else if !city.points.isEmpty {
            let bounds = EdgeIndex.bounds(tileX: tile.x, tileY: tile.y)
            let metresPerDegree = 111_320.0
            let scaleX = metresPerDegree * cos(bounds.maxLat * .pi / 180)
            let marginLat = Self.maxPointDistance / metresPerDegree
            let marginLon = Self.maxPointDistance / scaleX
            let nearby = city.points.filter {
                $0.coordinate.latitude >= bounds.minLat - marginLat && $0.coordinate.latitude <= bounds.maxLat + marginLat
                    && $0.coordinate.longitude >= bounds.minLon - marginLon && $0.coordinate.longitude <= bounds.maxLon + marginLon
            }
            guard !nearby.isEmpty else { return [] }
            for cell in cells {
                let centre = cellCentre(tile, cell: cell)
                var best: (id: Int64, distance: Double)?
                for point in nearby {
                    let dx = (point.coordinate.longitude - centre.longitude) * scaleX
                    let dy = (point.coordinate.latitude - centre.latitude) * metresPerDegree
                    let distance = (dx * dx + dy * dy).squareRoot()
                    if distance <= Self.maxPointDistance, distance < best?.distance ?? .infinity {
                        best = (point.id, distance)
                    }
                }
                if let best { result.append((cell, best.id)) }
            }
        }
        return result
    }

    private func fetchCity(_ id: Int64, country: String) async throws {
        let areas = try await lookup.areaWithSubdivisions(id)
        guard var city = areas.first(where: { $0.id == id }), let shape = city.shape else {
            unavailableCities.insert(id)
            return
        }
        if let countryShape = countries?.countries.first(where: { $0.code == country }) {
            city.shape?.area = Self.landArea(of: shape, country: countryShape)
        }
        let neighbourhoods: [AdminArea]
        var entry = City(index: EdgeIndex(shape: shape))
        switch AdminArea.neighbourhoods(in: areas, city: city) {
        case .boundaries(let found):
            neighbourhoods = found
            entry.boundaries = found.compactMap { area in area.shape.map { (area.id, EdgeIndex(shape: $0)) } }
        case .points(let found):
            neighbourhoods = found
            entry.points = found.compactMap { area in area.centre.map { (area.id, $0) } }
        case .none:
            neighbourhoods = []
        }

        let db = try database()
        try db.transaction {
            try insertPlace(city, kind: "city", parent: nil, country: country, in: db)
            for area in neighbourhoods {
                try insertPlace(area, kind: "neighbourhood", parent: id, country: country, in: db)
            }
        }
        cities?[id] = entry
    }

    static func landArea(of shape: PlaceShape, country: CountryIndex.Country) -> Double {
        let land = PolygonMath.intersectionArea(shape.rings, country.rings)
        return land > 0 && land < shape.area * seaClipThreshold ? land : shape.area
    }

    // MARK: - Storage

    private func database() throws -> Database {
        if let db { return db }
        let db = try Database(path: databaseURL.path)
        self.db = db
        return db
    }

    private func loadCities() throws -> [Int64: City] {
        if let cities { return cities }
        let rows = try database().query("SELECT id, kind, parent, shape, lat, lon FROM places") { row in
            (id: row.int(0), kind: row.text(1), parent: row.int(2), shape: row.text(3), lat: row.double(4), lon: row.double(5))
        }
        let decoder = JSONDecoder()
        func shape(_ json: String) -> PlaceShape? {
            json.isEmpty ? nil : try? decoder.decode(PlaceShape.self, from: Data(json.utf8))
        }
        var loaded: [Int64: City] = [:]
        for row in rows where row.kind == "city" {
            if let shape = shape(row.shape) { loaded[row.id] = City(index: EdgeIndex(shape: shape)) }
        }
        for row in rows where row.kind == "neighbourhood" {
            if let shape = shape(row.shape) {
                loaded[row.parent]?.boundaries.append((row.id, EdgeIndex(shape: shape)))
            } else {
                loaded[row.parent]?.points.append((row.id, CLLocationCoordinate2D(latitude: row.lat, longitude: row.lon)))
            }
        }
        cities = loaded
        return loaded
    }

    private func insertPlace(_ area: AdminArea, kind: String, parent: Int64?, country: String, in db: Database) throws {
        let shape = try area.shape.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) } ?? ""
        try db.run(
            "INSERT OR REPLACE INTO places (id, name, english, kind, parent, country, area, shape, lat, lon) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [.int(area.id), .text(area.name), .text(area.englishName ?? ""), .text(kind), .int(parent ?? 0), .text(country),
             .double(area.shape?.area ?? 0), .text(shape), .double(area.centre?.latitude ?? 0), .double(area.centre?.longitude ?? 0)]
        )
    }

    private func pendingTiles(country: String, countries: CountryIndex) throws -> [Tile] {
        let fineZoom = FogGrid.fineCellZoom - FogGrid.tileShift
        let tileCount = Double(FogGrid.cellCount(zoom: fineZoom))
        let rows = try database().query(
            """
            SELECT t.x, t.y, t.bits, p.cells FROM tiles t
            LEFT JOIN tile_places p ON p.x = t.x AND p.y = t.y
            WHERE t.z = ?
            """,
            [.int(Int64(fineZoom))]
        ) { row in
            (x: Int(row.int(0)), y: Int(row.int(1)), bits: TileBits(data: row.blob(2)), cells: Int(row.int(3)))
        }
        return rows.compactMap { row in
            guard let bits = row.bits, bits.count != row.cells else { return nil }
            // Same tile-centre rule as the country stats, so the numbers agree.
            let centre = CLLocationCoordinate2D(
                latitude: FogGrid.latitude(ofCellY: Double(row.y) + 0.5, zoom: fineZoom),
                longitude: (Double(row.x) + 0.5) / tileCount * 360 - 180
            )
            guard countries.country(at: centre)?.code == country else { return nil }
            return Tile(x: row.x, y: row.y, bits: bits)
        }
    }

    private func save(_ tile: Tile, totals: [Int64: Double]) throws {
        let db = try database()
        try db.transaction {
            try db.run("DELETE FROM tile_place_areas WHERE x = ? AND y = ?", [.int(Int64(tile.x)), .int(Int64(tile.y))])
            for (place, area) in totals {
                try db.run(
                    "INSERT INTO tile_place_areas (x, y, place, area) VALUES (?, ?, ?, ?)",
                    [.int(Int64(tile.x)), .int(Int64(tile.y)), .int(place), .double(area)]
                )
            }
            try db.run(
                "INSERT OR REPLACE INTO tile_places (x, y, cells) VALUES (?, ?, ?)",
                [.int(Int64(tile.x)), .int(Int64(tile.y)), .int(Int64(tile.bits.count))]
            )
        }
    }

    private func stats(where condition: String, _ bindings: [SQLValue]) throws -> [PlaceStat] {
        try database().query(
            """
            SELECT p.id, p.name, p.english, p.area, SUM(t.area),
                   (SELECT COUNT(*) FROM places c WHERE c.parent = p.id)
            FROM tile_place_areas t JOIN places p ON p.id = t.place
            WHERE \(condition)
            GROUP BY p.id
            ORDER BY SUM(t.area) DESC
            """,
            bindings
        ) { row in
            let english = row.text(2)
            return PlaceStat(
                id: row.int(0), name: row.text(1), englishName: english.isEmpty ? nil : english,
                exploredArea: row.double(4), totalArea: row.double(3), childCount: Int(row.int(5))
            )
        }
    }

    private func cellCentre(_ tile: Tile, cell: Int) -> CLLocationCoordinate2D {
        let bounds = EdgeIndex.bounds(tileX: tile.x, tileY: tile.y)
        let width = (bounds.maxLon - bounds.minLon) / Double(FogGrid.cellsPerTile)
        return CLLocationCoordinate2D(
            latitude: FogGrid.latitude(ofCellY: Double(tile.y * FogGrid.cellsPerTile + cell / 32) + 0.5),
            longitude: bounds.minLon + (Double(cell % 32) + 0.5) * width
        )
    }
}
