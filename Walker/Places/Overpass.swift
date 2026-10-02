import CoreLocation

/// An OpenStreetMap place: an administrative boundary (relation), or a named point
/// (node tagged place=quarter etc.) where a city's neighbourhoods have no boundaries.
struct AdminArea: Equatable, Sendable {
    /// Relations keep their OSM id; nodes are negated, since the id spaces overlap.
    var id: Int64
    var name: String
    var englishName: String?
    /// admin_level for boundaries; 0 for points.
    var level: Int
    var shape: PlaceShape?
    /// Set for points.
    var centre: CLLocationCoordinate2D?
    /// The place=* tag for points.
    var placeKind: String?

    static func == (a: AdminArea, b: AdminArea) -> Bool {
        a.id == b.id && a.name == b.name && a.englishName == b.englishName && a.level == b.level && a.shape == b.shape
            && a.centre?.latitude == b.centre?.latitude && a.centre?.longitude == b.centre?.longitude && a.placeKind == b.placeKind
    }

    enum Neighbourhoods: Equatable {
        /// Boundaries covering most of the city: area and % can be measured.
        case boundaries([AdminArea])
        /// Named points: explored cells go to the nearest one; area only, no %.
        case points([AdminArea])
        case none
    }

    /// Boundaries are used when they cover at least this share of the city.
    static let minBoundaryCoverage = 0.5

    /// The city or municipality: the deepest boundary between the country and level 8.
    /// (Iceland: municipalities at 6; US: cities at 8; Berlin: the city-state at 4.)
    static func city(in areas: [AdminArea]) -> AdminArea? {
        areas.filter { (3...8).contains($0.level) }.max { $0.level < $1.level }
    }

    /// The city's neighbourhoods: its first level of boundary subdivision (9 and up, such as
    /// Miðborg in Reykjavík) if those cover most of the city, otherwise named points
    /// (as in Kanazawa, where most 町 are mapped as place=quarter nodes).
    static func neighbourhoods(in areas: [AdminArea], city: AdminArea) -> Neighbourhoods {
        guard let cityShape = city.shape else { return .none }

        let candidates = areas.filter { $0.id != city.id && $0.level >= 9 && $0.shape != nil }
        if let level = candidates.map(\.level).min() {
            let boundaries = candidates.filter { area in
                // map_to_area also returns neighbours that merely touch the city.
                guard area.level == level, let shape = area.shape else { return false }
                let centre = CLLocationCoordinate2D(latitude: (shape.bbox[1] + shape.bbox[3]) / 2, longitude: (shape.bbox[0] + shape.bbox[2]) / 2)
                return cityShape.contains(centre)
            }
            let covered = boundaries.reduce(0) { $0 + ($1.shape?.area ?? 0) }
            if cityShape.area > 0, covered / cityShape.area >= minBoundaryCoverage {
                return .boundaries(boundaries)
            }
        }

        let points = areas.filter { area in
            guard let centre = area.centre else { return false }
            return cityShape.contains(centre)
        }
        for kind in ["quarter", "suburb", "neighbourhood"] {
            let matching = points.filter { $0.placeKind == kind }
            if matching.count >= 3 { return .points(matching) }
        }
        return .none
    }
}

/// Looks up boundaries; a protocol so tests can stand in for the network.
protocol PlaceLookup: Sendable {
    /// All administrative boundaries containing the coordinate, without geometry.
    func adminAreas(containing coordinate: CLLocationCoordinate2D) async throws -> [AdminArea]
    /// The boundary with its geometry, plus every subdivision inside it.
    func areaWithSubdivisions(_ id: Int64) async throws -> [AdminArea]
}

struct OverpassError: Error, LocalizedError {
    var errorDescription: String?
}

/// Queries the public Overpass API. Only coordinates you have explored are sent, and only
/// when a drill-down needs a boundary that isn't cached yet.
struct OverpassClient: PlaceLookup {
    var endpoint = URL(string: "https://overpass-api.de/api/interpreter")!
    var session: URLSession = .shared

