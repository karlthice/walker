import CoreLocation

struct PlaceStat: Identifiable, Hashable, Sendable {
    var id: Int64
    var name: String
    var englishName: String?
    /// m²
    var exploredArea: Double
    /// m²; 0 when OpenStreetMap has the place only as a point, without a boundary.
    var totalArea: Double

    var fraction: Double? { totalArea > 0 ? exploredArea / totalArea : nil }
}

struct ResolveProgress: Sendable {
    var done: Int
    var total: Int
    /// What is being looked up right now, if anything.
    var status: String?
}

/// Splits explored area into OpenStreetMap places: cities in a country, then the places
/// one level down inside a place you open (districts, then neighbourhoods).
///
/// The same rule applies at every level. Each explored cell goes to a cached boundary that
/// contains it; a cell none contains triggers one lookup there, and the boundary found is
/// cached, so lookups scale with the number of places rather than map tiles. If the lookup
/// answers with the parent itself, that level doesn't exist there. Results are stored per
/// tile and recomputed only when the tile's explored cells change.
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
    private struct ChildKey: Hashable {
        var parent: Int64
        var level: PlaceLevel
    }

    /// Child boundaries by parent place and level, once loaded.
    private var children: [ChildKey: [(id: Int64, index: EdgeIndex)]] = [:]
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
        try stats(where: "p.kind = ? AND p.country = ?", [.text(PlaceLevel.city.rawValue), .text(country)])
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
            guard let place = try await lookup.place(at: cellCentre(tile, cell: cell), zoom: PlaceLevel.city.zoom),
                  self.cities?[place.id] == nil, !shapeless.contains(place.id)
            else { break }
            guard var shape = place.shape else {
                shapeless.insert(place.id)
                break
            }
            if let countryShape {
                shape.area = Self.landArea(of: shape, country: countryShape)
            }
            try insertPlace(place, shape: shape, level: .city, parent: nil, country: country)
            self.cities?[place.id] = EdgeIndex(shape: shape)
            try log("Found \(place.name) (\(StatsView.formatArea(shape.area)))")
            await status("Found \(place.name)")
        }
        try save(tile, owner: owner, scope: .cities)
    }

    // MARK: - Places inside a place

    /// Assigns the explored tiles inside `parent` (a city or district) to places at `level`.
    func resolveChildren(of parent: Int64, level: PlaceLevel, progress: @Sendable (ResolveProgress) async -> Void) async throws {
        guard let parentIndex = try shapeIndex(parent) else { return }
        let ancestors = try ancestorIDs(of: parent)
        let key = ChildKey(parent: parent, level: level)
        try loadChildren(key)
        let tiles = try pendingChildTiles(key)
        await progress(ResolveProgress(done: 0, total: tiles.count))
        for (index, tile) in tiles.enumerated() {
            try Task.checkCancellation()
            try await resolveChildren(in: tile, key: key, parentIndex: parentIndex, ancestors: ancestors) { status in
                await progress(ResolveProgress(done: index, total: tiles.count, status: status))
            }
            await progress(ResolveProgress(done: index + 1, total: tiles.count))
        }
    }

    func childStats(of parent: Int64, level: PlaceLevel) throws -> [PlaceStat] {
        try stats(where: "p.kind = ? AND p.parent = ?", [.text(level.rawValue), .int(parent)])
    }

    private func resolveChildren(in tile: Tile, key: ChildKey, parentIndex: EdgeIndex,
                                 ancestors: Set<Int64>, status: @Sendable (String) async -> Void) async throws {
        let (parent, level) = (key.parent, key.level)
        let inParent = parentIndex.inside(tileX: tile.x, tileY: tile.y, bits: tile.bits)
        var owner = [Int64?](repeating: nil, count: Self.cellCount)
        /// Cells a lookup showed belong to no child of this parent (or not one found yet).
        var excluded = Set<Int>()
        /// A child OpenStreetMap has only as a point; it gets the cells left over at the end.
        var point: Int64?
        var lookups = 0
        while true {
            for (id, index) in children[key] ?? [] {
                assign(index, to: id, in: tile, owner: &owner, eligible: { inParent[$0] })
            }
            guard lookups < Self.maxLookupsPerTile,
                  let cell = unassignedCell(tile, owner: owner, eligible: { inParent[$0] && !excluded.contains($0) })
            else { break }
            let centre = cellCentre(tile, cell: cell)
            let gap = Self.gapBlock(centre, level: level)
            guard try !isGap(gap, key: key) else { break }
            lookups += 1

            await status("Looking up a \(level.rawValue)…")
            guard let place = try await lookup.place(at: centre, zoom: level.zoom) else {
                excluded.insert(cell)
                continue
            }
            // Answering with the parent (or above) means no place at this level here; remember
            // the block so nearby tiles don't ask again.
            if ancestors.contains(place.id) {
                try addGap(gap, key: key)
                break
            }
            // Boundaries don't always nest exactly, so near a border the answer can be the
            // neighbouring parent's place: a place belongs to the parent holding its centre. A
            // place already known as a city is never re-filed under another place.
            guard parentIndex.shape.contains(place.centre), self.cities?[place.id] == nil else {
                if let shape = place.shape {
                    let inside = EdgeIndex(shape: shape).inside(tileX: tile.x, tileY: tile.y, bits: tile.bits)
                    excluded.formUnion((0..<Self.cellCount).filter { inside[$0] })
                }
                excluded.insert(cell)
                continue
            }
            guard !(children[key] ?? []).contains(where: { $0.id == place.id }), place.id != point else {
                excluded.insert(cell)
                continue
            }

            try insertPlace(place, shape: place.shape, level: level, parent: parent, country: nil)
            if let shape = place.shape {
                children[key, default: []].append((place.id, EdgeIndex(shape: shape)))
                try log("Found \(place.name) (\(StatsView.formatArea(shape.area)))")
            } else {
                point = point ?? place.id
                excluded.insert(cell)
                try log("Found \(place.name) (no boundary in OpenStreetMap)")
            }
        }
        // OpenStreetMap has the point-only place without an extent, so it gets this tile's cells
        // that no boundary claimed, and no percentage.
        if let point {
            for cell in 0..<Self.cellCount where inParent[cell] && owner[cell] == nil {
                owner[cell] = point
            }
        }
        try save(tile, owner: owner, scope: .children(key))
    }

    // MARK: - Gaps

    /// Blocks for remembering "no place at this level here", so a city without districts costs
    /// about one lookup per block explored rather than per map tile. A remembered gap only skips
    /// lookups; boundaries found elsewhere still claim their cells inside it. Blocks are about
    /// 1 km for districts (zoom 15) and 500 m for neighbourhoods (zoom 16), at mid latitudes.
    private static func gapBlock(_ coordinate: CLLocationCoordinate2D, level: PlaceLevel) -> (x: Int, y: Int) {
        let zoom = level == .district ? 15 : 16
        let position = FogGrid.cellPosition(of: coordinate, zoom: zoom)
        return (Int(position.x), Int(position.y))
    }

    private func isGap(_ block: (x: Int, y: Int), key: ChildKey) throws -> Bool {
        try database().query(
            "SELECT 1 FROM place_gaps WHERE parent = ? AND level = ? AND x = ? AND y = ?",
            [.int(key.parent), .text(key.level.rawValue), .int(Int64(block.x)), .int(Int64(block.y))]
        ) { _ in true }.first ?? false
    }

    private func addGap(_ block: (x: Int, y: Int), key: ChildKey) throws {
        try database().run(
            "INSERT OR REPLACE INTO place_gaps (parent, level, x, y) VALUES (?, ?, ?, ?)",
            [.int(key.parent), .text(key.level.rawValue), .int(Int64(block.x)), .int(Int64(block.y))]
        )
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
        let db = try Database(path: databaseURL.path, create: false)
        self.db = db
        return db
    }

    private func loadCities() throws -> [Int64: EdgeIndex] {
        if let cities { return cities }
        var loaded: [Int64: EdgeIndex] = [:]
        for (id, shape) in try shapes(where: "kind = ?", [.text(PlaceLevel.city.rawValue)]) {
            loaded[id] = EdgeIndex(shape: shape)
        }
        cities = loaded
        return loaded
    }

    private func loadChildren(_ key: ChildKey) throws {
        guard children[key] == nil else { return }
        children[key] = try shapes(where: "parent = ? AND kind = ?", [.int(key.parent), .text(key.level.rawValue)])
            .map { ($0.id, EdgeIndex(shape: $0.shape)) }
    }

    private func shapeIndex(_ id: Int64) throws -> EdgeIndex? {
        if let city = try loadCities()[id] { return city }
        if let child = children.values.lazy.flatMap({ $0 }).first(where: { $0.id == id }) { return child.index }
        return try shapes(where: "id = ?", [.int(id)]).first.map { EdgeIndex(shape: $0.shape) }
    }

    /// The place and every place above it, up to the city.
    private func ancestorIDs(of id: Int64) throws -> Set<Int64> {
        var result: Set<Int64> = [id]
        var current = id
        while let parent = try database().query("SELECT parent FROM places WHERE id = ?", [.int(current)], map: { $0.int(0) }).first,
              parent != 0, result.insert(parent).inserted {
            current = parent
        }
        return result
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

    private func insertPlace(_ place: OSMPlace, shape: PlaceShape?, level: PlaceLevel, parent: Int64?, country: String?) throws {
        let json = try shape.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) } ?? ""
        try database().run(
            "INSERT OR REPLACE INTO places (id, name, english, kind, parent, country, area, shape, lat, lon) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [.int(place.id), .text(place.name), .text(place.englishName ?? ""), .text(level.rawValue), .int(parent ?? 0),
             .text(country ?? ""), .double(shape?.area ?? 0), .text(json),
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

    /// The parent's tiles that changed since its children at this level were last assigned,
    /// most explored first.
    private func pendingChildTiles(_ key: ChildKey) throws -> [Tile] {
        try database().query(
            """
            SELECT t.x, t.y, t.bits, c.cells FROM tile_place_areas a
            JOIN tiles t ON t.z = ? AND t.x = a.x AND t.y = a.y
            LEFT JOIN tile_children c ON c.x = a.x AND c.y = a.y AND c.parent = a.place AND c.level = ?
            WHERE a.place = ?
            """,
            [.int(Int64(FogGrid.fineTileZoom)), .text(key.level.rawValue), .int(key.parent)]
        ) { row in
            (x: Int(row.int(0)), y: Int(row.int(1)), bits: TileBits(data: row.blob(2)), cells: Int(row.int(3)))
        }
        .compactMap { row -> Tile? in
            guard let bits = row.bits, bits.count != row.cells else { return nil }
            return Tile(x: row.x, y: row.y, bits: bits)
        }
        .sorted { $0.bits.count > $1.bits.count }
    }

    private enum SaveScope {
        case cities
        case children(ChildKey)
    }

    /// Replaces the tile's areas for the places in `scope` and records the tile as up to date.
    private func save(_ tile: Tile, owner: [Int64?], scope: SaveScope) throws {
        var totals: [Int64: Double] = [:]
        for cell in 0..<Self.cellCount {
            if let id = owner[cell] {
                totals[id, default: 0] += FogGrid.cellArea(row: tile.y * FogGrid.cellsPerTile + cell / FogGrid.cellsPerTile)
            }
        }
        let x = Int64(tile.x), y = Int64(tile.y), cells = Int64(tile.bits.count)
        let db = try database()
        try db.transaction {
            switch scope {
            case .cities:
                try db.run(
                    "DELETE FROM tile_place_areas WHERE x = ? AND y = ? AND place IN (SELECT id FROM places WHERE kind = ?)",
                    [.int(x), .int(y), .text(PlaceLevel.city.rawValue)]
                )
                try db.run("INSERT OR REPLACE INTO tile_places (x, y, cells) VALUES (?, ?, ?)", [.int(x), .int(y), .int(cells)])
            case .children(let key):
                try db.run(
                    "DELETE FROM tile_place_areas WHERE x = ? AND y = ? AND place IN (SELECT id FROM places WHERE parent = ? AND kind = ?)",
                    [.int(x), .int(y), .int(key.parent), .text(key.level.rawValue)]
                )
                try db.run(
                    "INSERT OR REPLACE INTO tile_children (x, y, parent, level, cells) VALUES (?, ?, ?, ?, ?)",
                    [.int(x), .int(y), .int(key.parent), .text(key.level.rawValue), .int(cells)]
                )
            }
            for (place, area) in totals {
                try db.run("INSERT INTO tile_place_areas (x, y, place, area) VALUES (?, ?, ?, ?)",
                           [.int(x), .int(y), .int(place), .double(area)])
            }
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
