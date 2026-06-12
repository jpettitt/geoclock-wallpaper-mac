import CoreLocation
import Foundation

/// Wraps `CLGeocoder` with a serial queue. Apple's geocoder
/// only services one request at a time and will fail subsequent
/// concurrent calls; this resolver buffers requests and drains
/// them one-by-one on the main run loop.
///
/// Both directions are exposed:
///   - `forward(place:)` → place-name → (lat, lon, tzid, name)
///   - `reverse(lat:lon:)` → coordinate → tzid
///
/// Failures return `nil` rather than surfacing CLError. Callers
/// decide whether to retry or surface the error in the UI.
final class TimezoneResolver {

  static let shared = TimezoneResolver()

  /// Result of a forward (place → coordinate) lookup.
  struct ForwardResult {
    let latitude: Double
    let longitude: Double
    let tzid: String?
    /// Localized name of the resolved place (CLPlacemark.locality
    /// when set, else .name). Useful as the default marker label
    /// when the user hasn't typed one.
    let displayName: String?
  }

  private let geocoder = CLGeocoder()
  private var queue: [() -> Void] = []
  private var isBusy = false

  // MARK: – Public API

  /// Look up a place name. Completion runs on the main thread
  /// with the resolved coordinate + IANA tzid, or nil on failure
  /// (empty result set, network error, rate-limit).
  func forward(
    place: String,
    completion: @escaping (ForwardResult?) -> Void
  ) {
    enqueue { [weak self] done in
      guard let self = self else { done(); return }
      self.geocoder.geocodeAddressString(place) { placemarks, _ in
        let result = placemarks?.first.map { p -> ForwardResult in
          ForwardResult(
            latitude: p.location?.coordinate.latitude ?? 0,
            longitude: p.location?.coordinate.longitude ?? 0,
            tzid: p.timeZone?.identifier,
            displayName: p.locality ?? p.name
          )
        }
        // Filter results without a real location.
        let cleaned = (result?.latitude == 0 && result?.longitude == 0)
          ? nil : result
        completion(cleaned)
        done()
      }
    }
  }

  /// Reverse-geocode a coordinate. Completion runs on the main
  /// thread with the IANA tzid, or nil on failure.
  func reverse(
    lat: Double, lon: Double,
    completion: @escaping (String?) -> Void
  ) {
    enqueue { [weak self] done in
      guard let self = self else { done(); return }
      let location = CLLocation(latitude: lat, longitude: lon)
      self.geocoder.reverseGeocodeLocation(location) { placemarks, _ in
        completion(placemarks?.first?.timeZone?.identifier)
        done()
      }
    }
  }

  // MARK: – Internal

  /// Add a work item to the serial queue and drain. Work items
  /// receive a `done` callback they must invoke exactly once
  /// when CLGeocoder has finished — that releases the next item.
  /// A watchdog also calls done after `requestTimeout` so a
  /// CLGeocoder callback that never fires (observed with some
  /// network states) can't stall the whole queue forever — the
  /// done path is idempotent per request via the `completed`
  /// flag, so a late real callback is a harmless no-op.
  private let requestTimeout: TimeInterval = 15

  private func enqueue(_ work: @escaping (_ done: @escaping () -> Void) -> Void) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.queue.append { [weak self] in
        var completed = false
        let done = {
          guard !completed else { return }
          completed = true
          self?.finishCurrent()
        }
        DispatchQueue.main.asyncAfter(
          deadline: .now() + (self?.requestTimeout ?? 15)
        ) { done() }
        work(done)
      }
      self.drain()
    }
  }

  private func drain() {
    guard !isBusy, let next = queue.first else { return }
    queue.removeFirst()
    isBusy = true
    next()
  }

  private func finishCurrent() {
    DispatchQueue.main.async { [weak self] in
      self?.isBusy = false
      self?.drain()
    }
  }
}
