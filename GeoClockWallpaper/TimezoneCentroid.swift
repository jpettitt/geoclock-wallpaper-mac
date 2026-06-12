import Foundation

/// Look up a rough (lat, lon) centroid for an IANA time-zone
/// identifier. Used by the "Guess from time zone" centering
/// mode — when the user hasn't granted Core Location and hasn't
/// typed a manual lat/lon, we fall back to the city the tzid
/// names. Not geographically precise (the city's coordinates are
/// often offset from the zone's true centroid by hundreds of
/// kilometers), but more than precise enough for a map that's
/// 2048 px wide.
///
/// Coverage is the population-weighted hot set: Apple's stock
/// tzid options + a handful of others. Unknown tzids return
/// `nil` so callers can degrade to subsolar centering rather
/// than picking somewhere wrong-by-an-ocean.
enum TimezoneCentroid {

  /// Best-effort lookup. Strips region prefix where helpful
  /// (e.g. `Etc/UTC` → returns Greenwich).
  static func coordinate(forIANA tzid: String) -> (lat: Double, lon: Double)? {
    if let exact = table[tzid] { return exact }
    // `Etc/UTC`, `Etc/GMT*` and bare `UTC` all map to Greenwich.
    if tzid.hasPrefix("Etc/") || tzid == "UTC" {
      return (51.48, 0.0)
    }
    return nil
  }

  /// IANA tzid → (lat, lon) for the named city.
  private static let table: [String: (lat: Double, lon: Double)] = [
    // North America
    "America/Los_Angeles": (34.05, -118.24),
    "America/Vancouver":   (49.28, -123.12),
    "America/Tijuana":     (32.51, -117.04),
    "America/Phoenix":     (33.45, -112.07),
    "America/Denver":      (39.74, -104.99),
    "America/Edmonton":    (53.55, -113.49),
    "America/Boise":       (43.62, -116.20),
    "America/Mexico_City": (19.43,  -99.13),
    "America/Chicago":     (41.88,  -87.63),
    "America/Winnipeg":    (49.90,  -97.14),
    "America/Indiana/Indianapolis": (39.77, -86.16),
    "America/Detroit":     (42.33,  -83.05),
    "America/New_York":    (40.71,  -74.01),
    "America/Toronto":     (43.65,  -79.38),
    "America/Halifax":     (44.65,  -63.58),
    "America/St_Johns":    (47.56,  -52.71),
    "America/Anchorage":   (61.22, -149.90),
    "America/Juneau":      (58.30, -134.42),
    "America/Adak":        (51.88, -176.66),
    "Pacific/Honolulu":    (21.31, -157.86),

    // South America
    "America/Sao_Paulo":   (-23.55, -46.63),
    "America/Argentina/Buenos_Aires": (-34.61, -58.38),
    "America/Santiago":    (-33.45, -70.67),
    "America/Bogota":      (4.71,   -74.07),
    "America/Lima":        (-12.05, -77.04),
    "America/Caracas":     (10.49,  -66.88),

    // Europe
    "Europe/London":       (51.51,  -0.13),
    "Europe/Dublin":       (53.35,  -6.26),
    "Europe/Lisbon":       (38.72,  -9.14),
    "Atlantic/Reykjavik":  (64.15, -21.95),
    "Europe/Paris":        (48.86,   2.35),
    "Europe/Madrid":       (40.42,  -3.70),
    "Europe/Amsterdam":    (52.37,   4.90),
    "Europe/Brussels":     (50.85,   4.35),
    "Europe/Zurich":       (47.38,   8.54),
    "Europe/Rome":         (41.90,  12.50),
    "Europe/Berlin":       (52.52,  13.40),
    "Europe/Vienna":       (48.21,  16.37),
    "Europe/Prague":       (50.08,  14.43),
    "Europe/Warsaw":       (52.23,  21.01),
    "Europe/Stockholm":    (59.33,  18.07),
    "Europe/Oslo":         (59.91,  10.75),
    "Europe/Copenhagen":   (55.68,  12.57),
    "Europe/Helsinki":     (60.17,  24.94),
    "Europe/Athens":       (37.98,  23.73),
    "Europe/Istanbul":     (41.01,  28.98),
    "Europe/Bucharest":    (44.43,  26.10),
    "Europe/Kyiv":         (50.45,  30.52),
    "Europe/Moscow":       (55.75,  37.62),
    "Atlantic/Canary":     (28.13, -15.43),
    "Atlantic/Azores":     (37.74, -25.67),

    // Africa
    "Africa/Cairo":        (30.04,  31.24),
    "Africa/Johannesburg": (-26.20,  28.05),
    "Africa/Lagos":        (6.45,    3.39),
    "Africa/Nairobi":      (-1.29,  36.82),
    "Africa/Casablanca":   (33.57,  -7.59),
    "Africa/Addis_Ababa":  (9.03,   38.74),

    // Middle East
    "Asia/Jerusalem":      (31.78,  35.22),
    "Asia/Tel_Aviv":       (32.08,  34.78),
    "Asia/Riyadh":         (24.71,  46.68),
    "Asia/Dubai":          (25.20,  55.27),
    "Asia/Tehran":         (35.69,  51.39),

    // Asia
    "Asia/Karachi":        (24.86,  67.01),
    "Asia/Kolkata":        (22.57,  88.36),
    "Asia/Calcutta":       (22.57,  88.36),   // alias
    "Asia/Dhaka":          (23.81,  90.41),
    "Asia/Bangkok":        (13.76, 100.50),
    "Asia/Ho_Chi_Minh":    (10.82, 106.63),
    "Asia/Singapore":      (1.35,  103.82),
    "Asia/Kuala_Lumpur":   (3.14,  101.69),
    "Asia/Manila":         (14.60, 120.98),
    "Asia/Jakarta":        (-6.21, 106.85),
    "Asia/Shanghai":       (31.23, 121.47),
    "Asia/Hong_Kong":      (22.32, 114.17),
    "Asia/Taipei":         (25.03, 121.57),
    "Asia/Seoul":          (37.57, 126.98),
    "Asia/Tokyo":          (35.68, 139.69),

    // Oceania
    "Australia/Perth":     (-31.95, 115.86),
    "Australia/Adelaide":  (-34.93, 138.60),
    "Australia/Darwin":    (-12.46, 130.84),
    "Australia/Brisbane":  (-27.47, 153.03),
    "Australia/Sydney":    (-33.87, 151.21),
    "Australia/Melbourne": (-37.81, 144.96),
    "Australia/Hobart":    (-42.88, 147.33),
    "Pacific/Auckland":    (-36.85, 174.76),
    "Pacific/Fiji":        (-18.14, 178.44),
    "Pacific/Guam":        (13.44, 144.79),
  ]
}
