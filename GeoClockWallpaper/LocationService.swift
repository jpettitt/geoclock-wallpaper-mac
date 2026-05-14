import Combine
import CoreLocation
import Foundation

/// Thin wrapper around `CLLocationManager` that surfaces just
/// the bits the wallpaper renderer cares about:
///
///   - "what's the current (lat, lon)?" → `coordinate`
///   - "did the user grant permission?" → `status`
///
/// Both are `@Published` so SwiftUI / Combine subscribers
/// recompute when either changes. The renderer subscribes to
/// `coordinate` to re-render the wallpaper when a new fix
/// arrives (e.g. when the user moves their MacBook).
///
/// Caching: the latest fix is persisted to UserDefaults so the
/// first launch render after wake doesn't have to wait for a
/// fresh location lookup. We ask CL for a fresh fix in the
/// background; subscribers see the cached value first, then the
/// update when CL replies.
final class LocationService: NSObject, ObservableObject {

  static let shared = LocationService()

  // MARK: – Published state

  /// Current best-known location, or nil if we've never had one
  /// AND we haven't loaded a cached value from prior runs.
  @Published private(set) var coordinate: CLLocationCoordinate2D?

  /// Current authorization status. SwiftUI subscribes to this
  /// to show "Allow…" / "Denied — open Settings" hints.
  @Published private(set) var status: CLAuthorizationStatus

  // MARK: – Internals

  private let manager = CLLocationManager()
  private let defaults = UserDefaults.standard
  private let cacheKey = "locationService.lastFix.v1"

  private override init() {
    self.status = manager.authorizationStatus
    super.init()
    manager.delegate = self
    // Kilometer accuracy is plenty for a planet-scale map.
    // Avoids waking the GPS chip and saves a meaningful amount
    // of battery on laptops.
    manager.desiredAccuracy = kCLLocationAccuracyKilometer
    loadCachedFix()
    // If the user already granted permission in a prior run,
    // kick off a refresh so subscribers see a fresh value soon
    // after launch.
    if status == .authorized || status == .authorizedAlways {
      requestRefresh()
    }
  }

  // MARK: – Public API

  /// Ask the OS to show the permission prompt if it hasn't yet.
  /// No-op if the user has already responded (granted or denied).
  /// Safe to call multiple times.
  func requestAccessIfNeeded() {
    if status == .notDetermined {
      manager.requestWhenInUseAuthorization()
    }
  }

  /// Trigger a one-shot location lookup. Used at launch (if
  /// permission was previously granted) and when the wallpaper
  /// renderer is about to draw with `centerMode == .myLocation`
  /// but the cached fix is stale or absent.
  ///
  /// If permission isn't granted this no-ops; coordinate stays
  /// nil and the renderer falls back to the time-zone centroid.
  func requestRefresh() {
    guard status == .authorized || status == .authorizedAlways
    else { return }
    manager.requestLocation()
  }

  /// Human-readable text the Settings UI shows under the
  /// "My location" option so the user understands which state
  /// they're in (no Core Location permission, granted but
  /// fetching, granted and current, etc.).
  func statusDescription() -> String {
    switch status {
    case .notDetermined:
      return "Permission not yet requested. Selecting this option will prompt."
    case .denied:
      return "Permission denied. Enable Location Services for this app in System Settings → Privacy & Security, then re-select this option. Falling back to time-zone centroid until granted."
    case .restricted:
      return "Location access is restricted on this Mac (parental controls or MDM). Falling back to time-zone centroid."
    case .authorized, .authorizedAlways:
      if let c = coordinate {
        return String(format: "Using current location (%.2f, %.2f).",
                      c.latitude, c.longitude)
      }
      return "Permission granted; fetching first location…"
    @unknown default:
      return "Unknown authorization state."
    }
  }

  // MARK: – Persistence

  private func loadCachedFix() {
    guard
      let dict = defaults.dictionary(forKey: cacheKey),
      let lat = dict["lat"] as? Double,
      let lon = dict["lon"] as? Double
    else { return }
    coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
  }

  private func saveCachedFix(_ c: CLLocationCoordinate2D) {
    defaults.set([
      "lat": c.latitude,
      "lon": c.longitude,
      "ts": Date().timeIntervalSince1970,
    ], forKey: cacheKey)
  }

  /// Wipe the in-memory + on-disk last-known coordinate. Used
  /// by `ConfigStore.resetToDefaults` so a "Reset" actually
  /// clears the home dot's position too — the cached fix
  /// otherwise survives every config reset and the home marker
  /// keeps drawing at the location the user might be trying
  /// to forget. CoreLocation will refresh the coordinate the
  /// next time it has authorization; until then `coordinate`
  /// is nil and overlay views fall back to the TZ-centroid or
  /// hide the home marker entirely.
  func clearCachedFix() {
    coordinate = nil
    defaults.removeObject(forKey: cacheKey)
  }
}

// MARK: – CLLocationManagerDelegate

extension LocationService: CLLocationManagerDelegate {

  func locationManagerDidChangeAuthorization(
    _ manager: CLLocationManager
  ) {
    let new = manager.authorizationStatus
    status = new
    Diagnostics.log("location authorization → \(new.rawValue)")
    if new == .authorized || new == .authorizedAlways {
      manager.requestLocation()
    }
  }

  func locationManager(
    _ manager: CLLocationManager,
    didUpdateLocations locations: [CLLocation]
  ) {
    guard let latest = locations.last else { return }
    coordinate = latest.coordinate
    saveCachedFix(latest.coordinate)
    Diagnostics.log(String(format:
      "location updated to (%.4f, %.4f)",
      latest.coordinate.latitude, latest.coordinate.longitude))
  }

  func locationManager(
    _ manager: CLLocationManager,
    didFailWithError error: Error
  ) {
    Diagnostics.log("location lookup failed: \(error)")
    // Keep whatever cached value we have. Renderer falls back
    // to the time-zone centroid if coordinate is still nil.
  }
}
