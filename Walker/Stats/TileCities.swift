import Foundation

struct PlaceStat: Identifiable, Hashable, Sendable {
    var id: Int64
    var name: String
    var localName: String?
    /// m²
    var exploredArea: Double
    /// m²
    var totalArea: Double

    var fraction: Double { totalArea > 0 ? exploredArea / totalArea : 0 }
}

/// How much of each bundled city every explored map tile covers, saved in the database.
/// A tile is measured cell by cell against the city boundaries once, and again only when its
/// explored cells change.
enum TileCities {
    private static let cellCount = FogGrid.cellsPerTile * FogGrid.cellsPerTile

    static func update(_ db: Database, cities: CityIndex) throws {
        // Saved areas are only valid for the grid and the city list they were computed with.
        let version = "z\(FogGrid.fineTileZoom)-\(cities.checksum)"
        let saved = try db.query("SELECT value FROM meta WHERE key = 'tileCities'") { $0.text(0) }.first
        if saved != version {
            try db.transaction {
                try db.run("DELETE FROM tile_places")
                try db.run("DELETE FROM tile_place_areas")
                try db.run("INSERT OR REPLACE INTO meta (key, value) VALUES ('tileCities', ?)", [.text(version)])
            }
        }

        let pending = try db.query(
            """
            SELECT t.x, t.y, t.bits, COALESCE(p.cells, -1) FROM tiles t
            LEFT JOIN tile_places p ON p.x = t.x AND p.y = t.y
            WHERE t.z = ?
            """,
            [.int(Int64(FogGrid.fineTileZoom))]
        ) { row in
            (x: Int(row.int(0)), y: Int(row.int(1)), bits: TileBits(data: row.blob(2)), cells: Int(row.int(3)))
        }
        .compactMap { row -> (x: Int, y: Int, bits: TileBits)? in
            guard let bits = row.bits, bits.count != row.cells else { return nil }
            return (row.x, row.y, bits)
        }
        guard !pending.isEmpty else { return }

        try db.transaction {
            for tile in pending {
                let areas = measure(tileX: tile.x, tileY: tile.y, bits: tile.bits, cities: cities)
                let x = Int64(tile.x), y = Int64(tile.y)
                try db.run("DELETE FROM tile_place_areas WHERE x = ? AND y = ?", [.int(x), .int(y)])
                for (place, area) in areas {
                    try db.run("INSERT INTO tile_place_areas (x, y, place, area) VALUES (?, ?, ?, ?)",
                               [.int(x), .int(y), .int(place), .double(area)])
                }
                try db.run("INSERT OR REPLACE INTO tile_places (x, y, cells) VALUES (?, ?, ?)",
                           [.int(x), .int(y), .int(Int64(tile.bits.count))])
            }
        }
    }

    /// Every bundled city in the country, with how much of it has been explored, most first.
    static func stats(_ db: Database, country: String, cities: CityIndex) throws -> [PlaceStat] {
        let explored = Dictionary(
            try db.query("SELECT place, SUM(area) FROM tile_place_areas GROUP BY place") { ($0.int(0), $0.double(1)) },
            uniquingKeysWith: { first, _ in first }
        )
        return cities.cities
            .filter { $0.country == country }
            .map { PlaceStat(id: $0.id, name: $0.name, localName: $0.localName, exploredArea: explored[$0.id] ?? 0, totalArea: $0.area) }
            .sorted { $0.exploredArea != $1.exploredArea ? $0.exploredArea > $1.exploredArea : $0.name < $1.name }
    }

    /// Explored area (m²) of the tile in each city; a cell counts for the first city containing it.
    private static func measure(tileX: Int, tileY: Int, bits: TileBits, cities: CityIndex) -> [Int64: Double] {
        var areas: [Int64: Double] = [:]
        var claimed = [Bool](repeating: false, count: cellCount)
        for city in cities.cities where city.edges.intersects(tileX: tileX, tileY: tileY) {
            let inside = city.edges.inside(tileX: tileX, tileY: tileY, bits: bits)
            for cell in 0..<cellCount where inside[cell] && !claimed[cell] {
                claimed[cell] = true
                areas[city.id, default: 0] += FogGrid.cellArea(row: tileY * FogGrid.cellsPerTile + cell / FogGrid.cellsPerTile)
            }
        }
        return areas
    }
}
