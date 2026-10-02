import CoreLocation

/// Geometry of the explored grid.
///
/// The world is split into Web Mercator tiles at zoom 16, each a 32×32 bitmap of cells,
/// so the finest cells are zoom-21 "pixels" (~19 m at the equator, ~8 m at 64°N).
/// Coarser overview levels, each 8× coarser, let the map draw zoomed-out views quickly.
enum FogGrid {
    static let fineCellZoom = 21
    static let tileShift = 5
    static let cellsPerTile = 1 << tileShift
    /// Stored cell zooms, finest first. Each overview cell is set if any finer cell inside it is.
    static let cellZooms = [21, 18, 15, 12, 9]

    private static let maxLatitude = 85.05112878
    private static let earthCircumference = 40_075_016.686

    static func cellCount(zoom: Int) -> Int { 1 << zoom }

    /// Fractional cell position; the integer part is the cell index.
    static func cellPosition(of coordinate: CLLocationCoordinate2D, zoom: Int = fineCellZoom) -> (x: Double, y: Double) {
        let n = Double(cellCount(zoom: zoom))
        let latitude = min(max(coordinate.latitude, -maxLatitude), maxLatitude) * .pi / 180
        let x = (coordinate.longitude + 180) / 360 * n
        let y = (1 - log(tan(latitude) + 1 / cos(latitude)) / .pi) / 2 * n
        return (x, y)
    }

    /// Latitude of a (fractional) cell row.
    static func latitude(ofCellY y: Double, zoom: Int = fineCellZoom) -> CLLocationDegrees {
        let n = Double(cellCount(zoom: zoom))
        return atan(sinh(.pi * (1 - 2 * y / n))) * 180 / .pi
    }

    /// Area of one cell in row `y`, in m².
    static func cellArea(row y: Int, zoom: Int = fineCellZoom) -> Double {
        let size = cellSize(atLatitude: latitude(ofCellY: Double(y) + 0.5, zoom: zoom), zoom: zoom)
        return size * size
    }

    /// Width of one cell in metres at the given latitude.
    static func cellSize(atLatitude latitude: CLLocationDegrees, zoom: Int = fineCellZoom) -> CLLocationDistance {
        earthCircumference * cos(latitude * .pi / 180) / Double(cellCount(zoom: zoom))
    }
}

struct TileKey: Hashable {
    /// Tile zoom: the cell zoom minus 5 (16 for the finest level).
    var zoom: Int
    var x: Int
    var y: Int

    var cellZoom: Int { zoom + FogGrid.tileShift }

    init(zoom: Int, x: Int, y: Int) {
        self.zoom = zoom
        self.x = x
        self.y = y
    }

    /// The tile containing the given cell.
    init(cellZoom: Int, cellX: Int, cellY: Int) {
        self.init(zoom: cellZoom - FogGrid.tileShift, x: cellX >> FogGrid.tileShift, y: cellY >> FogGrid.tileShift)
    }
}

/// A 32×32 bitmap of explored cells, stored as 128 bytes.
struct TileBits: Equatable {
    static let byteCount = 128

    private(set) var words = [UInt64](repeating: 0, count: 16)

    init() {}

    init?(data: Data) {
        guard data.count == Self.byteCount else { return nil }
        words = data.withUnsafeBytes { bytes in
            (0..<16).map { UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: $0 * 8, as: UInt64.self)) }
        }
    }

    var data: Data {
        words.map(\.littleEndian).withUnsafeBufferPointer { Data(buffer: $0) }
    }

    var count: Int { words.reduce(0) { $0 + $1.nonzeroBitCount } }

    func count(row: Int) -> Int {
        let word = words[row >> 1] >> UInt64((row & 1) * 32)
        return (word & 0xFFFF_FFFF).nonzeroBitCount
    }

    func contains(column: Int, row: Int) -> Bool {
        let index = row * FogGrid.cellsPerTile + column
        return words[index >> 6] & (1 << UInt64(index & 63)) != 0
    }

    /// Returns false if the cell was already set.
    @discardableResult
    mutating func insert(column: Int, row: Int) -> Bool {
        let index = row * FogGrid.cellsPerTile + column
        let mask: UInt64 = 1 << UInt64(index & 63)
        guard words[index >> 6] & mask == 0 else { return false }
        words[index >> 6] |= mask
        return true
    }
}
