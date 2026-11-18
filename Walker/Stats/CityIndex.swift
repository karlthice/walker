import CryptoKit
import Foundation

/// Major cities bundled with the app, built by `scripts/make-cities.py` from the curated list
/// in `scripts/cities.csv`. Boundaries © OpenStreetMap contributors, simplified to about 50 m.
/// Works offline; no coordinates leave the phone.
final class CityIndex: Sendable {
    struct City: Sendable {
        /// The OpenStreetMap relation of the boundary.
        let id: Int64
        let name: String
        /// The name used locally, when it differs (京都市 for Kyoto).
        let localName: String?
        /// The country's `code` in `CountryIndex`.
        let country: String
        /// Land area in m².
        let area: Double
        let edges: EdgeIndex
    }

    private struct Record: Decodable {
        let id: Int64
        let name: String
        let local: String?
        let country: String
        let area: Double
        let rings: [[Double]]
    }

    static let shared: CityIndex? = {
        guard let url = Bundle.main.url(forResource: "cities", withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? CityIndex(data: data)
    }()

    let cities: [City]
    /// Identifies this version of the list, so results computed from older ones are redone.
    let checksum: String

    init(data: Data) throws {
        cities = try JSONDecoder().decode([Record].self, from: data).map { record in
            City(id: record.id, name: record.name, localName: record.local, country: record.country, area: record.area,
                 edges: EdgeIndex(shape: PlaceShape(rings: record.rings, area: record.area)))
        }
        checksum = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
