import Foundation

/// Port of `sun.ts` from the geo-clock-card repo. Same USNO
/// low-precision formulas, same accuracy bounds (≤ 0.01° from
/// 1950–2050). The overlay layer needs to know the subsolar
/// longitude at the same moment the wallpaper renders so
/// markers project to the same screen positions as the SVG
/// underneath them — and the easiest way to guarantee that is
/// to compute the value Swift-side and feed it to both the
/// card (as an explicit `centerLongitude`) and the overlay.
///
/// Keep this in sync with sun.ts. If a future card release
/// changes the formula, the overlay will silently drift off
/// the wallpaper's centerLon. A regression test that imports
/// both sources of truth would catch it; for now we rely on
/// the formula being a closed-form astronomical reference.
enum Sun {

  /// Result of `subsolarPoint(at:)`.
  struct SubsolarPoint {
    /// Solar declination, degrees, positive north.
    let lat: Double
    /// Subsolar longitude, degrees, positive east,
    /// normalised to (-180, 180].
    let lon: Double
  }

  private static let DEG = Double.pi / 180
  private static let RAD = 180 / Double.pi
  private static let J2000_MS: TimeInterval =
    Date(timeIntervalSince1970: 946728000).timeIntervalSince1970 * 1000
    // = Date.UTC(2000, 0, 1, 12, 0, 0) — JS / Swift epoch differs
    // but the underlying instant is the same.

  /// Subsolar point (lat = solar declination, lon = subsolar
  /// longitude) for a given UTC moment. Matches `sun.ts`.
  static func subsolarPoint(at date: Date) -> SubsolarPoint {
    let n = (date.timeIntervalSince1970 * 1000 - J2000_MS) / 86_400_000

    let L = 280.460 + 0.9856474 * n
    let g = (357.528 + 0.9856003 * n) * DEG

    let lambda = (L + 1.915 * sin(g) + 0.020 * sin(2 * g)) * DEG
    let epsilon = (23.439 - 0.0000004 * n) * DEG

    let declination = asin(sin(epsilon) * sin(lambda)) * RAD

    let alpha = atan2(cos(epsilon) * sin(lambda), cos(lambda)) * RAD
    let eotDeg = wrap180(L - alpha)

    let cal = Calendar(identifier: .gregorian)
    var c = cal
    c.timeZone = TimeZone(identifier: "UTC")!
    let comps = c.dateComponents(
      [.hour, .minute, .second, .nanosecond],
      from: date)
    let utcHours =
      Double(comps.hour ?? 0)
      + Double(comps.minute ?? 0) / 60
      + Double(comps.second ?? 0) / 3600
      + Double(comps.nanosecond ?? 0) / 1_000_000_000 / 3600

    let lon = wrap180(-15 * (utcHours - 12) - eotDeg)
    return SubsolarPoint(lat: declination, lon: lon)
  }

  /// Solar altitude angle at (lat, lon) in degrees. Positive
  /// means the sun is above the geometric horizon (daylight);
  /// negative means below (night / twilight). Refraction is not
  /// modelled — the day/night flag we derive from this is for
  /// painting marker colours, not for sunrise/sunset times.
  static func altitude(
    lat: Double, lon: Double, at date: Date
  ) -> Double {
    let p = subsolarPoint(at: date)
    let latR = lat * DEG
    let declR = p.lat * DEG
    let dLonR = (lon - p.lon) * DEG
    let cosAngle =
      sin(latR) * sin(declR)
      + cos(latR) * cos(declR) * cos(dLonR)
    // `cosAngle` can drift outside [-1, 1] by 1 ulp from rounding;
    // clamp before acos to avoid producing NaN.
    let clamped = max(-1, min(1, cosAngle))
    return 90 - acos(clamped) * RAD
  }

  /// Convenience: is (lat, lon) lit by direct sunlight at `date`?
  /// True when the sun is geometrically above the horizon — matches
  /// the daylight side of the terminator the card draws.
  static func isDaylight(
    lat: Double, lon: Double, at date: Date
  ) -> Bool {
    altitude(lat: lat, lon: lon, at: date) > 0
  }

  /// Normalise an angle to (-180, 180].
  private static func wrap180(_ deg: Double) -> Double {
    let m = (deg + 180).truncatingRemainder(dividingBy: 360)
    return (m >= 0 ? m : m + 360) - 180
  }
}
