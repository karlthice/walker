import CoreLocation

/// Decides which raw Core Location fixes are good enough to store.
struct PointFilter {
    enum Verdict: Equatable {
        case accept
        /// Invalid, or worse than `maxAccuracy`. A coarse fix would clear fog where you never were.
        case inaccurate
        /// Not newer than the last accepted fix (duplicate or cached).
        case outOfOrder
        /// Within `minDistance` of the last accepted fix; adds nothing at a 150 m reveal radius.
        case tooClose
    }

    var maxAccuracy: CLLocationAccuracy = 100
    var minDistance: CLLocationDistance = 50
    private(set) var last: CLLocation?

    mutating func seed(with point: LocationPoint) {
        last = point.location
    }

    mutating func evaluate(_ location: CLLocation) -> Verdict {
        let accuracy = location.horizontalAccuracy
        guard accuracy >= 0, accuracy <= maxAccuracy else { return .inaccurate }
        if let last {
            guard location.timestamp > last.timestamp else { return .outOfOrder }
            guard location.distance(from: last) >= minDistance else { return .tooClose }
        }
        last = location
        return .accept
    }
}
