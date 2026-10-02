import CoreLocation

/// Which country each explored map tile is in, saved in the database. A tile's country never
/// changes, so each tile is tested against the borders once instead of on every visit to Stats.
enum TileCountries {
    /// Assigns a country to every finest-grid tile that doesn't have one yet ('' for none, e.g. at sea).
    static func update(_ db: Database, countries: CountryIndex) throws {
        // Saved countries are only valid for the grid and the borders they were computed with.
        let version = "z\(FogGrid.fineTileZoom)-\(countries.checksum)"
        let saved = try db.query("SELECT value FROM meta WHERE key = 'tileCountries'") { $0.text(0) }.first
        if saved != version {
            try db.transaction {
                try db.run("DELETE FROM tile_countries")
                try db.run("INSERT OR REPLACE INTO meta (key, value) VALUES ('tileCountries', ?)", [.text(version)])
            }
        }

        let missing = try db.query(
            """
            SELECT t.x, t.y FROM tiles t
            LEFT JOIN tile_countries c ON c.x = t.x AND c.y = t.y
            WHERE t.z = ? AND c.country IS NULL
            """,
            [.int(Int64(FogGrid.fineTileZoom))]
        ) { row in (x: Int(row.int(0)), y: Int(row.int(1))) }
        guard !missing.isEmpty else { return }
        try db.transaction {
            for tile in missing {
                let code = countries.country(at: centre(x: tile.x, y: tile.y))?.code ?? ""
                try db.run("INSERT OR REPLACE INTO tile_countries (x, y, country) VALUES (?, ?, ?)",
                           [.int(Int64(tile.x)), .int(Int64(tile.y)), .text(code)])
            }
        }
    }

    /// The tile's centre, which decides its country: tiles are at most ~300 m across.
    static func centre(x: Int, y: Int) -> CLLocationCoordinate2D {
        let zoom = FogGrid.fineTileZoom
        return CLLocationCoordinate2D(
            latitude: FogGrid.latitude(ofCellY: Double(y) + 0.5, zoom: zoom),
            longitude: (Double(x) + 0.5) / Double(FogGrid.cellCount(zoom: zoom)) * 360 - 180
        )
    }
}
