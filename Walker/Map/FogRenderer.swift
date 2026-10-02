import MapKit

/// A world-sized overlay; all the work happens in `FogRenderer`.
final class FogOverlay: NSObject, MKOverlay {
    let coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    let boundingMapRect = MKMapRect.world
}

final class FogRenderer: MKOverlayRenderer {
    private let reader: TileReader

    init(overlay: FogOverlay, reader: TileReader) {
        self.reader = reader
        super.init(overlay: overlay)
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let range = FogBitmap.CellRange(covering: mapRect, zoomScale: Double(zoomScale))
        let tiles = reader.tiles(for: range.tileKeys)
        // About one image pixel per screen point is enough for a soft edge.
        let cellPoints = range.cellSize * Double(zoomScale)
        let scale = min(FogBitmap.maxScale, max(1, Int(cellPoints.rounded())))
        guard let image = FogBitmap.image(for: range, tiles: tiles, scale: scale) else { return }

        let drawRect = rect(for: range.mapRect)
        context.interpolationQuality = .none
        // The renderer's context has y pointing down; CGImage rows are drawn y-up.
        context.translateBy(x: drawRect.minX, y: drawRect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: drawRect.size))
    }
}

/// Builds the fog image for one map tile: fog where unexplored.
///
/// Drawing cells directly shows a staircase, so the edge is taken from a blurred copy of the
/// cells instead, which follows the true outline. The raw cells are kept too, so a lone
/// explored cell (common at overview levels) doesn't blur away. Both are bilinearly
/// interpolated between cell centres by hand, since MapKit ignores image smoothing.
/// The image covers `margin` extra cells on each side so neighbouring map tiles match without seams.
enum FogBitmap {
    static let color: (red: Double, green: Double, blue: Double) = (0.11, 0.13, 0.18)
    static let opacity = 0.82
    /// Overview levels are picked so cells stay at least this many screen points wide.
    static let minCellPoints = 2.0
    /// Upper bound on image pixels per cell, to bound the work per map tile.
    static let maxScale = 8
    /// Cells beyond the map tile needed by the blur (2) and the interpolation (1).
    static let margin = 3

    struct CellRange {
        var zoom: Int
        var minX: Int
        var minY: Int
        var width: Int
        var height: Int

        init(zoom: Int, minX: Int, minY: Int, width: Int, height: Int) {
            self.zoom = zoom
            self.minX = minX
            self.minY = minY
            self.width = width
            self.height = height
        }

        init(covering mapRect: MKMapRect, zoomScale: Double) {
            let zoom = FogBitmap.cellZoom(forZoomScale: zoomScale)
            let cellSize = MKMapSize.world.width / Double(FogGrid.cellCount(zoom: zoom))
            let minX = Int(floor(mapRect.minX / cellSize)) - FogBitmap.margin
            let minY = Int(floor(mapRect.minY / cellSize)) - FogBitmap.margin
            let maxX = Int(ceil(mapRect.maxX / cellSize)) + FogBitmap.margin - 1
            let maxY = Int(ceil(mapRect.maxY / cellSize)) + FogBitmap.margin - 1
            self.init(zoom: zoom, minX: minX, minY: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        }

        var cellSize: Double { MKMapSize.world.width / Double(FogGrid.cellCount(zoom: zoom)) }

        var mapRect: MKMapRect {
            MKMapRect(
                x: Double(minX) * cellSize,
                y: Double(minY) * cellSize,
                width: Double(width) * cellSize,
                height: Double(height) * cellSize
            )
        }

        var tileKeys: [TileKey] {
            let shift = FogGrid.tileShift
            let tileCount = FogGrid.cellCount(zoom: zoom) >> shift
            var keys = Set<TileKey>()
            for ty in (minY >> shift)...((minY + height - 1) >> shift) where ty >= 0 && ty < tileCount {
                for tx in (minX >> shift)...((minX + width - 1) >> shift) {
                    keys.insert(TileKey(zoom: zoom - shift, x: ((tx % tileCount) + tileCount) % tileCount, y: ty))
                }
            }
            return Array(keys)
        }
    }

    /// The finest stored level whose cells are at least `minCellPoints` wide on screen.
    static func cellZoom(forZoomScale zoomScale: Double) -> Int {
        FogGrid.cellZooms.first { zoom in
            MKMapSize.world.width / Double(FogGrid.cellCount(zoom: zoom)) * zoomScale >= minCellPoints
        } ?? FogGrid.cellZooms.last!
    }

    static func isExplored(x: Int, y: Int, zoom: Int, tiles: [TileKey: TileBits]) -> Bool {
        let n = FogGrid.cellCount(zoom: zoom)
        guard y >= 0, y < n else { return false }
        let x = ((x % n) + n) % n
        let mask = FogGrid.cellsPerTile - 1
        return tiles[TileKey(cellZoom: zoom, cellX: x, cellY: y)]?.contains(column: x & mask, row: y & mask) ?? false
    }

