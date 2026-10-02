import CoreLocation

struct CountryStat: Identifiable, Hashable, Sendable {
    var code: String
    var name: String
    var flag: String?
    /// m²
    var exploredArea: Double
    /// m²
    var countryArea: Double

    var id: String { code }
    var fraction: Double { countryArea > 0 ? exploredArea / countryArea : 0 }
}

enum StatsCalculator {
    /// Splits the explored area by country, each finest-grid tile going to the country at its
    /// centre (see `TileCountries`). Opens its own connection so it can run off the main actor.
    static func countryStats(databaseURL: URL, countries: CountryIndex) throws -> [CountryStat] {
        // The app creates the database; opening Stats before that must not create an empty one.
        let db = try Database(path: databaseURL.path, create: false)
        try TileCountries.update(db, countries: countries)
        let tiles = try db.query(
            """
            SELECT c.country, t.y, t.bits FROM tiles t
            JOIN tile_countries c ON c.x = t.x AND c.y = t.y
            WHERE t.z = ? AND c.country != ''
            """,
            [.int(Int64(FogGrid.fineTileZoom))]
        ) { row in
            (country: row.text(0), y: Int(row.int(1)), bits: TileBits(data: row.blob(2)))
        }

        var explored: [String: Double] = [:]
        for tile in tiles {
            guard let bits = tile.bits else { continue }
            for row in 0..<FogGrid.cellsPerTile {
                let count = bits.count(row: row)
                if count > 0 {
                    explored[tile.country, default: 0] += Double(count) * FogGrid.cellArea(row: tile.y * FogGrid.cellsPerTile + row)
                }
            }
        }

        let byCode = Dictionary(countries.countries.map { ($0.code, $0) }, uniquingKeysWith: { first, _ in first })
        return explored
            .compactMap { code, area in
                byCode[code].map {
                    CountryStat(code: code, name: $0.name, flag: $0.flag, exploredArea: area, countryArea: $0.areaKm2 * 1e6)
                }
            }
            .sorted { $0.exploredArea > $1.exploredArea }
    }
}
