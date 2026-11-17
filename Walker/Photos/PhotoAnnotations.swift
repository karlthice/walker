import MapKit
import Photos
import UIKit

/// Photos grouped into one pin: a single photo, or a stack of nearby ones.
final class PhotoGroupAnnotation: NSObject, MKAnnotation {
    /// Zoom level and grid cell, so an unchanged group keeps its view while the map pans.
    let key: String
    /// Newest first.
    let pins: [PhotoPin]
    let coordinate: CLLocationCoordinate2D

    init(key: String, pins: [PhotoPin], coordinate: CLLocationCoordinate2D) {
        self.key = key
        self.pins = pins
        self.coordinate = coordinate
    }
}

/// Groups photos into a grid of cells about a pin wide on screen, so the map only ever holds a
/// few hundred pins. MapKit's own clustering needs a view per photo first, which stalls the
/// map for a library of tens of thousands of photos.
enum PhotoGrouping {
    /// Pin spacing on screen, in points.
    static let cellPoints: Double = 80

    struct Group: Equatable {
        var key: String
        /// Indices into the pins, newest first.
        var members: [Int]
        var coordinate: CLLocationCoordinate2D

        static func == (a: Group, b: Group) -> Bool {
            a.key == b.key && a.members == b.members
        }
    }

    /// Cell size in map points, snapped to a power of two so cells stay put while panning
    /// and only change when the zoom level does.
    static func cellSize(visibleWidth: Double, viewWidth: Double) -> Double {
        let raw = visibleWidth / max(viewWidth, 1) * cellPoints
        return pow(2, (log2(max(raw, 1))).rounded())
    }

    /// Pins closer than this on screen, in points, are merged so they never overlap.
    static let minSpacingPoints: Double = 56

    /// Groups the pins inside `rect`; `points` are the pins' map points, in the same order.
    /// Grid cells whose pins end up closer than `minSpacing` (map points), e.g. photos either
    /// side of a cell edge, are merged into the larger group.
    static func groups(pins: [PhotoPin], points: [MKMapPoint], in rect: MKMapRect, cellSize: Double,
                       minSpacing: Double) -> [Group] {
        let level = Int(log2(cellSize).rounded())
        var cells: [Int64: [Int]] = [:]
        for (index, point) in points.enumerated() where rect.contains(point) {
            let x = Int64((point.x / cellSize).rounded(.down)), y = Int64((point.y / cellSize).rounded(.down))
            cells[x << 32 | (y & 0xFFFF_FFFF), default: []].append(index)
        }

        struct Pending {
            var key: String
            var members: [Int]
            var centre: MKMapPoint
        }
        func centre(_ members: [Int]) -> MKMapPoint {
            // The mean position, so a stack sits among its photos.
            MKMapPoint(x: members.reduce(0) { $0 + points[$1].x } / Double(members.count),
                       y: members.reduce(0) { $0 + points[$1].y } / Double(members.count))
        }
        // Largest first, so small groups fold into big ones; keys break ties for a stable result.
        let candidates = cells.map { cell, members in Pending(key: "\(level):\(cell)", members: members, centre: centre(members)) }
            .sorted { $0.members.count != $1.members.count ? $0.members.count > $1.members.count : $0.key < $1.key }
        var kept: [Pending] = []
        for candidate in candidates {
            if let index = kept.firstIndex(where: {
                abs($0.centre.x - candidate.centre.x) < minSpacing && abs($0.centre.y - candidate.centre.y) < minSpacing
            }) {
                kept[index].members += candidate.members
            } else {
                kept.append(candidate)
            }
        }
        return kept.map { group in
            let sorted = group.members.sorted { (pins[$0].date ?? .distantPast) > (pins[$1].date ?? .distantPast) }
            return Group(key: group.key, members: sorted, coordinate: centre(sorted).coordinate)
        }
    }
}

/// A rounded thumbnail of the newest photo in a white frame; a stack with a count badge when
/// the pin holds several photos.
final class PhotoGroupView: MKAnnotationView {
    static let reuseID = "photoGroup"
    static let side: CGFloat = 44
    private static let border: CGFloat = 2.5

    private let imageView = UIImageView()
    private let badge = UILabel()
    private let backCards: [UIView] = [UIView(), UIView()]
    private var request: PHImageRequestIDBox?
    private var shownID: String?

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: Self.side, height: Self.side)
        // Below the location dot, which is usually where photos are taken. Pins stay out of
        // MapKit's collision handling, which could hide the dot; the grid keeps them apart.
        zPriority = .min
        collisionMode = .none

        for (index, card) in backCards.enumerated() {
            let offset = CGFloat(index + 1) * 3
            card.frame = bounds.offsetBy(dx: offset, dy: -offset)
            card.backgroundColor = UIColor(white: 0.92 - CGFloat(index) * 0.08, alpha: 1)
            card.layer.cornerRadius = 10
            card.layer.borderColor = UIColor.black.withAlphaComponent(0.15).cgColor
            card.layer.borderWidth = 0.5
            insertSubview(card, at: 0)
        }

        let card = UIView(frame: bounds)
        card.backgroundColor = .white
        card.layer.cornerRadius = 10
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.35
        card.layer.shadowRadius = 3
        card.layer.shadowOffset = CGSize(width: 0, height: 1)
        addSubview(card)

        imageView.frame = bounds.insetBy(dx: Self.border, dy: Self.border)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 10 - Self.border
        imageView.backgroundColor = .systemGray4
        card.addSubview(imageView)

        badge.font = .systemFont(ofSize: 12, weight: .bold)
        badge.textColor = .white
        badge.backgroundColor = .systemOrange
        badge.textAlignment = .center
        badge.layer.cornerRadius = 10
        badge.layer.masksToBounds = true
        addSubview(badge)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var annotation: MKAnnotation? {
        didSet {
            guard let group = annotation as? PhotoGroupAnnotation, let newest = group.pins.first else { return }
            let count = group.pins.count
            for card in backCards { card.isHidden = count == 1 }
            badge.isHidden = count == 1
            badge.text = count < 1000 ? "\(count)" : "\(count / 1000)k"
            let width = max(20, badge.intrinsicContentSize.width + 10)
            badge.frame = CGRect(x: bounds.maxX - width / 2 - 2, y: -8, width: width, height: 20)
            accessibilityLabel = count == 1 ? "Photo" : "\(count) photos"
            showPhoto(id: newest.id)
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        PhotoImages.cancel(request?.id)
        request = nil
        shownID = nil
        imageView.image = nil
    }

    /// The image arrives asynchronously, maybe after this view was reused for another photo,
    /// so results for any other photo are dropped.
    private func showPhoto(id: String) {
        guard id != shownID else { return }
        PhotoImages.cancel(request?.id)
        shownID = id
        imageView.image = nil
        let pixels = Self.side * traitCollection.displayScale
        let box = PHImageRequestIDBox()
        request = box
        box.id = PhotoImages.request(id, pixelSize: CGSize(width: pixels, height: pixels)) { [weak self] image, _ in
            guard let self, self.shownID == id, let image else { return }
            self.imageView.image = image
        }
    }
}

/// Holds a request id that is only known after the request call returns.
final class PHImageRequestIDBox {
    var id: PHImageRequestID?
}
