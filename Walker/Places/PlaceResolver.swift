import CoreLocation

struct PlaceStat: Identifiable, Hashable, Sendable {
    var id: Int64
    var name: String
    var englishName: String?
    /// m²
    var exploredArea: Double
    /// m²; 0 when the place is a point without a boundary.
    var totalArea: Double

    var fraction: Double? { totalArea > 0 ? exploredArea / totalArea : nil }
}

struct ResolveProgress: Sendable {
    var done: Int
    var total: Int
    /// What is being looked up right now, if anything.
    var status: String?
}

/// Splits explored area into cities, then neighbourhoods, using OpenStreetMap places.
///
/// Cities are resolved for a country, neighbourhoods only for a city you open. Each
/// explored cell is assigned to a cached boundary containing it; a cell no cached boundary
/// contains triggers one lookup there, whose boundary is cached, so lookups scale with the
/// number of places rather than tiles. Results are stored per tile and recomputed only when
/// the tile's explored cells change.
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
    /// Neighbourhood boundaries by city.
    private var neighbourhoods: [Int64: [(id: Int64, index: EdgeIndex)]] = [:]
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
        try stats(where: "p.kind = 'city' AND p.country = ?", [.text(country)])
    }

    private func resolveCities(in tile: Tile, country: String, countryShape: CountryIndex.Country?,
                               status: @Sendable (String) async -> Void) async throws {
        let cities = try loadCities()
        var owner = [Int64?](repeating: nil, count: Self.cellCount)
        var lookups = 0
        while true {
            for (id, index) in self.cities ?? cities {
                assign(index, to: id, in: tile, owner: &owner, eligible: { _ in true })
            }
            guard lookups < Self.maxLookupsPerTile,
                  let cell = unassignedCell(tile, owner: owner, eligible: { _ in true })
            else { break }
            lookups += 1

            await status("Looking up a city…")
            // An explored cell is somewhere you've been, so it's on land: a good spot to ask about.
            guard let place = try await lookup.place(at: cellCentre(tile, cell: cell), zoom: PlaceZoom.city),
                  self.cities?[place.id] == nil, !shapeless.contains(place.id)
            else { break }
            guard var shape = place.shape else {
                shapeless.insert(place.id)
                break
            }
            if let countryShape {
                shape.area = Self.landArea(of: shape, country: countryShape)
            }
            try insertPlace(place, shape: shape, kind: "city", parent: nil, country: country)
            self.cities?[place.id] = EdgeIndex(shape: shape)
            try log("Found \(place.name) (\(StatsView.formatArea(shape.area)))")
            await status("Found \(place.name)")
        }
        try save(tile, kind: "city", owner: owner, stateTable: "tile_places")
    }

    // MARK: - Neighbourhoods

    func resolveNeighbourhoods(city: Int64, progress: @Sendable (ResolveProgress) async -> Void) async throws {
        guard let cityIndex = try loadCities()[city] else { return }
        try loadNeighbourhoods(city: city)
        let tiles = try pendingNeighbourhoodTiles(city: city)
        await progress(ResolveProgress(done: 0, total: tiles.count))
        for (index, tile) in tiles.enumerated() {
            try Task.checkCancellation()
            try await resolveNeighbourhoods(in: tile, city: city, cityIndex: cityIndex) { status in
                await progress(ResolveProgress(done: index, total: tiles.count, status: status))
            }
            await progress(ResolveProgress(done: index + 1, total: tiles.count))
        }
    }

    func neighbourhoodStats(city: Int64) throws -> [PlaceStat] {
        try stats(where: "p.kind = 'neighbourhood' AND p.parent = ?", [.int(city)])
    }

    private func resolveNeighbourhoods(in tile: Tile, city: Int64, cityIndex: EdgeIndex,
                                       status: @Sendable (String) async -> Void) async throws {
        let inCity = cityIndex.inside(tileX: tile.x, tileY: tile.y, bits: tile.bits)
        var owner = [Int64?](repeating: nil, count: Self.cellCount)
        var lookups = 0
        while true {
            for (id, index) in neighbourhoods[city] ?? [] {
                assign(index, to: id, in: tile, owner: &owner, eligible: { inCity[$0] })
            }
            guard lookups < Self.maxLookupsPerTile,
                  let cell = unassignedCell(tile, owner: owner, eligible: { inCity[$0] })
            else { break }
            lookups += 1

            await status("Looking up a neighbourhood…")
            guard let place = try await lookup.place(at: cellCentre(tile, cell: cell), zoom: PlaceZoom.neighbourhood),
                  // Rural areas answer with the municipality itself: no neighbourhoods there.
                  place.id != city, self.cities?[place.id] == nil,
                  !(neighbourhoods[city] ?? []).contains(where: { $0.id == place.id })
            else { break }

            try insertPlace(place, shape: place.shape, kind: "neighbourhood", parent: city, country: nil)
            if let shape = place.shape {
                neighbourhoods[city, default: []].append((place.id, EdgeIndex(shape: shape)))
                try log("Found \(place.name) (\(StatsView.formatArea(shape.area)))")
            } else {
                // A point without a boundary: the rest of this tile's cells go to it.
                for cell in 0..<Self.cellCount where inCity[cell] && owner[cell] == nil {
                    owner[cell] = place.id
                }
                try log("Found \(place.name) (no boundary)")
                break
            }
        }
        try save(tile, kind: "neighbourhood", owner: owner, stateTable: "tile_neighbourhoods")
    }

    // MARK: - Cells

    private func assign(_ index: EdgeIndex, to id: Int64, in tile: Tile, owner: inout [Int64?], eligible: (Int) -> Bool) {
        guard index.intersects(tileX: tile.x, tileY: tile.y) else { return }
        let inside = index.inside(tileX: tile.x, tileY: tile.y, bits: tile.bits)
        for cell in 0..<Self.cellCount where inside[cell] && owner[cell] == nil && eligible(cell) {
            owner[cell] = id
        }
    }

    /// The middle one of the explored, eligible cells nothing owns yet.
    private func unassignedCell(_ tile: Tile, owner: [Int64?], eligible: (Int) -> Bool) -> Int? {
        let cells = (0..<Self.cellCount).filter {
            owner[$0] == nil && eligible($0) && tile.bits.contains(column: $0 % FogGrid.cellsPerTile, row: $0 / FogGrid.cellsPerTile)
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
        let db = try Database(path: databaseURL.path)
        self.db = db
        return db
    }

    private func loadCities() throws -> [Int64: EdgeIndex] {
        if let cities { return cities }
        var loaded: [Int64: EdgeIndex] = [:]
        for (id, shape) in try shapes(where: "kind = 'city'", []) {
            loaded[id] = EdgeIndex(shape: shape)
        }
        cities = loaded
        return loaded
    }

    private func loadNeighbourhoods(city: Int64) throws {
        guard neighbourhoods[city] == nil else { return }
        neighbourhoods[city] = try shapes(where: "kind = 'neighbourhood' AND parent = ?", [.int(city)])
            .map { ($0.id, EdgeIndex(shape: $0.shape)) }
    }

    private func shapes(where condition: String, _ bindings: [SQLValue]) throws -> [(id: Int64, shape: PlaceShape)] {
        let decoder = JSONDecoder()
        return try database().query("SELECT id, shape FROM places WHERE \(condition) AND shape != ''", bindings) { row in
            (row.int(0), row.text(1))
        }
        .compactMap { id, json in
            (try? decoder.decode(PlaceShape.self, from: Data(json.utf8))).map { (id, $0) }
        }
    }

    private func insertPlace(_ place: OSMPlace, shape: PlaceShape?, kind: String, parent: Int64?, country: String?) throws {
        let json = try shape.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) } ?? ""
        try database().run(
            "INSERT OR REPLACE INTO places (id, name, english, kind, parent, country, area, shape, lat, lon) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [.int(place.id), .text(place.name), .text(place.englishName ?? ""), .text(kind), .int(parent ?? 0),
             .text(country ?? ""), .double(shape?.area ?? 0), .text(json),
             .double(place.centre.latitude), .double(place.centre.longitude)]
        )
    }

    /// The country's explored tiles that changed since cities were last assigned, most explored first.
    private func pendingCityTiles(country: String, countries: CountryIndex) throws -> [Tile] {
        let fineZoom = FogGrid.fineTileZoom
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
        return rows.compactMap { row -> Tile? in
            guard let bits = row.bits, bits.count != row.cells else { return nil }
            // Same tile-centre rule as the country stats, so the numbers agree.
            let centre = CLLocationCoordinate2D(
                latitude: FogGrid.latitude(ofCellY: Double(row.y) + 0.5, zoom: fineZoom),
                longitude: (Double(row.x) + 0.5) / tileCount * 360 - 180
            )
            guard countries.country(at: centre)?.code == country else { return nil }
            return Tile(x: row.x, y: row.y, bits: bits)
        }
        .sorted { $0.bits.count > $1.bits.count }
    }

    /// The city's tiles that changed since neighbourhoods were last assigned, most explored first.
    private func pendingNeighbourhoodTiles(city: Int64) throws -> [Tile] {
        let fineZoom = FogGrid.fineTileZoom
        return try database().query(
            """
            SELECT t.x, t.y, t.bits, n.cells FROM tile_place_areas a
            JOIN tiles t ON t.z = ? AND t.x = a.x AND t.y = a.y
            LEFT JOIN tile_neighbourhoods n ON n.x = a.x AND n.y = a.y
            WHERE a.place = ?
            """,
            [.int(Int64(fineZoom)), .int(city)]
        ) { row in
            (x: Int(row.int(0)), y: Int(row.int(1)), bits: TileBits(data: row.blob(2)), cells: Int(row.int(3)))
        }
        .compactMap { row -> Tile? in
            guard let bits = row.bits, bits.count != row.cells else { return nil }
            return Tile(x: row.x, y: row.y, bits: bits)
        }
        .sorted { $0.bits.count > $1.bits.count }
    }

    /// Replaces the tile's areas for places of `kind` and records it as up to date.
    private func save(_ tile: Tile, kind: String, owner: [Int64?], stateTable: String) throws {
        var totals: [Int64: Double] = [:]
        for cell in 0..<Self.cellCount {
            if let id = owner[cell] {
                totals[id, default: 0] += FogGrid.cellArea(row: tile.y * FogGrid.cellsPerTile + cell / FogGrid.cellsPerTile)
            }
        }
        let x = Int64(tile.x), y = Int64(tile.y)
        let db = try database()
        try db.transaction {
            try db.run(
                "DELETE FROM tile_place_areas WHERE x = ? AND y = ? AND place IN (SELECT id FROM places WHERE kind = ?)",
                [.int(x), .int(y), .text(kind)]
            )
            for (place, area) in totals {
                try db.run("INSERT INTO tile_place_areas (x, y, place, area) VALUES (?, ?, ?, ?)",
                           [.int(x), .int(y), .int(place), .double(area)])
            }
            try db.run("INSERT OR REPLACE INTO \(stateTable) (x, y, cells) VALUES (?, ?, ?)",
                       [.int(x), .int(y), .int(Int64(tile.bits.count))])
        }
    }

    private func stats(where condition: String, _ bindings: [SQLValue]) throws -> [PlaceStat] {
        try database().query(
            """
            SELECT p.id, p.name, p.english, p.area, SUM(t.area)
            FROM tile_place_areas t JOIN places p ON p.id = t.place
            WHERE \(condition)
            GROUP BY p.id
            ORDER BY SUM(t.area) DESC
            """,
            bindings
        ) { row in
            let english = row.text(2)
            return PlaceStat(id: row.int(0), name: row.text(1), englishName: english.isEmpty ? nil : english,
                             exploredArea: row.double(4), totalArea: row.double(3))
        }
    }

    /// Shown in the Log tab, so lookups can be followed on the phone.
    private func log(_ message: String) throws {
        try database().run("INSERT INTO events (ts, kind, message) VALUES (?, ?, ?)",
                           [.double(Date().timeIntervalSince1970), .text(LogKind.places.rawValue), .text(message)])
    }
}
