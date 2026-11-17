import CoreLocation
import Observation
import Photos
import UIKit

/// A photo from the library that has a location, shown as a pin on the map.
struct PhotoPin: Identifiable, Hashable, Sendable {
    /// The asset's local identifier.
    var id: String
    var latitude: CLLocationDegrees
    var longitude: CLLocationDegrees
    var date: Date?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// The user's photos that have a location. Everything is read on the phone; nothing is uploaded.
///
/// Nothing here touches the photo library until photos are turned on in the map, so a launch
/// (including a background relaunch for location, or a test run) never asks for access.
@MainActor
@Observable
final class PhotoLibrary: NSObject {
    static let shared = PhotoLibrary()

    private(set) var access: PHAuthorizationStatus = .notDetermined
    private(set) var pins: [PhotoPin] = []
    /// Bumped whenever `pins` is replaced, so the map syncs its pins only when they changed.
    private(set) var version = 0

    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var observing = false
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?

    var canRead: Bool { access == .authorized || access == .limited }

    /// Reads the current access without asking for it.
    func refreshAccess() {
        access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    /// Shows the system prompt if access hasn't been decided yet, then loads.
    func requestAccess() async {
        access = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        if canRead { load() }
    }

    /// Loads the pins once, if access was already granted; later changes arrive from the library.
    func loadIfNeeded() {
        guard !loaded else { return }
        load()
    }

    func load() {
        refreshAccess()
        #if DEBUG
        if let count = Self.demoPinCount {
            loaded = true
            replacePins(Self.demoPins(count: count))
            return
        }
        #endif
        guard canRead else {
            if !pins.isEmpty { replacePins([]) }
            return
        }
        loaded = true
        if !observing {
            PHPhotoLibrary.shared().register(self)
            observing = true
        }
        loadTask?.cancel()
        loadTask = Task {
            let pins = await Task.detached(priority: .utility) { Self.fetchPins() }.value
            guard !Task.isCancelled else { return }
            replacePins(pins)
        }
    }

    private func replacePins(_ new: [PhotoPin]) {
        pins = new
        version += 1
    }

    /// Photos (not videos or screenshots) with a usable location.
    nonisolated static func fetchPins() -> [PhotoPin] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        let assets = PHAsset.fetchAssets(with: options)
        var pins: [PhotoPin] = []
        pins.reserveCapacity(assets.count)
        assets.enumerateObjects { asset, _, _ in
            guard !asset.mediaSubtypes.contains(.photoScreenshot),
                  let coordinate = asset.location?.coordinate,
                  isUsable(coordinate)
            else { return }
            pins.append(PhotoPin(id: asset.localIdentifier, latitude: coordinate.latitude,
                                 longitude: coordinate.longitude, date: asset.creationDate))
        }
        return pins
    }

    /// Rejects invalid coordinates and 0,0, which some apps write for "no location".
    nonisolated static func isUsable(_ coordinate: CLLocationCoordinate2D) -> Bool {
        CLLocationCoordinate2DIsValid(coordinate) && !(coordinate.latitude == 0 && coordinate.longitude == 0)
    }

    /// Coalesces bursts of library changes (an import, iCloud syncing) into one reload.
    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            load()
        }
    }

    #if DEBUG
    /// `-photoPinsDemo 20000` fills the map with synthetic pins around Reykjavík, to check that
    /// panning stays smooth with a large library; a tenth sit at one spot, like photos taken at
    /// home. Their thumbnails stay empty.
    private static var demoPinCount: Int? {
        let count = UserDefaults.standard.integer(forKey: "photoPinsDemo")
        return count > 0 ? count : nil
    }

    private static func demoPins(count: Int) -> [PhotoPin] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { index in
            if index < count / 10 {
                return PhotoPin(id: "demo-\(index)", latitude: 64.1440, longitude: -21.9400,
                                date: Date(timeIntervalSinceNow: -Double(index) * 3600))
            }
            return PhotoPin(id: "demo-\(index)",
                     latitude: 64.14 + Double.random(in: -0.05...0.05, using: &generator),
                     longitude: -21.92 + Double.random(in: -0.12...0.12, using: &generator),
                     date: Date(timeIntervalSinceNow: -Double(index) * 3600))
        }
    }
    #endif
}

extension PhotoLibrary: PHPhotoLibraryChangeObserver {
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in self.scheduleReload() }
    }
}

/// Loads photo images for pins and the viewer.
@MainActor
enum PhotoImages {
    private static let manager = PHCachingImageManager()

    /// Calls `handler` on the main actor, possibly twice: a quick low-quality image first, then
    /// the final one. Returns nil if the asset is gone; pass the result to `cancel`.
    @discardableResult
    static func request(_ id: String, pixelSize: CGSize, handler: @escaping @MainActor (UIImage?, _ isFinal: Bool) -> Void) -> PHImageRequestID? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            handler(nil, true)
            return nil
        }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        // Photos kept only in iCloud are downloaded when shown.
        options.isNetworkAccessAllowed = true
        return manager.requestImage(for: asset, targetSize: pixelSize, contentMode: .aspectFill, options: options) { image, info in
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            let isFinal = !degraded || info?[PHImageErrorKey] != nil || (info?[PHImageCancelledKey] as? Bool) == true
            if Thread.isMainThread {
                MainActor.assumeIsolated { handler(image, isFinal) }
            } else {
                DispatchQueue.main.async { handler(image, isFinal) }
            }
        }
    }

    static func cancel(_ request: PHImageRequestID?) {
        if let request { manager.cancelImageRequest(request) }
    }
}
