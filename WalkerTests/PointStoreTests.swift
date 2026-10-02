import Foundation
import Testing
@testable import Walker

@MainActor
struct PointStoreTests {
    @Test func insertsAndReadsBackPoints() {
        let store = PointStore(url: nil)
        let first = LocationPoint(timestamp: Date(timeIntervalSince1970: 100), latitude: 64.1, longitude: -21.9, accuracy: 15)
        let second = LocationPoint(timestamp: Date(timeIntervalSince1970: 200), latitude: 64.2, longitude: -21.8, accuracy: 30)
        store.insert(first)
        store.insert(second)

        #expect(store.pointCount() == 2)
        #expect(store.lastPoint() == second)
        #expect(store.points(since: Date(timeIntervalSince1970: 150)) == [second])
    }

    @Test func logsEventsNewestFirst() {
        let store = PointStore(url: nil)
        store.log(.launch, "first")
        store.log(.pause, "second")

        let events = store.recentEvents()
        #expect(events.map(\.message) == ["second", "first"])
        #expect(events.first?.kind == .pause)
    }

    @Test func persistsToFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
            .appending(path: "walker.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let point = LocationPoint(timestamp: Date(timeIntervalSince1970: 100), latitude: 64.1, longitude: -21.9, accuracy: 15)
        PointStore(url: url).insert(point)

        #expect(PointStore(url: url).lastPoint() == point)
    }
}
