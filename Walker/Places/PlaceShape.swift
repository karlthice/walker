import CoreLocation

/// Polygon helpers over rings of flattened lon, lat pairs (not closed: the last point
/// connects back to the first). Holes are just more rings; the even-odd rule handles them.
enum PolygonMath {
    private static let earthRadius = 6_371_008.8

    static func contains(rings: [[Double]], longitude: Double, latitude: Double) -> Bool {
        var inside = false
        for ring in rings {
            var j = ring.count - 2
            for i in stride(from: 0, to: ring.count, by: 2) {
                let (xi, yi, xj, yj) = (ring[i], ring[i + 1], ring[j], ring[j + 1])
                if (yi > latitude) != (yj > latitude),
                   longitude < (xj - xi) * (latitude - yi) / (yj - yi) + xi {
                    inside.toggle()
                }
                j = i
            }
        }
        return inside
    }

    /// Spherical area of one ring in m².
    static func ringArea(_ ring: [Double]) -> Double {
        var total = 0.0
        var j = ring.count - 2
        for i in stride(from: 0, to: ring.count, by: 2) {
            let (lon1, lat1, lon2, lat2) = (ring[j], ring[j + 1], ring[i], ring[i + 1])
            total += (lon2 - lon1) * .pi / 180 * (2 + sin(lat1 * .pi / 180) + sin(lat2 * .pi / 180))
            j = i
        }
        return abs(total) * earthRadius * earthRadius / 2
    }

    /// Approximate area in m² of the overlap of two shapes, by horizontal strips of about
    /// `step` metres: in each strip, the longitude intervals inside both are intersected.
    static func intersectionArea(_ a: [[Double]], _ b: [[Double]], step: Double = 200) -> Double {
        let boxA = boundingBox(of: a), boxB = boundingBox(of: b)
        let minLat = max(boxA[1], boxB[1]), maxLat = min(boxA[3], boxB[3])
        guard minLat < maxLat, max(boxA[0], boxB[0]) < min(boxA[2], boxB[2]) else { return 0 }

        let metresPerDegree = 111_320.0
        let rows = min(max(Int((maxLat - minLat) * metresPerDegree / step), 50), 2000)
        let rowHeight = (maxLat - minLat) / Double(rows)
        var total = 0.0
        for row in 0..<rows {
            let latitude = minLat + (Double(row) + 0.5) * rowHeight
            let overlap = intersect(intervals(a, latitude: latitude), intervals(b, latitude: latitude))
            total += overlap * metresPerDegree * cos(latitude * .pi / 180) * rowHeight * metresPerDegree
        }
        return total
    }

    /// Longitude intervals inside the rings along a line of latitude (even-odd rule).
    private static func intervals(_ rings: [[Double]], latitude: Double) -> [(Double, Double)] {
        var crossings: [Double] = []
        for ring in rings {
            var j = ring.count - 2
            for i in stride(from: 0, to: ring.count, by: 2) {
                let (xi, yi, xj, yj) = (ring[i], ring[i + 1], ring[j], ring[j + 1])
                if (yi > latitude) != (yj > latitude) {
                    crossings.append(xi + (latitude - yi) * (xj - xi) / (yj - yi))
                }
                j = i
            }
        }
        crossings.sort()
        return stride(from: 0, to: crossings.count - 1, by: 2).map { (crossings[$0], crossings[$0 + 1]) }
    }

    /// Total length of the overlap of two sorted interval lists.
    private static func intersect(_ a: [(Double, Double)], _ b: [(Double, Double)]) -> Double {
        var i = 0, j = 0, total = 0.0
        while i < a.count && j < b.count {
            total += max(0, min(a[i].1, b[j].1) - max(a[i].0, b[j].0))
            if a[i].1 < b[j].1 { i += 1 } else { j += 1 }
        }
        return total
    }

    static func boundingBox(of rings: [[Double]]) -> [Double] {
        var box = [Double.infinity, .infinity, -Double.infinity, -Double.infinity]
        for ring in rings {
            for i in stride(from: 0, to: ring.count, by: 2) {
                box[0] = min(box[0], ring[i])
                box[1] = min(box[1], ring[i + 1])
                box[2] = max(box[2], ring[i])
                box[3] = max(box[3], ring[i + 1])
            }
        }
        return box
    }
}

