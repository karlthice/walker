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
    static let version = 1

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
        for point in points {
            try Self.reveal(point, after: previous, in: &grid)
            previous = point
        }
        try store.saveReveal(grid.dirtyTiles, through: last.timestamp)
        return points.count
    }

    nonisolated static func reveal(_ point: LocationPoint, after previous: LocationPoint?, in grid: inout ExploredGrid) throws {
        if let previous, shouldConnect(previous, point) {
            try grid.revealStrip(from: previous.coordinate, to: point.coordinate, radius: radius)
        } else {
            try grid.revealCircle(center: point.coordinate, radius: radius)
        }
    }

    nonisolated static func shouldConnect(_ a: LocationPoint, _ b: LocationPoint) -> Bool {
        let gap = b.timestamp.timeIntervalSince(a.timestamp)
        guard gap > 0, gap <= maxGap else { return false }
        return a.location.distance(from: b.location) / gap <= maxSpeed
    }
}
