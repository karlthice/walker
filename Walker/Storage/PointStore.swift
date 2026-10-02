import Foundation

enum LogKind: String {
    case launch, auth, resume, pause, geofence, visit, info, error
}

struct LogEvent: Identifiable {
    var id: Int64
    var timestamp: Date
    var kind: LogKind
    var message: String
}

/// Local storage for accepted location points and the debug event log.
///
/// Right after a reboot, iOS can deliver locations before the phone has been unlocked,
/// when the database file is still encrypted. Writes that fail are buffered in memory
/// and flushed once protected data becomes available.
@MainActor
final class PointStore {
    static let shared = PointStore(url: defaultURL)

    static var defaultURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "Walker", directoryHint: .isDirectory)
            .appending(path: "walker.sqlite")
    }

    private static let maxEvents = 5000

    /// nil means an in-memory database (tests).
    private let url: URL?
    private var db: Database?
    private var pendingPoints: [LocationPoint] = []
    private var pendingEvents: [(Date, LogKind, String)] = []

    init(url: URL?) {
        self.url = url
        openIfNeeded()
    }

    func insert(_ point: LocationPoint) {
        do {
            try write(point, to: requireDatabase())
            flushPending()
        } catch {
            pendingPoints.append(point)
        }
    }

    func log(_ kind: LogKind, _ message: String) {
        let event = (Date(), kind, message)
        do {
            try write(event, to: requireDatabase())
            flushPending()
        } catch {
            pendingEvents.append(event)
        }
    }

    func flushPending() {
        guard !pendingPoints.isEmpty || !pendingEvents.isEmpty, let db = openIfNeeded() else { return }
        do {
            try db.transaction {
                for point in pendingPoints { try write(point, to: db) }
                for event in pendingEvents { try write(event, to: db) }
            }
            pendingPoints.removeAll()
            pendingEvents.removeAll()
        } catch {
            // Still locked; keep buffering.
        }
    }

    func lastPoint() -> LocationPoint? {
        (try? requireDatabase().query(
            "SELECT ts, lat, lon, acc FROM points ORDER BY ts DESC LIMIT 1",
            map: Self.point
        ))?.first
    }

    func points(since date: Date) -> [LocationPoint] {
        (try? requireDatabase().query(
            "SELECT ts, lat, lon, acc FROM points WHERE ts >= ? ORDER BY ts",
            [.double(date.timeIntervalSince1970)],
            map: Self.point
        )) ?? []
    }

    func pointCount() -> Int {
        let count = try? requireDatabase().query("SELECT COUNT(*) FROM points") { $0.int(0) }.first
        return Int(count ?? 0) + pendingPoints.count
    }

    func recentEvents(limit: Int = 500) -> [LogEvent] {
        (try? requireDatabase().query(
            "SELECT id, ts, kind, message FROM events ORDER BY id DESC LIMIT ?",
            [.int(Int64(limit))]
        ) { row in
            LogEvent(
                id: row.int(0),
                timestamp: Date(timeIntervalSince1970: row.double(1)),
                kind: LogKind(rawValue: row.text(2)) ?? .info,
                message: row.text(3)
            )
        }) ?? []
    }

    // MARK: - Private

    @discardableResult
    private func openIfNeeded() -> Database? {
        if let db { return db }
        do {
            let db: Database
            if let url {
                let directory = url.deletingLastPathComponent()
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
                )
                db = try Database(path: url.path)
            } else {
                db = try Database(path: ":memory:")
            }
            try migrate(db)
            if let url {
                try? FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: url.path
                )
            }
            self.db = db
            return db
        } catch {
            return nil
        }
    }

    private func requireDatabase() throws -> Database {
        guard let db = openIfNeeded() else { throw DatabaseError(description: "database unavailable") }
        return db
    }

    private func migrate(_ db: Database) throws {
        try db.execute("PRAGMA journal_mode = WAL")
        try db.execute("""
            CREATE TABLE IF NOT EXISTS points (
                id INTEGER PRIMARY KEY,
                ts REAL NOT NULL,
                lat REAL NOT NULL,
                lon REAL NOT NULL,
                acc REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS points_ts ON points(ts);
            CREATE TABLE IF NOT EXISTS events (
                id INTEGER PRIMARY KEY,
                ts REAL NOT NULL,
                kind TEXT NOT NULL,
                message TEXT NOT NULL
            );
            """)
        try db.run(
            "DELETE FROM events WHERE id <= (SELECT MAX(id) FROM events) - ?",
            [.int(Int64(Self.maxEvents))]
        )
    }

    private func write(_ point: LocationPoint, to db: Database) throws {
        try db.run(
            "INSERT INTO points (ts, lat, lon, acc) VALUES (?, ?, ?, ?)",
            [.double(point.timestamp.timeIntervalSince1970), .double(point.latitude),
             .double(point.longitude), .double(point.accuracy)]
        )
    }

    private func write(_ event: (Date, LogKind, String), to db: Database) throws {
        try db.run(
            "INSERT INTO events (ts, kind, message) VALUES (?, ?, ?)",
            [.double(event.0.timeIntervalSince1970), .text(event.1.rawValue), .text(event.2)]
        )
    }

    private static func point(_ row: Database.Row) -> LocationPoint {
        LocationPoint(
            timestamp: Date(timeIntervalSince1970: row.double(0)),
            latitude: row.double(1),
            longitude: row.double(2),
            accuracy: row.double(3)
        )
    }
}
