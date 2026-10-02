import CoreLocation
import Observation
import UIKit

/// Keeps location tracking alive in the background without the app being opened.
///
/// - Moving: standard updates at ~100 m accuracy, one every ~75 m.
/// - Paused by iOS (stationary): a 150 m geofence around the last position; exiting it restarts updates.
/// - Backups: significant location changes and visit departures also restart updates, and
///   relaunch the app if iOS terminated it.
@MainActor
@Observable
final class LocationService: NSObject {
    static let shared = LocationService(store: .shared)

    enum TrackingState: String {
        case off = "Off"
        case moving = "Tracking"
        case paused = "Paused (geofence armed)"
    }

    private static let geofenceRadius: CLLocationDistance = 150
    private static let geofenceID = "resume"
    private static let enabledKey = "trackingEnabled"
    private static let askedForAlwaysKey = "askedForAlways"

    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    private(set) var preciseLocation = true
    private(set) var state: TrackingState = .off
    private(set) var lastAccepted: LocationPoint?
    private(set) var acceptedThisSession = 0
    private(set) var rejectedThisSession = 0
    /// Bumped on every store write so views know to reload.
    private(set) var revision = 0

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled { start(reason: "enabled") } else { stop() }
        }
    }

    var isAuthorized: Bool {
        authorization == .authorizedAlways || authorization == .authorizedWhenInUse
    }

    @ObservationIgnored let store: PointStore
    @ObservationIgnored private let revealer: Revealer
    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var filter = PointFilter()
    @ObservationIgnored private var monitor: Task<CLMonitor, Never>?
    @ObservationIgnored private var bootstrapped = false

    init(store: PointStore) {
        self.store = store
        self.revealer = Revealer(store: store)
        self.isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        super.init()
    }

    func bootstrap() {
        guard !bootstrapped else { return }
        bootstrapped = true

        if let last = store.lastPoint() {
            filter.seed(with: last)
            lastAccepted = last
        }
        revealFog(rebuildIfNeeded: true)

        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 75
        manager.activityType = .other
        manager.pausesLocationUpdatesAutomatically = true
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = false
        authorization = manager.authorizationStatus
        preciseLocation = manager.accuracyAuthorization == .fullAccuracy
        manager.delegate = self

        // The monitor must be re-created on every launch so a geofence exit that
        // relaunched the app is delivered.
        startMonitorEvents()

        NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.store.flushPending()
                self.revealFog()
                self.revision += 1
            }
        }

        start(reason: "launch")

        // First launch: ask right away rather than waiting for a tap on the Status tab.
        if authorization == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    func requestPermission() {
        switch authorization {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            // iOS shows the "Change to Always Allow" prompt only once.
            manager.requestAlwaysAuthorization()
        default:
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        }
    }

    func log(_ kind: LogKind, _ message: String) {
        store.log(kind, message)
        revision += 1
    }

    // MARK: - Tracking

    private func start(reason: String) {
        guard isEnabled, isAuthorized else {
            state = .off
            return
        }
        manager.startUpdatingLocation()
        manager.startMonitoringSignificantLocationChanges()
        manager.startMonitoringVisits()
        disarmGeofence()
        if state != .moving {
            log(.resume, "Updates started (\(reason))")
        }
        state = .moving
    }

    private func stop() {
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        manager.stopMonitoringVisits()
        disarmGeofence()
        state = .off
        log(.info, "Tracking turned off")
    }

    private func handle(_ locations: [CLLocation]) {
        // While paused, only significant-change fixes arrive here.
        if state == .paused {
            start(reason: "significant change")
        }
        var accepted = false
        for location in locations {
            if filter.evaluate(location) == .accept {
                let point = LocationPoint(location)
                store.insert(point)
                lastAccepted = point
                acceptedThisSession += 1
                accepted = true
            } else {
                rejectedThisSession += 1
            }
        }
        if accepted {
            revealFog()
        }
        revision += 1
    }

    private func revealFog(rebuildIfNeeded: Bool = false) {
        do {
            if rebuildIfNeeded, try revealer.needsRebuild() {
                let start = Date()
                let count = try revealer.rebuild()
                log(.info, String(format: "Rebuilt fog from %d points in %.1f s", count, Date().timeIntervalSince(start)))
            }
            try revealer.catchUp()
        } catch {
            // Database still locked (before first unlock); the next catch-up applies these points.
        }
    }

    // MARK: - Resume geofence

    private func startMonitorEvents() {
        let monitorTask = Task { await CLMonitor("WalkerResumeMonitor") }
        monitor = monitorTask
        Task {
            let monitor = await monitorTask.value
            do {
                for try await event in await monitor.events {
                    handle(event)
                }
            } catch {
                log(.error, "Geofence monitor stopped: \(error.localizedDescription)")
            }
        }
    }

    private func handle(_ event: CLMonitor.Event) {
        guard event.identifier == Self.geofenceID, event.state == .unsatisfied else { return }
        log(.geofence, "Left the resume geofence")
        start(reason: "geofence exit")
    }

    private func armGeofence(at coordinate: CLLocationCoordinate2D) {
        guard let monitor else { return }
        Task {
            let condition = CLMonitor.CircularGeographicCondition(center: coordinate, radius: Self.geofenceRadius)
            await monitor.value.add(condition, identifier: Self.geofenceID, assuming: .satisfied)
        }
        log(.pause, String(format: "Paused; geofence armed at %.5f, %.5f", coordinate.latitude, coordinate.longitude))
    }

    private func disarmGeofence() {
        guard let monitor else { return }
        Task { await monitor.value.remove(Self.geofenceID) }
    }
}

// MARK: - CLLocationManagerDelegate

// The manager is created on the main thread, so its callbacks arrive there.
extension LocationService: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            let previous = authorization
            authorization = self.manager.authorizationStatus
            preciseLocation = self.manager.accuracyAuthorization == .fullAccuracy
            // Follow "While Using" straight away with the "Always" prompt, once; iOS only shows it once anyway.
            if previous == .notDetermined, authorization == .authorizedWhenInUse,
               !UserDefaults.standard.bool(forKey: Self.askedForAlwaysKey) {
                UserDefaults.standard.set(true, forKey: Self.askedForAlwaysKey)
                self.manager.requestAlwaysAuthorization()
            }
            if previous != authorization {
                log(.auth, "Authorization: \(authorization.label)")
            }
            if isAuthorized {
                start(reason: "authorized")
            } else {
                state = .off
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            handle(locations)
        }
    }

    nonisolated func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            state = .paused
            if let coordinate = self.manager.location?.coordinate ?? lastAccepted?.coordinate {
                armGeofence(at: coordinate)
            } else {
                log(.pause, "Paused with no known location; waiting for a significant change")
            }
        }
    }

    nonisolated func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            start(reason: "resumed by iOS")
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        MainActor.assumeIsolated {
            let departed = visit.departureDate != .distantFuture
            log(.visit, departed ? "Visit departure" : "Visit arrival")
            if departed && state == .paused {
                start(reason: "visit departure")
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            if (error as? CLError)?.code == .locationUnknown { return }
            log(.error, "Location error: \(error.localizedDescription)")
        }
    }
}

extension CLAuthorizationStatus {
    var label: String {
        switch self {
        case .notDetermined: "Not requested"
        case .restricted: "Restricted"
        case .denied: "Denied"
        case .authorizedAlways: "Always"
        case .authorizedWhenInUse: "While Using"
        @unknown default: "Unknown"
        }
    }
}
