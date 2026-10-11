import CoreLocation
import MapKit
import UIKit

/// A soft cone fanning out from the user's location dot in the direction the phone is facing,
/// like Apple Maps. Wider when the compass is less certain.
final class HeadingBeamView: UIView {
    private static let length: CGFloat = 70
    private let gradient = CAGradientLayer()
    private let cone = CAShapeLayer()

    /// Half the cone's opening angle, in degrees.
    var spread: CLLocationDegrees = 25 {
        didSet { if spread != oldValue { setNeedsLayout() } }
    }

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: Self.length * 2, height: Self.length * 2))
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        gradient.type = .radial
        gradient.colors = [UIColor.systemBlue.withAlphaComponent(0.6).cgColor, UIColor.systemBlue.withAlphaComponent(0).cgColor]
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        gradient.mask = cone
        layer.addSublayer(gradient)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = bounds
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        let half = spread * .pi / 180
        // Pointing up (north before rotation); UIKit angles run clockwise from the x-axis.
        let path = UIBezierPath()
        path.move(to: centre)
        path.addArc(withCenter: centre, radius: Self.length, startAngle: -.pi / 2 - half, endAngle: -.pi / 2 + half, clockwise: true)
        path.close()
        cone.path = path.cgPath
    }

    /// Points the beam at `heading` (degrees from true north) on a map rotated by `mapHeading`.
    func point(at heading: CLLocationDirection, mapHeading: CLLocationDirection) {
        transform = CGAffineTransform(rotationAngle: (heading - mapHeading) * .pi / 180)
    }
}

/// Feeds compass headings to a beam under the map's user location view, only while the map
/// is on screen and the app is in the foreground.
final class HeadingBeamController: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let beam = HeadingBeamView()
    private weak var map: MKMapView?
    private var heading: CLLocationDirection?
    private var observers: [NSObjectProtocol] = []

    init(map: MKMapView) {
        self.map = map
        super.init()
        manager.delegate = self
        manager.headingFilter = 2
        beam.isHidden = true
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                self?.manager.stopUpdatingHeading()
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                self?.start()
            },
        ]
        start()
    }

    deinit {
        manager.stopUpdatingHeading()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    private func start() {
        guard CLLocationManager.headingAvailable() else { return }
        manager.startUpdatingHeading()
    }

    /// Re-attaches the beam if MapKit replaced the user location view, and re-aims it after
    /// the map rotates.
    func update() {
        guard let map, let dot = map.view(for: map.userLocation) else { return }
        if beam.superview !== dot {
            dot.insertSubview(beam, at: 0)
        }
        beam.center = CGPoint(x: dot.bounds.midX, y: dot.bounds.midY)
        if let heading {
            beam.point(at: heading, mapHeading: map.camera.heading)
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        // A negative accuracy means the reading is invalid (e.g. interference).
        guard newHeading.headingAccuracy >= 0 else {
            beam.isHidden = true
            return
        }
        heading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        beam.spread = min(max(newHeading.headingAccuracy, 20), 60)
        beam.isHidden = false
        update()
    }
}