    func adminAreas(containing coordinate: CLLocationCoordinate2D) async throws -> [AdminArea] {
        let query = """
            [out:json][timeout:25];
            is_in(\(coordinate.latitude),\(coordinate.longitude))->.a;
            rel(pivot.a)[boundary=administrative][admin_level];
            out tags;
            """
        return try await run(query).areas
    }

    func areaWithSubdivisions(_ id: Int64) async throws -> [AdminArea] {
        let query = """
            [out:json][timeout:120];
            rel(\(id))->.city;
            .city out geom;
            .city map_to_area->.a;
            rel(area.a)[boundary=administrative][admin_level~"^(9|10|11)$"];
            out geom;
            node(area.a)[place~"^(quarter|suburb|neighbourhood)$"];
            out;
            """
        return try await run(query).areas
    }

    private func run(_ query: String) async throws -> OverpassResponse {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Walker iOS app (https://github.com/karlthice/walker)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        request.httpBody = Data("data=\(encoded)".utf8)
        request.timeoutInterval = 150

        // Overpass answers 429 (rate limit) or 504 (busy) under load; back off and retry.
        var delay: UInt64 = 2
        for attempt in 1...4 {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 {
                return try JSONDecoder().decode(OverpassResponse.self, from: data)
            }
            guard (status == 429 || status == 504), attempt < 4 else {
                throw OverpassError(errorDescription: "OpenStreetMap lookup failed (HTTP \(status)).")
            }
            try await Task.sleep(nanoseconds: delay * 1_000_000_000)
            delay *= 2
        }
        throw OverpassError(errorDescription: "OpenStreetMap is busy; try again later.")
    }
}

struct OverpassResponse: Decodable {
    struct Element: Decodable {
        var type: String
        var id: Int64
        var tags: [String: String]?
        var members: [Member]?
        var lat: Double?
        var lon: Double?
    }

    struct Member: Decodable {
        var type: String
        var role: String?
        var geometry: [Point?]?
    }

    struct Point: Decodable {
        var lat: Double
        var lon: Double
    }

    var elements: [Element]

    var areas: [AdminArea] {
        elements.compactMap { element in
            guard let tags = element.tags else { return nil }
            let name = tags["name"] ?? tags["name:en"] ?? "Unnamed"
            let englishName = tags["name:en"].flatMap { $0 == name ? nil : $0 }
            switch element.type {
            case "relation":
                guard let level = tags["admin_level"].flatMap(Int.init) else { return nil }
                return AdminArea(id: element.id, name: name, englishName: englishName, level: level, shape: element.members.flatMap(Self.shape))
            case "node":
                guard let lat = element.lat, let lon = element.lon, let kind = tags["place"] else { return nil }
                return AdminArea(id: -element.id, name: name, englishName: englishName, level: 0,
                                 centre: CLLocationCoordinate2D(latitude: lat, longitude: lon), placeKind: kind)
            default:
                return nil
            }
        }
    }

    private static func shape(from members: [Member]) -> PlaceShape? {
        func ways(role: String) -> [[CLLocationCoordinate2D]] {
            members
                // An empty role is treated as outer.
                .filter { $0.type == "way" && (($0.role ?? "").isEmpty ? "outer" : $0.role) == role }
                .compactMap { member in
                    member.geometry.map { points in
                        points.compactMap { $0.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) } }
                    }
                }
        }
        let outer = PlaceShape.assembleRings(ways(role: "outer"))
        guard !outer.isEmpty else { return nil }
        let inner = PlaceShape.assembleRings(ways(role: "inner"))
        let area = outer.reduce(0) { $0 + PolygonMath.ringArea($1) } - inner.reduce(0) { $0 + PolygonMath.ringArea($1) }
        return PlaceShape(rings: outer + inner, area: area)
    }
}
