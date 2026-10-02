import CoreLocation

/// Applies stored points to the explored grid.
///
/// Progress is tracked by the timestamp of the last revealed point, so points stored while
/// the grid couldn't be updated (e.g. before first unlock) are picked up by the next catch-up.
@MainActor
final class Revealer {
    nonisolated static let radius: CLLocationDistance = 150
    /// Consecutive points are joined by a strip only if they are this close in time...
    nonisolated static let maxGap: TimeInterval = 10 * 60
    /// ...and the implied speed is plausible, so a bad fix doesn't clear a stripe across town.
    nonisolated static let maxSpeed: CLLocationSpeed = 200 / 3.6
    /// Bump when the reveal rules change; the grid is then rebuilt from the raw points.
    static let version = 2

    private let store: PointStore

    init(store: PointStore) {
        self.store = store
    }

    func needsRebuild() throws -> Bool {
        try store.gridVersion() != Self.version
    }

    /// Clears the grid and reveals every stored point again. Returns the number of points applied.
    @discardableResult
    func rebuild() throws -> Int {
        try store.resetGrid(version: Self.version)
        return try catchUp()
    }

    /// Reveals stored points not yet applied to the grid. Throws without changing anything
    /// if the database is unavailable. Returns the number of points applied.
    @discardableResult
    func catchUp() throws -> Int {
        var (previous, points) = try store.unrevealedPoints()
        guard let last = points.last else { return 0 }
        let store = self.store
        var grid = ExploredGrid(load: { try store.loadTile($0) })
        var days: [String: DayTotals] = [:]
        for point in points {
            let areaBefore = grid.newlyExploredArea
            let distance = try Self.reveal(point, after: previous, in: &grid)
            days[Self.dayKey(for: point.timestamp), default: DayTotals()].add(
                area: grid.newlyExploredArea - areaBefore,
                distance: distance
            )
            previous = point
        }
        try store.saveReveal(grid.dirtyTiles, days: days, through: last.timestamp)
        return points.count
    }

    /// Returns the distance travelled from `previous`, or 0 if the points aren't connected.
    @discardableResult
    nonisolated static func reveal(_ point: LocationPoint, after previous: LocationPoint?, in grid: inout ExploredGrid) throws -> CLLocationDistance {
        if let previous, shouldConnect(previous, point) {
            try grid.revealStrip(from: previous.coordinate, to: point.coordinate, radius: radius)
            return distance(previous, point)
        }
        try grid.revealCircle(center: point.coordinate, radius: radius)
        return 0
    }

    /// Local calendar day, e.g. "2026-10-02".
    nonisolated static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    nonisolated static func shouldConnect(_ a: LocationPoint, _ b: LocationPoint) -> Bool {
        let gap = b.timestamp.timeIntervalSince(a.timestamp)
        guard gap > 0, gap <= maxGap else { return false }
        return distance(a, b) / gap <= maxSpeed
    }

    /// Great-circle distance in metres (haversine).
    nonisolated static func distance(_ a: LocationPoint, _ b: LocationPoint) -> CLLocationDistance {
        let earthRadius = 6_371_008.8
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * asin(min(1, h.squareRoot()))
    }
}