/// An administrative boundary and its land area.
struct PlaceShape: Codable, Equatable, Sendable {
    var rings: [[Double]]
    /// m², outer rings minus holes.
    var area: Double
    /// minLon, minLat, maxLon, maxLat
    var bbox: [Double]

    init(rings: [[Double]], area: Double) {
        self.rings = rings
        self.area = area
        self.bbox = PolygonMath.boundingBox(of: rings)
    }

    func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        coordinate.longitude >= bbox[0] && coordinate.longitude <= bbox[2]
            && coordinate.latitude >= bbox[1] && coordinate.latitude <= bbox[3]
            && PolygonMath.contains(rings: rings, longitude: coordinate.longitude, latitude: coordinate.latitude)
    }
}

/// Edges of a shape bucketed by finest-grid tile row, so measuring a tile only looks at
/// edges near it instead of the whole boundary.
struct EdgeIndex {
    struct Edge {
        var x1, y1, x2, y2: Double
    }

    private static let tileZoom = FogGrid.fineTileZoom

    let shape: PlaceShape
    private var rows: [Int: [Edge]] = [:]

    init(shape: PlaceShape) {
        self.shape = shape
        for ring in shape.rings {
            var j = ring.count - 2
            for i in stride(from: 0, to: ring.count, by: 2) {
                let edge = Edge(x1: ring[j], y1: ring[j + 1], x2: ring[i], y2: ring[i + 1])
                let top = Int(FogGrid.cellPosition(of: CLLocationCoordinate2D(latitude: max(edge.y1, edge.y2), longitude: 0), zoom: Self.tileZoom).y)
                let bottom = Int(FogGrid.cellPosition(of: CLLocationCoordinate2D(latitude: min(edge.y1, edge.y2), longitude: 0), zoom: Self.tileZoom).y)
                for row in top...bottom {
                    rows[row, default: []].append(edge)
                }
                j = i
            }
        }
    }

    func intersects(tileX: Int, tileY: Int) -> Bool {
        let bounds = Self.bounds(tileX: tileX, tileY: tileY)
        return bounds.minLon <= shape.bbox[2] && bounds.maxLon >= shape.bbox[0]
            && bounds.minLat <= shape.bbox[3] && bounds.maxLat >= shape.bbox[1]
    }

    /// Marks which set cells of a finest-grid tile lie inside the shape (row-major, 32×32).
    func inside(tileX: Int, tileY: Int, bits: TileBits) -> [Bool] {
        var result = [Bool](repeating: false, count: FogGrid.cellsPerTile * FogGrid.cellsPerTile)
        guard intersects(tileX: tileX, tileY: tileY) else { return result }
        let edges = rows[tileY] ?? []
        let bounds = Self.bounds(tileX: tileX, tileY: tileY)
        let cellWidth = (bounds.maxLon - bounds.minLon) / Double(FogGrid.cellsPerTile)

        for row in 0..<FogGrid.cellsPerTile where bits.count(row: row) > 0 {
            let latitude = FogGrid.latitude(ofCellY: Double(tileY * FogGrid.cellsPerTile + row) + 0.5)
            var crossings: [Double] = []
            for edge in edges where (edge.y1 > latitude) != (edge.y2 > latitude) {
                crossings.append(edge.x1 + (latitude - edge.y1) * (edge.x2 - edge.x1) / (edge.y2 - edge.y1))
            }
            crossings.sort()
            // Sweep columns left to right, counting crossings passed: odd means inside.
            var passed = 0
            for column in 0..<FogGrid.cellsPerTile {
                let longitude = bounds.minLon + (Double(column) + 0.5) * cellWidth
                while passed < crossings.count && crossings[passed] < longitude { passed += 1 }
                if passed % 2 == 1 && bits.contains(column: column, row: row) {
                    result[row * FogGrid.cellsPerTile + column] = true
                }
            }
        }
        return result
    }

    static func bounds(tileX: Int, tileY: Int) -> (minLon: Double, minLat: Double, maxLon: Double, maxLat: Double) {
        let n = Double(FogGrid.cellCount(zoom: tileZoom))
        return (
            Double(tileX) / n * 360 - 180,
            FogGrid.latitude(ofCellY: Double(tileY + 1), zoom: tileZoom),
            Double(tileX + 1) / n * 360 - 180,
            FogGrid.latitude(ofCellY: Double(tileY), zoom: tileZoom)
        )
    }
}
