import Foundation

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

    func saveReveal(_ tiles: [TileKey: TileBits], through: Date) throws {
        let db = try requireDatabase()
        try db.transaction {
            for (key, bits) in tiles {
                try db.run(
                    "INSERT OR REPLACE INTO tiles (z, x, y, bits) VALUES (?, ?, ?, ?)",
                    [.int(Int64(key.zoom)), .int(Int64(key.x)), .int(Int64(key.y)), .blob(bits.data)]
                )
            }
            try setMeta("revealedThrough", "\(through.timeIntervalSince1970)", in: db)
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
