import CoreLocation

/// A place from OpenStreetMap: a boundary, or a point (such as a place=quarter node) where
/// the neighbourhood has no boundary.
struct OSMPlace: Equatable, Sendable {
    /// Relations keep their OSM id, ways are offset and nodes negated, since the id spaces overlap.
    var id: Int64
    var name: String
    var englishName: String?
    /// nil for points.
    var shape: PlaceShape?
    var centre: CLLocationCoordinate2D

    static func == (a: OSMPlace, b: OSMPlace) -> Bool {
        a.id == b.id && a.name == b.name && a.englishName == b.englishName && a.shape == b.shape
            && a.centre.latitude == b.centre.latitude && a.centre.longitude == b.centre.longitude
    }

    static let wayOffset: Int64 = 1 << 44

    static func id(type: String, osmID: Int64) -> Int64 {
        switch type {
        case "relation": osmID
        case "way": osmID + wayOffset
        default: -osmID
        }
    }
}

/// Looks up places; a protocol so tests can stand in for the network.
protocol PlaceLookup: Sendable {
    /// The city or municipality containing the coordinate (Reykjavíkurborg, Barcelona, 金沢市),
    /// or nil where there is none, e.g. at sea.
    func city(at coordinate: CLLocationCoordinate2D) async throws -> OSMPlace?
}

struct PlaceLookupError: Error, LocalizedError {
    var errorDescription: String?
}

/// OpenStreetMap's Nominatim reverse geocoder. Only coordinates you have explored are sent,
/// and only when a country's cities are listed and a place isn't cached yet.
actor NominatimClient: PlaceLookup {
    /// Nominatim's usage policy allows at most one request per second.
    private static let minInterval: Duration = .milliseconds(1100)

    private let endpoint = URL(string: "https://nominatim.openstreetmap.org")!
    private let session: URLSession
    private var nextSlot = ContinuousClock.now

    init(session: URLSession = .shared) {
        self.session = session
    }

    func city(at coordinate: CLLocationCoordinate2D) async throws -> OSMPlace? {
        var components = URLComponents(url: endpoint.appending(path: "reverse"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "lat", value: "\(coordinate.latitude)"),
            URLQueryItem(name: "lon", value: "\(coordinate.longitude)"),
            // Nominatim's zoom 10 is the city or municipality level.
            URLQueryItem(name: "zoom", value: "10"),
            URLQueryItem(name: "format", value: "jsonv2"),
            URLQueryItem(name: "polygon_geojson", value: "1"),
            // Simplify boundaries to about 10 m: plenty for cells of 8–19 m, and much smaller.
            URLQueryItem(name: "polygon_threshold", value: "0.0001"),
            URLQueryItem(name: "namedetails", value: "1"),
        ]
        return try NominatimResponse.decode(try await get(components.url!))
    }

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Walker iOS app (https://github.com/karlthice/walker)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        for attempt in 1...3 {
            try await waitForSlot()
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 {
                return data
            }
            guard status == 429 || status == 503, attempt < 3 else {
                throw PlaceLookupError(errorDescription: "OpenStreetMap lookup failed (HTTP \(status)).")
            }
            try await Task.sleep(for: .seconds(5 * attempt))
        }
        throw PlaceLookupError(errorDescription: "OpenStreetMap is busy; try again later.")
    }

    /// Reserves the next request slot before sleeping, so concurrent callers queue up.
    private func waitForSlot() async throws {
        let slot = max(nextSlot, .now)
        nextSlot = slot + Self.minInterval
        try await Task.sleep(until: slot)
    }
}

struct NominatimResponse: Decodable {
    var osm_type: String?
    var osm_id: Int64?
    var lat: String?
    var lon: String?
    var name: String?
    var namedetails: [String: String]?
    var geojson: GeoJSON?
    var error: String?

    struct GeoJSON: Decodable {
        var type: String
        /// Each polygon is rings of [lon, lat] positions; the first ring is outer, the rest holes.
        var polygons: [[[[Double]]]] = []

        enum CodingKeys: String, CodingKey { case type, coordinates }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decode(String.self, forKey: .type)
            switch type {
            case "Polygon": polygons = [try container.decode([[[Double]]].self, forKey: .coordinates)]
            case "MultiPolygon": polygons = try container.decode([[[[Double]]]].self, forKey: .coordinates)
            default: break
            }
        }
    }

    static func decode(_ data: Data) throws -> OSMPlace? {
        try JSONDecoder().decode(NominatimResponse.self, from: data).place
    }

    var place: OSMPlace? {
        guard error == nil,
              let osmType = osm_type, let osmID = osm_id,
              let lat = lat.flatMap(Double.init), let lon = lon.flatMap(Double.init)
        else { return nil }
        let name = namedetails?["name"] ?? self.name ?? "Unnamed"
        let english = namedetails?["name:en"].flatMap { $0 == name ? nil : $0 }
        return OSMPlace(
            id: OSMPlace.id(type: osmType, osmID: osmID),
            name: name,
            englishName: english,
            shape: geojson.flatMap(Self.shape),
            centre: CLLocationCoordinate2D(latitude: lat, longitude: lon)
        )
    }

    private static func shape(from geojson: GeoJSON) -> PlaceShape? {
        var rings: [[Double]] = []
        var area = 0.0
        for polygon in geojson.polygons {
            for (index, positions) in polygon.enumerated() {
                // GeoJSON rings repeat the first position at the end; ours don't.
                let ring = positions.dropLast().flatMap { $0.prefix(2) }
                guard ring.count >= 6 else { continue }
                area += PolygonMath.ringArea(ring) * (index == 0 ? 1 : -1)
                rings.append(ring)
            }
        }
        return rings.isEmpty ? nil : PlaceShape(rings: rings, area: area)
    }
}
