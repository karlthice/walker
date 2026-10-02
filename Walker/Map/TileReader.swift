import Foundation

/// Cached, thread-safe read access to explored tiles for the fog renderer, which draws on
/// background threads. Uses its own read-only connection so it never blocks on the writer.
final class TileReader: @unchecked Sendable {
    private static let maxCachedTiles = 20_000

    private let url: URL
    private let lock = NSLock()
    private var db: Database?
    /// A nil value records that the tile is known to be empty.
    private var cache: [TileKey: TileBits?] = [:]

    init(url: URL = PointStore.defaultURL) {
        self.url = url
    }

    func tiles(for keys: [TileKey]) -> [TileKey: TileBits] {
        lock.lock()
        defer { lock.unlock() }
        if cache.count > Self.maxCachedTiles {
            cache.removeAll()
        }
        var result: [TileKey: TileBits] = [:]
        for key in keys {
            let bits: TileBits?
            if let cached = cache[key] {
                bits = cached
            } else {
                bits = load(key)
                cache[key] = .some(bits)
            }
            if let bits { result[key] = bits }
        }
        return result
    }

    func invalidateAll() {
        lock.withLock { cache.removeAll() }
    }

    private func load(_ key: TileKey) -> TileBits? {
        if db == nil {
            db = try? Database(path: url.path, readOnly: true)
        }
        let rows = try? db?.query(
            "SELECT bits FROM tiles WHERE z = ? AND x = ? AND y = ?",
            [.int(Int64(key.zoom)), .int(Int64(key.x)), .int(Int64(key.y))]
        ) { $0.blob(0) }
        return rows?.first.flatMap(TileBits.init(data:))
    }
}
