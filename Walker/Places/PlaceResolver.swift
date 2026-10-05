import CoreLocation

struct PlaceStat: Identifiable, Hashable, Sendable {
    var id: Int64
    var name: String
    var englishName: String?
    /// m²
    var exploredArea: Double
    /// m²
    var totalArea: Double

    var fraction: Double { totalArea > 0 ? exploredArea / totalArea : 0 }
}

struct ResolveProgress: Sendable {
    var done: Int
    var total: Int
    /// What is being looked up right now, if anything.
    var status: String?
}

/// Splits a country's explored area into cities and municipalities, using OpenStreetMap
/// boundaries.
///
/// Each explored cell goes to a cached boundary that contains it; a cell none contains
/// triggers one lookup there, and the boundary found is cached, so lookups scale with the
/// number of cities rather than map tiles. Results are stored per tile and recomputed only
/// when the tile's explored cells change.
actor PlaceResolver {
    static let shared = PlaceResolver(databaseURL: PointStore.defaultURL, lookup: NominatimClient())

    /// A city whose land area (clipped to the country's coastline) is below this share of its
    /// boundary area includes sea, like Kanazawa's territorial waters; use the land area then.
    /// The 1:50m coastline is too coarse to clip smaller differences reliably.
    static let seaClipThreshold = 0.8
    /// Lookups per tile per pass, for tiles spanning several uncached places.
    private static let maxLookupsPerTile = 3

    private struct Tile {
        var x: Int
        var y: Int
        var bits: TileBits
    }

    private static let cellCount = FogGrid.cellsPerTile * FogGrid.cellsPerTile

    private let databaseURL: URL
    private let lookup: PlaceLookup
    private var db: Database?
    private var cities: [Int64: EdgeIndex]?
    /// Places known to have no usable boundary, so they aren't looked up again this session.
    private var shapeless: Set<Int64> = []

    init(databaseURL: URL, lookup: PlaceLookup) {
        self.databaseURL = databaseURL
        self.lookup = lookup
    }

    // MARK: - Cities

    func resolveCities(country: String, countries: CountryIndex, progress: @Sendable (ResolveProgress) async -> Void) async throws {
        let countryShape = countries.countries.first { $0.code == country }
        let tiles = try pendingCityTiles(country: country, countries: countries)
        await progress(ResolveProgress(done: 0, total: tiles.count))
        for (index, tile) in tiles.enumerated() {
            try Task.checkCancellation()
            try await resolveCities(in: tile, country: country, countryShape: countryShape) { status in
                await progress(ResolveProgress(done: index, total: tiles.count, status: status))
            }
            await progress(ResolveProgress(done: index + 1, total: tiles.count))
        }
    }

    func cityStats(country: String) throws -> [PlaceStat] {
        try database().query(
            """
            SELECT p.id, p.name, p.english, p.area, SUM(t.area)
            FROM tile_place_areas t JOIN places p ON p.id = t.place
            WHERE p.country = ?
            GROUP BY p.id
            ORDER BY SUM(t.area) DESC
            """,
            [.text(country)]
        ) { row in
            let english = row.text(2)
            return PlaceStat(id: row.int(0), name: row.text(1), englishName: english.isEmpty ? nil : english,
                             exploredArea: row.double(4), totalArea: row.double(3))
        }
    }

    private func resolveCities(in tile: Tile, country: String, countryShape: CountryIndex.Country?,
                               status: @Sendable (String) async -> Void) async throws {
        let cities = try loadCities()
        var owner = [Int64?](repeating: nil, count: Self.cellCount)
        var lookups = 0
        while true {
            for (id, index) in self.cities ?? cities {
                assign(index, to: id, in: tile, owner: &owner)
            }
            guard lookups < Self.maxLookupsPerTile,
                  let cell = unassignedCell(tile, owner: owner)
            else { break }
            lookups += 1

            await status("Looking up a city…")
            // An explored cell is somewhere you've been, so it's on land: a good spot to ask about.
            guard let place = try await lookup.city(at: cellCentre(tile, cell: cell)),
                  self.cities?[place.id] == nil, !shapeless.contains(place.id)
            else { break }
            guard var shape = place.shape else {
                shapeless.insert(place.id)
                break
            }
            if let countryShape {
                shape.area = Self.landArea(of: shape, country: countryShape)
            }
            try insertCity(place, shape: shape, country: country)
            self.cities?[place.id] = EdgeIndex(shape: shape)
            try log("Found \(place.name) (\(StatsView.formatArea(shape.area)))")
            await status("Found \(place.name)")
        }
        try save(tile, owner: owner)
    }

    // MARK: - Cells

    private func assign(_ index: EdgeIndex, to id: Int64, in tile: Tile, owner: inout [Int64?]) {
        guard index.intersects(tileX: tile.x, tileY: tile.y) else { return }
        let inside = index.inside(tileX: tile.x, tileY: tile.y, bits: tile.bits)
        for cell in 0..<Self.cellCount where inside[cell] && owner[cell] == nil {
            owner[cell] = id
        }
    }

    /// The middle one of the explored cells nothing owns yet.
    private func unassignedCell(_ tile: Tile, owner: [Int64?]) -> Int? {
        let cells = (0..<Self.cellCount).filter {
            owner[$0] == nil && tile.bits.contains(column: $0 % FogGrid.cellsPerTile, row: $0 / FogGrid.cellsPerTile)
        }
        return cells.isEmpty ? nil : cells[cells.count / 2]
    }

    private func cellCentre(_ tile: Tile, cell: Int) -> CLLocationCoordinate2D {
        let bounds = EdgeIndex.bounds(tileX: tile.x, tileY: tile.y)
        let width = (bounds.maxLon - bounds.minLon) / Double(FogGrid.cellsPerTile)
        return CLLocationCoordinate2D(
            latitude: FogGrid.latitude(ofCellY: Double(tile.y * FogGrid.cellsPerTile + cell / FogGrid.cellsPerTile) + 0.5),
            longitude: bounds.minLon + (Double(cell % FogGrid.cellsPerTile) + 0.5) * width
        )
    }

    static func landArea(of shape: PlaceShape, country: CountryIndex.Country) -> Double {
        let land = PolygonMath.intersectionArea(shape.rings, country.rings)
        return land > 0 && land < shape.area * seaClipThreshold ? land : shape.area
    }

    // MARK: - Storage

    private func database() throws -> Database {
        if let db { return db }
        let db = try Database(path: databaseURL.path, create: false)
        self.db = db
        return db
    }

    private func loadCities() throws -> [Int64: EdgeIndex] {
        if let cities { return cities }
        var loaded: [Int64: EdgeIndex] = [:]
        for (id, shape) in try shapes() {
            loaded[id] = EdgeIndex(shape: shape)
        }
        cities = loaded
        return loaded
    }

    private func shapes() throws -> [(id: Int64, shape: PlaceShape)] {
        let decoder = JSONDecoder()
        return try database().query("SELECT id, shape FROM places WHERE shape != ''") { row in
            (row.int(0), row.text(1))
        }
        .compactMap { id, json in
            (try? decoder.decode(PlaceShape.self, from: Data(json.utf8))).map { (id, $0) }
        }
    }

    private func insertCity(_ place: OSMPlace, shape: PlaceShape, country: String) throws {
        let json = String(decoding: try JSONEncoder().encode(shape), as: UTF8.self)
        try database().run(
            "INSERT OR REPLACE INTO places (id, name, english, kind, parent, country, area, shape, lat, lon) VALUES (?, ?, ?, 'city', 0, ?, ?, ?, ?, ?)",
            [.int(place.id), .text(place.name), .text(place.englishName ?? ""), .text(country), .double(shape.area), .text(json),
             .double(place.centre.latitude), .double(place.centre.longitude)]
        )
    }

    /// The country's explored tiles that changed since cities were last assigned, most explored first.
    private func pendingCityTiles(country: String, countries: CountryIndex) throws -> [Tile] {
        let db = try database()
        try TileCountries.update(db, countries: countries)
        return try db.query(
            """
            SELECT t.x, t.y, t.bits, p.cells FROM tiles t
            JOIN tile_countries c ON c.x = t.x AND c.y = t.y
            LEFT JOIN tile_places p ON p.x = t.x AND p.y = t.y
            WHERE t.z = ? AND c.country = ?
            """,
            [.int(Int64(FogGrid.fineTileZoom)), .text(country)]
        ) { row in
            (x: Int(row.int(0)), y: Int(row.int(1)), bits: TileBits(data: row.blob(2)), cells: Int(row.int(3)))
        }
        .compactMap { row -> Tile? in
            guard let bits = row.bits, bits.count != row.cells else { return nil }
            return Tile(x: row.x, y: row.y, bits: bits)
        }
        .sorted { $0.bits.count > $1.bits.count }
    }

    /// Replaces the tile's city areas and records the tile as up to date.
    private func save(_ tile: Tile, owner: [Int64?]) throws {
        var totals: [Int64: Double] = [:]
        for cell in 0..<Self.cellCount {
            if let id = owner[cell] {
                totals[id, default: 0] += FogGrid.cellArea(row: tile.y * FogGrid.cellsPerTile + cell / FogGrid.cellsPerTile)
            }
        }
        let x = Int64(tile.x), y = Int64(tile.y)
        let db = try database()
        try db.transaction {
            try db.run("DELETE FROM tile_place_areas WHERE x = ? AND y = ?", [.int(x), .int(y)])
            for (place, area) in totals {
                try db.run("INSERT INTO tile_place_areas (x, y, place, area) VALUES (?, ?, ?, ?)",
                           [.int(x), .int(y), .int(place), .double(area)])
            }
            try db.run("INSERT OR REPLACE INTO tile_places (x, y, cells) VALUES (?, ?, ?)",
                       [.int(x), .int(y), .int(Int64(tile.bits.count))])
        }
    }

    /// Shown in the Log tab, so lookups can be followed on the phone.
    private func log(_ message: String) throws {
        try database().run("INSERT INTO events (ts, kind, message) VALUES (?, ?, ?)",
                           [.double(Date().timeIntervalSince1970), .text(LogKind.places.rawValue), .text(message)])
    }
}
