import CoreLocation
import CryptoKit

/// Country borders bundled with the app (Natural Earth 1:50m, public domain), built by
/// `scripts/make-countries.py`. Works offline; no coordinates leave the phone.
final class CountryIndex: Sendable {
    struct Country: Decodable, Sendable {
        let name: String
        let code: String
        /// ISO 3166-1 alpha-2, missing for a few disputed areas.
        let iso2: String?
        let areaKm2: Double
        /// minLon, minLat, maxLon, maxLat
        let bbox: [Double]
        /// Each ring is flattened lon, lat pairs; holes are included and handled by the even-odd rule.
        let rings: [[Double]]

        /// The flag emoji, made of the regional indicator symbols for the two letters.
        var flag: String? {
            guard let iso2 else { return nil }
            let scalars = iso2.uppercased().unicodeScalars.compactMap { UnicodeScalar(0x1F1E6 - 0x41 + $0.value) }
            return scalars.count == 2 ? String(String.UnicodeScalarView(scalars)) : nil
        }

        func boxContains(_ c: CLLocationCoordinate2D, margin: Double = 0) -> Bool {
            c.longitude >= bbox[0] - margin && c.latitude >= bbox[1] - margin
                && c.longitude <= bbox[2] + margin && c.latitude <= bbox[3] + margin
        }

        func contains(_ c: CLLocationCoordinate2D) -> Bool {
            boxContains(c) && PolygonMath.contains(rings: rings, longitude: c.longitude, latitude: c.latitude)
        }

        /// Approximate distance in metres to the nearest border edge (local flat projection).
        func distance(to c: CLLocationCoordinate2D) -> CLLocationDistance {
            let metresPerDegree = 111_320.0
            let scaleX = metresPerDegree * cos(c.latitude * .pi / 180)
            var best = Double.infinity
            for ring in rings {
                var j = ring.count - 2
                for i in stride(from: 0, to: ring.count, by: 2) {
                    let ax = (ring[j] - c.longitude) * scaleX, ay = (ring[j + 1] - c.latitude) * metresPerDegree
                    let bx = (ring[i] - c.longitude) * scaleX, by = (ring[i + 1] - c.latitude) * metresPerDegree
                    let dx = bx - ax, dy = by - ay
                    let lengthSquared = dx * dx + dy * dy
                    let t = lengthSquared > 0 ? min(max(-(ax * dx + ay * dy) / lengthSquared, 0), 1) : 0
                    let px = ax + t * dx, py = ay + t * dy
                    best = min(best, px * px + py * py)
                    j = i
                }
            }
            return best.squareRoot()
        }
    }

    /// Points this close offshore still count for the nearest country; the 1:50m coastline
    /// is too coarse to drop a harbour walk into the sea.
    static let coastTolerance: CLLocationDistance = 5000

    static let shared: CountryIndex? = {
        guard let url = Bundle.main.url(forResource: "countries", withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? CountryIndex(data: data)
    }()

    let countries: [Country]
    /// Identifies this version of the borders, so results computed from older ones are redone.
    let checksum: String

    init(data: Data) throws {
        countries = try JSONDecoder().decode([Country].self, from: data)
        checksum = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    func country(at coordinate: CLLocationCoordinate2D) -> Country? {
        if let match = countries.first(where: { $0.contains(coordinate) }) {
            return match
        }
        let margin = Self.coastTolerance / 111_320 / max(cos(coordinate.latitude * .pi / 180), 0.01)
        return countries
            .filter { $0.boxContains(coordinate, margin: margin) }
            .map { ($0, $0.distance(to: coordinate)) }
            .filter { $0.1 <= Self.coastTolerance }
            .min { $0.1 < $1.1 }?
            .0
    }
}
