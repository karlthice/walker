import CoreLocation

/// A working set of explored tiles. Tiles are loaded on first touch and changed ones are
/// tracked in `dirty` so only those need saving.
struct ExploredGrid {
    typealias Loader = (TileKey) throws -> TileBits?

    private let load: Loader
    private(set) var tiles: [TileKey: TileBits] = [:]
    private(set) var dirty: Set<TileKey> = []

    init(load: @escaping Loader = { _ in nil }) {
        self.load = load
    }

    var dirtyTiles: [TileKey: TileBits] {
        dirty.reduce(into: [:]) { result, key in result[key] = tiles[key] }
    }

    func contains(cellZoom: Int = FogGrid.fineCellZoom, x: Int, y: Int) -> Bool {
        let key = TileKey(cellZoom: cellZoom, cellX: x, cellY: y)
        return tiles[key]?.contains(column: x & (FogGrid.cellsPerTile - 1), row: y & (FogGrid.cellsPerTile - 1)) ?? false
    }

    func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        let position = FogGrid.cellPosition(of: coordinate)
        return contains(x: Int(position.x), y: Int(position.y))
    }

    mutating func revealCircle(center: CLLocationCoordinate2D, radius: CLLocationDistance) throws {
        let position = FogGrid.cellPosition(of: center)
        let radiusInCells = radius / FogGrid.cellSize(atLatitude: center.latitude)
        try revealCapsule(from: position, to: position, radius: radiusInCells)
    }

    /// Reveals everything within `radius` of the line from `start` to `end`, including both end circles.
    mutating func revealStrip(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D, radius: CLLocationDistance) throws {
        let a = FogGrid.cellPosition(of: start)
        let b = FogGrid.cellPosition(of: end)
        let dx = b.x - a.x
        let dy = b.y - a.y
        // A segment spanning half the world crosses the antimeridian; don't draw it the long way round.
        guard abs(dx) < Double(FogGrid.cellCount(zoom: FogGrid.fineCellZoom)) / 2 else {
            try revealCircle(center: start, radius: radius)
            try revealCircle(center: end, radius: radius)
            return
        }
        let radiusInCells = radius / FogGrid.cellSize(atLatitude: (start.latitude + end.latitude) / 2)
        // Split long segments so each piece's bounding box stays small.
        let length = (dx * dx + dy * dy).squareRoot()
        let pieces = max(1, Int((length / max(radiusInCells, 1)).rounded(.up)))
        for i in 0..<pieces {
            let t0 = Double(i) / Double(pieces)
            let t1 = Double(i + 1) / Double(pieces)
            try revealCapsule(
                from: (a.x + dx * t0, a.y + dy * t0),
                to: (a.x + dx * t1, a.y + dy * t1),
                radius: radiusInCells
            )
        }
    }

    /// Sets the fine cell and the overview cells above it.
    mutating func setFineCell(x: Int, y: Int) throws {
        let n = FogGrid.cellCount(zoom: FogGrid.fineCellZoom)
        guard y >= 0, y < n else { return }
        let x = ((x % n) + n) % n
        // Overview cells are only ever set together with a fine cell, so if the fine cell
        // was already set there is nothing more to do.
        guard try insert(cellZoom: FogGrid.fineCellZoom, x: x, y: y) else { return }
        for zoom in FogGrid.cellZooms.dropFirst() {
            let shift = FogGrid.fineCellZoom - zoom
            try insert(cellZoom: zoom, x: x >> shift, y: y >> shift)
        }
    }

    /// Positions and radius are in fine-cell units. A cell is revealed if its centre is within reach.
    private mutating func revealCapsule(from a: (x: Double, y: Double), to b: (x: Double, y: Double), radius: Double) throws {
        let minX = Int(floor(min(a.x, b.x) - radius))
        let maxX = Int(floor(max(a.x, b.x) + radius))
        let minY = Int(floor(min(a.y, b.y) - radius))
        let maxY = Int(floor(max(a.y, b.y) + radius))
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        let radiusSquared = radius * radius

        for y in minY...maxY {
            for x in minX...maxX {
                let cx = Double(x) + 0.5
                let cy = Double(y) + 0.5
                var t = lengthSquared > 0 ? ((cx - a.x) * dx + (cy - a.y) * dy) / lengthSquared : 0
                t = min(max(t, 0), 1)
                let ex = a.x + t * dx - cx
                let ey = a.y + t * dy - cy
                if ex * ex + ey * ey <= radiusSquared {
                    try setFineCell(x: x, y: y)
                }
            }
        }
    }

    @discardableResult
    private mutating func insert(cellZoom: Int, x: Int, y: Int) throws -> Bool {
        let key = TileKey(cellZoom: cellZoom, cellX: x, cellY: y)
        var bits = try tiles[key] ?? load(key) ?? TileBits()
        let inserted = bits.insert(column: x & (FogGrid.cellsPerTile - 1), row: y & (FogGrid.cellsPerTile - 1))
        tiles[key] = bits
        if inserted { dirty.insert(key) }
        return inserted
    }
}
