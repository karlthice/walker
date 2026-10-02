import CoreLocation
import Testing
@testable import Walker

struct FogGridTests {
    @Test func nullIslandIsTheCentreOfTheWorld() {
        let position = FogGrid.cellPosition(of: CLLocationCoordinate2D(latitude: 0, longitude: 0))
        let half = Double(1 << 20)
        #expect(abs(position.x - half) < 1e-6)
        #expect(abs(position.y - half) < 1e-6)
    }

    @Test func northIsSmallerY() {
        let reykjavik = FogGrid.cellPosition(of: CLLocationCoordinate2D(latitude: 64.14, longitude: -21.94))
        let equator = FogGrid.cellPosition(of: CLLocationCoordinate2D(latitude: 0, longitude: -21.94))
        #expect(reykjavik.y < equator.y)
    }

    @Test func cellSizeShrinksWithLatitude() {
        #expect(abs(FogGrid.cellSize(atLatitude: 0) - 19.11) < 0.01)
        #expect(abs(FogGrid.cellSize(atLatitude: 64) - 8.38) < 0.01)
    }

    @Test func tileKeyForCell() {
        let key = TileKey(cellZoom: 21, cellX: 32 * 100 + 31, cellY: 32 * 7)
        #expect(key == TileKey(zoom: 16, x: 100, y: 7))
        #expect(key.cellZoom == 21)
    }

    @Test func tileBitsInsertAndRoundTrip() throws {
        var bits = TileBits()
        let inserted = [
            bits.insert(column: 0, row: 0),
            bits.insert(column: 31, row: 31),
            bits.insert(column: 5, row: 17),
            bits.insert(column: 5, row: 17),
        ]
        #expect(inserted == [true, true, true, false])
        #expect(bits.count == 3)
        #expect(bits.contains(column: 31, row: 31))
        #expect(!bits.contains(column: 30, row: 31))

        let restored = try #require(TileBits(data: bits.data))
        #expect(restored == bits)
        #expect(bits.data.count == TileBits.byteCount)
        #expect(TileBits(data: Data([1, 2, 3])) == nil)
    }
}
