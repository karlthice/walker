import CoreLocation
import Testing
@testable import Walker

/// Offsets a coordinate by metres (small distances only).
func offset(_ coordinate: CLLocationCoordinate2D, north: Double = 0, east: Double = 0) -> CLLocationCoordinate2D {
    CLLocationCoordinate2D(
        latitude: coordinate.latitude + north / 111_320,
        longitude: coordinate.longitude + east / (111_320 * cos(coordinate.latitude * .pi / 180))
    )
}

let reykjavik = CLLocationCoordinate2D(latitude: 64.1466, longitude: -21.9426)

struct ExploredGridTests {
    @Test func circleCoversExpectedArea() throws {
        var grid = ExploredGrid()
        try grid.revealCircle(center: reykjavik, radius: 150)

        let fineCells = grid.tiles.filter { $0.key.zoom == 16 }.values.reduce(0) { $0 + $1.count }
        let cellSize = FogGrid.cellSize(atLatitude: reykjavik.latitude)
        let expected = Double.pi * pow(150 / cellSize, 2)
        #expect(abs(Double(fineCells) - expected) / expected < 0.05)
    }

    @Test func circleEdge() throws {
        var grid = ExploredGrid()
        try grid.revealCircle(center: reykjavik, radius: 150)

        #expect(grid.contains(reykjavik))
        #expect(grid.contains(offset(reykjavik, north: 140)))
        #expect(grid.contains(offset(reykjavik, east: -140)))
        #expect(!grid.contains(offset(reykjavik, north: 165)))
        #expect(!grid.contains(offset(reykjavik, east: 165)))
    }

    @Test func overviewLevelsAreSet() throws {
        var grid = ExploredGrid()
        try grid.revealCircle(center: reykjavik, radius: 150)

        for zoom in FogGrid.cellZooms {
            let position = FogGrid.cellPosition(of: reykjavik, zoom: zoom)
            #expect(grid.contains(cellZoom: zoom, x: Int(position.x), y: Int(position.y)))
        }
    }

    @Test func circleOnTileBoundaryTouchesBothTiles() throws {
        // A longitude exactly on a zoom-16 tile edge.
        let n = Double(FogGrid.cellCount(zoom: 21))
        let tileX = 29_000
        let edge = CLLocationCoordinate2D(latitude: reykjavik.latitude, longitude: Double(tileX * 32) / n * 360 - 180)

        var grid = ExploredGrid()
        try grid.revealCircle(center: edge, radius: 150)

        let fineTileXs = Set(grid.dirty.filter { $0.zoom == 16 }.map(\.x))
        #expect(fineTileXs.contains(tileX - 1))
        #expect(fineTileXs.contains(tileX))
        #expect(grid.contains(offset(edge, east: -100)))
        #expect(grid.contains(offset(edge, east: 100)))
    }

    @Test func stripCoversTheLineBetweenPoints() throws {
        let end = offset(reykjavik, east: 1000)
        let middle = offset(reykjavik, east: 500)
        var grid = ExploredGrid()
        try grid.revealStrip(from: reykjavik, to: end, radius: 150)

        #expect(grid.contains(middle))
        #expect(grid.contains(offset(middle, north: 120)))
        #expect(!grid.contains(offset(middle, north: 170)))
        #expect(grid.contains(offset(end, east: 120)))
        #expect(!grid.contains(offset(end, east: 170)))
    }

    @Test func stripAcrossAntimeridianDoesNotSpanTheWorld() throws {
        let west = CLLocationCoordinate2D(latitude: 0, longitude: 179.999)
        let east = CLLocationCoordinate2D(latitude: 0, longitude: -179.999)
        var grid = ExploredGrid()
        try grid.revealStrip(from: west, to: east, radius: 150)

        #expect(grid.contains(west))
        #expect(grid.contains(east))
        #expect(!grid.contains(CLLocationCoordinate2D(latitude: 0, longitude: 0)))
        #expect(grid.dirty.filter { $0.zoom == 16 }.count <= 4)
    }

    @Test func loadedTilesKeepExistingCells() throws {
        let position = FogGrid.cellPosition(of: reykjavik)
        let key = TileKey(cellZoom: 21, cellX: Int(position.x), cellY: Int(position.y))
        var existing = TileBits()
        existing.insert(column: 0, row: 0)

        var grid = ExploredGrid(load: { $0 == key ? existing : nil })
        try grid.revealCircle(center: reykjavik, radius: 150)

        let bits = try #require(grid.dirtyTiles[key])
        #expect(bits.contains(column: 0, row: 0))
    }

    @Test func loaderErrorsPropagate() {
        struct Locked: Error {}
        var grid = ExploredGrid(load: { _ in throw Locked() })
        #expect(throws: Locked.self) { try grid.revealCircle(center: reykjavik, radius: 150) }
    }
}