    /// `scale` is image pixels per cell; at 1 each pixel is exactly one cell.
    static func image(for range: CellRange, tiles: [TileKey: TileBits], scale: Int = 1) -> CGImage? {
        let explored: [Double] = (0..<range.width * range.height).map { index in
            let column = index % range.width
            let row = index / range.width
            return isExplored(x: range.minX + column, y: range.minY + row, zoom: range.zoom, tiles: tiles) ? 1 : 0
        }
        let blurred = blur(explored, width: range.width, height: range.height)
        // Precompute per-axis interpolation: the two neighbouring cells and the weight of the second.
        func samples(cells: Int) -> [(Int, Int, Double)] {
            (0..<cells * scale).map { pixel in
                let position = (Double(pixel) + 0.5) / Double(scale) - 0.5
                let lower = Int(floor(position))
                let weight = position - Double(lower)
                return (min(max(lower, 0), cells - 1), min(max(lower + 1, 0), cells - 1), weight)
            }
        }
        let xs = samples(cells: range.width)
        let ys = samples(cells: range.height)
        let width = xs.count
        let height = ys.count

        // Premultiplied RGBA of full fog, written directly for pixels well outside explored areas.
        let fullFog: (UInt8, UInt8, UInt8, UInt8) = (
            UInt8(color.red * opacity * 255), UInt8(color.green * opacity * 255),
            UInt8(color.blue * opacity * 255), UInt8(opacity * 255)
        )
        let cells = range.width
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        explored.withUnsafeBufferPointer { raw in
            blurred.withUnsafeBufferPointer { soft in
                pixels.withUnsafeMutableBufferPointer { out in
                    for (row, (y0, y1, wy)) in ys.enumerated() {
                        for (column, (x0, x1, wx)) in xs.enumerated() {
                            let i00 = y0 * cells + x0, i01 = y0 * cells + x1
                            let i10 = y1 * cells + x0, i11 = y1 * cells + x1
                            let offset = (row * width + column) * 4
                            // Fast paths: all four neighbouring cells explored, or none explored and
                            // too little blur to reach the edge threshold.
                            if raw[i00] + raw[i01] + raw[i10] + raw[i11] == 4 { continue }
                            if raw[i00] + raw[i01] + raw[i10] + raw[i11] == 0,
                               max(soft[i00], soft[i01], soft[i10], soft[i11]) <= 0.15 {
                                (out[offset], out[offset + 1], out[offset + 2], out[offset + 3]) = fullFog
                                continue
                            }
                            let rawValue = (raw[i00] * (1 - wx) + raw[i01] * wx) * (1 - wy)
                                + (raw[i10] * (1 - wx) + raw[i11] * wx) * wy
                            let softValue = (soft[i00] * (1 - wx) + soft[i01] * wx) * (1 - wy)
                                + (soft[i10] * (1 - wx) + soft[i11] * wx) * wy
                            let fog = opacity * (1 - max(smoothstep(0.15, 0.5, softValue), rawValue))
                            guard fog > 0 else { continue }
                            out[offset] = UInt8(color.red * fog * 255)
                            out[offset + 1] = UInt8(color.green * fog * 255)
                            out[offset + 2] = UInt8(color.blue * fog * 255)
                            out[offset + 3] = UInt8(fog * 255)
                        }
                    }
                }
            }
        }
        return makeImage(pixels: pixels, width: width, height: height)
    }

    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Separable 1-4-6-4-1 blur; samples past the edges repeat the edge cell.
    /// Written out by hand because this runs per map tile, in Debug builds too.
    private static func blur(_ field: [Double], width: Int, height: Int) -> [Double] {
        var horizontal = [Double](repeating: 0, count: field.count)
        var result = [Double](repeating: 0, count: field.count)
        field.withUnsafeBufferPointer { input in
            horizontal.withUnsafeMutableBufferPointer { output in
                for row in 0..<height {
                    let base = row * width
                    for column in 0..<width {
                        let a = input[base + max(column - 2, 0)], b = input[base + max(column - 1, 0)]
                        let c = input[base + column]
                        let d = input[base + min(column + 1, width - 1)], e = input[base + min(column + 2, width - 1)]
                        output[base + column] = (a + 4 * b + 6 * c + 4 * d + e) / 16
                    }
                }
            }
        }
        horizontal.withUnsafeBufferPointer { input in
            result.withUnsafeMutableBufferPointer { output in
                for row in 0..<height {
                    let a = max(row - 2, 0) * width, b = max(row - 1, 0) * width, c = row * width
                    let d = min(row + 1, height - 1) * width, e = min(row + 2, height - 1) * width
                    for column in 0..<width {
                        output[c + column] = (input[a + column] + 4 * input[b + column] + 6 * input[c + column]
                            + 4 * input[d + column] + input[e + column]) / 16
                    }
                }
            }
        }
        return result
    }

    private static func makeImage(pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
