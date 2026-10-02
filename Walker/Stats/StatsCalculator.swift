import CoreLocation

struct CountryStat: Identifiable, Hashable, Sendable {
    var code: String
    var name: String
    /// m²
    var exploredArea: Double
    /// m²
    var countryArea: Double

    var id: String { code }
    var fraction: Double { countryArea > 0 ? exploredArea / countryArea : 0 }
}

enum StatsCalculator {
    /// Splits the explored area by country. Each finest-grid tile (≤ 300 m across) is assigned
    /// to the country at its centre, which is plenty precise for a percentage.
    /// Opens its own read-only connection so it can run off the main actor.
    static func countryStats(databaseURL: URL, countries: CountryIndex) throws -> [CountryStat] {
        let db = try Database(path: databaseURL.path, readOnly: true)
        let fineZoom = FogGrid.fineTileZoom
        let tiles = try db.query("SELECT x, y, bits FROM tiles WHERE z = ?", [.int(Int64(fineZoom))]) { row in
            (x: Int(row.int(0)), y: Int(row.int(1)), bits: TileBits(data: row.blob(2)))
        }

        let tileCount = Double(FogGrid.cellCount(zoom: fineZoom))
        var explored: [String: Double] = [:]
        var byCode: [String: CountryIndex.Country] = [:]
        for tile in tiles {
            guard let bits = tile.bits else { continue }
            var area = 0.0
            for row in 0..<FogGrid.cellsPerTile {
                let count = bits.count(row: row)
                if count > 0 {
                    area += Double(count) * FogGrid.cellArea(row: tile.y * FogGrid.cellsPerTile + row)
                }
            }
            let centre = CLLocationCoordinate2D(
                latitude: FogGrid.latitude(ofCellY: Double(tile.y) + 0.5, zoom: fineZoom),
                longitude: (Double(tile.x) + 0.5) / tileCount * 360 - 180
            )
            guard let country = countries.country(at: centre) else { continue }
            explored[country.code, default: 0] += area
            byCode[country.code] = country
        }

        return explored
            .compactMap { code, area in
                byCode[code].map { CountryStat(code: code, name: $0.name, exploredArea: area, countryArea: $0.areaKm2 * 1e6) }
            }
            .sorted { $0.exploredArea > $1.exploredArea }
    }
}
