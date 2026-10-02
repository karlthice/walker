import CoreLocation
import MapKit
import Testing
@testable import Walker

struct FogBitmapTests {
    private func alpha(of image: CGImage, column: Int, row: Int) -> UInt8 {
        let data = image.dataProvider!.data! as Data
        return data[(row * image.width + column) * 4 + 3]
    }

    private func range(around coordinate: CLLocationCoordinate2D, zoom: Int, size: Int) -> FogBitmap.CellRange {
        let position = FogGrid.cellPosition(of: coordinate, zoom: zoom)
        return FogBitmap.CellRange(zoom: zoom, minX: Int(position.x) - size / 2, minY: Int(position.y) - size / 2, width: size, height: size)
    }

    @Test func picksFinestLevelThatStaysVisible() {
        // Street level: a fine cell is many points wide.
        #expect(FogBitmap.cellZoom(forZoomScale: 1.0 / 16) == 21)
        // Whole world on screen: even the coarsest cells are tiny.
        #expect(FogBitmap.cellZoom(forZoomScale: 1.0 / 1_000_000) == 9)
        // Fine cells exactly 2 points wide is still the fine level; just below switches to the next.
        let fineCellMapPoints = MKMapSize.world.width / Double(1 << 21)
        #expect(FogBitmap.cellZoom(forZoomScale: 2 / fineCellMapPoints) == 21)
        #expect(FogBitmap.cellZoom(forZoomScale: 1.9 / fineCellMapPoints) == 18)
    }

    @Test func exploredCellsAreClear() throws {
        var grid = ExploredGrid()
        try grid.revealCircle(center: reykjavik, radius: 150)
        let range = range(around: reykjavik, zoom: 21, size: 64)

        let image = try #require(FogBitmap.image(for: range, tiles: grid.tiles))
        #expect(image.width == 64)
        #expect(alpha(of: image, column: 32, row: 32) == 0)
        #expect(alpha(of: image, column: 0, row: 0) > 0)
    }

    @Test func scaledImageHasSoftEdges() throws {
        var grid = ExploredGrid()
        try grid.revealCircle(center: reykjavik, radius: 150)
        let range = range(around: reykjavik, zoom: 21, size: 64)

        let image = try #require(FogBitmap.image(for: range, tiles: grid.tiles, scale: 4))
        #expect(image.width == 256)
        #expect(alpha(of: image, column: 128, row: 128) == 0)
        let full = UInt8(FogBitmap.opacity * 255)
        #expect(alpha(of: image, column: 0, row: 128) == full)
        // Walking out from the centre, some pixels must be part-way between clear and fog.
        let row = (0..<128).map { alpha(of: image, column: 128 - $0, row: 128) }
        #expect(row.contains { $0 > 0 && $0 < full })
    }

    @Test func overviewShowsExploredArea() throws {
        var grid = ExploredGrid()
        try grid.revealCircle(center: reykjavik, radius: 150)
        let range = range(around: reykjavik, zoom: 12, size: 8)

        let image = try #require(FogBitmap.image(for: range, tiles: grid.tiles))
        #expect(alpha(of: image, column: 4, row: 4) == 0)
        #expect(alpha(of: image, column: 0, row: 0) > 0)
    }

    @Test func rangeCoversMapRectWithMargin() {
        let mapRect = MKMapRect(x: 1000, y: 2000, width: 256, height: 256)
        let range = FogBitmap.CellRange(covering: mapRect, zoomScale: 1)
        #expect(range.mapRect.contains(mapRect))
        #expect(range.mapRect.minX <= mapRect.minX - range.cellSize)
        #expect(range.mapRect.maxY >= mapRect.maxY + range.cellSize)
    }

    @Test func tileKeysWrapAtTheAntimeridian() {
        let range = FogBitmap.CellRange(zoom: 21, minX: -2, minY: 1000, width: 4, height: 4)
        let xs = Set(range.tileKeys.map(\.x))
        #expect(xs == [0, (1 << 16) - 1])
    }

    @Test func renderingLargeHistoryIsFast() throws {
        // About a year of daily walks around one city.
        var grid = ExploredGrid()
        for day in 0..<365 {
            var coordinate = offset(reykjavik, north: Double(day % 19) * 300 - 3000, east: Double(day % 23) * 300 - 3500)
            for _ in 0..<20 {
                let next = offset(coordinate, north: 50, east: 60)
                try grid.revealStrip(from: coordinate, to: next, radius: 150)
                coordinate = next
            }
        }

        let clock = ContinuousClock()
        var images = 0
        let elapsed = clock.measure {
            for dy in -4..<4 {
                for dx in -4..<4 {
                    let base = range(around: reykjavik, zoom: 21, size: 130)
                    let tile = FogBitmap.CellRange(zoom: 21, minX: base.minX + dx * 130, minY: base.minY + dy * 130, width: 130, height: 130)
                    if FogBitmap.image(for: tile, tiles: grid.tiles, scale: 2) != nil { images += 1 }
                }
            }
        }
        let perImage = elapsed / images
        print("Fog bitmap: \(perImage) per 130×130-cell tile at 2× scale, \(grid.tiles.count) tiles in grid")
        #expect(images == 64)
        #expect(perImage < .milliseconds(50))
    }
}
