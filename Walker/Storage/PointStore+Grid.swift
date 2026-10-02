import Foundation

/// Newly explored area (m²) and connected distance travelled (m).
struct DayTotals: Equatable {
    var area: Double = 0
    var distance: Double = 0

    mutating func add(area: Double, distance: Double) {
        self.area += area
        self.distance += distance
    }
}

struct DayStat: Identifiable, Equatable {
    var day: Date
    var totals: DayTotals
    var id: Date { day }
}

/// Explored-grid storage. Unlike the point methods, these throw so a locked database never
/// looks like an empty grid (saving that would wipe explored tiles).
extension PointStore {
    func gridVersion() throws -> Int {
        Int(try meta("gridVersion") ?? "") ?? 0
    }

    func resetGrid(version: Int) throws {
        let db = try requireDatabase()
        try db.transaction {
            try db.run("DELETE FROM tiles")
            try db.run("DELETE FROM daily")
            // Place assignments are per tile; tiles change meaning when the grid does.
            try db.run("DELETE FROM tile_places")
            try db.run("DELETE FROM tile_neighbourhoods")
            try db.run("DELETE FROM tile_place_areas")
            try db.run("DELETE FROM meta WHERE key = 'revealedThrough'")
            try setMeta("gridVersion", "\(version)", in: db)
        }
    }

    /// Points newer than the last revealed one, plus the last revealed point (to connect a strip from).
    func unrevealedPoints() throws -> (previous: LocationPoint?, points: [LocationPoint]) {
        let db = try requireDatabase()
        let through = try meta("revealedThrough").flatMap(Double.init)
        var previous: LocationPoint?
        if let through {
            previous = try db.query(
                "SELECT ts, lat, lon, acc FROM points WHERE ts <= ? ORDER BY ts DESC LIMIT 1",
                [.double(through)],
                map: Self.point
            ).first
        }
        let points = try db.query(
            "SELECT ts, lat, lon, acc FROM points WHERE ts > ? ORDER BY ts",
            [.double(through ?? -Double.greatestFiniteMagnitude)],
            map: Self.point
        )
        return (previous, points)
    }

    func loadTile(_ key: TileKey) throws -> TileBits? {
        try requireDatabase().query(
            "SELECT bits FROM tiles WHERE z = ? AND x = ? AND y = ?",
            [.int(Int64(key.zoom)), .int(Int64(key.x)), .int(Int64(key.y))]
        ) { $0.blob(0) }
        .first
        .flatMap(TileBits.init(data:))
    }

    func saveReveal(_ tiles: [TileKey: TileBits], days: [String: DayTotals] = [:], through: Date) throws {
        let db = try requireDatabase()
        try db.transaction {
            for (key, bits) in tiles {
                try db.run(
                    "INSERT OR REPLACE INTO tiles (z, x, y, bits) VALUES (?, ?, ?, ?)",
                    [.int(Int64(key.zoom)), .int(Int64(key.x)), .int(Int64(key.y)), .blob(bits.data)]
                )
            }
            for (day, totals) in days {
                try db.run(
                    """
                    INSERT INTO daily (day, area, distance) VALUES (?, ?, ?)
                    ON CONFLICT(day) DO UPDATE SET area = area + excluded.area, distance = distance + excluded.distance
                    """,
                    [.text(day), .double(totals.area), .double(totals.distance)]
                )
            }
            try setMeta("revealedThrough", "\(through.timeIntervalSince1970)", in: db)
        }
    }

    /// Per-day totals, oldest first. Days are local calendar days.
    func dailyStats(calendar: Calendar = .current) -> [DayStat] {
        let rows = (try? requireDatabase().query("SELECT day, area, distance FROM daily ORDER BY day") { row in
            (row.text(0), DayTotals(area: row.double(1), distance: row.double(2)))
        }) ?? []
        return rows.compactMap { key, totals in
            let parts = key.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3,
                  let day = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
            else { return nil }
            return DayStat(day: day, totals: totals)
        }
    }

    func tileCount(zoom: Int) -> Int {
        let count = try? requireDatabase().query("SELECT COUNT(*) FROM tiles WHERE z = ?", [.int(Int64(zoom))]) { $0.int(0) }.first
        return Int(count ?? 0)
    }

    private func meta(_ key: String) throws -> String? {
        try requireDatabase().query("SELECT value FROM meta WHERE key = ?", [.text(key)]) { $0.text(0) }.first
    }

    private func setMeta(_ key: String, _ value: String, in db: Database) throws {
        try db.run("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", [.text(key), .text(value)])
    }
}
