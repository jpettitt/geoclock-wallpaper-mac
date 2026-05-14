import Foundation

/// Per-display configuration overrides. Every field except
/// `markers` is `Optional`: nil means "inherit from the global
/// `WallpaperConfig` at render time". `markers` is intentionally
/// not optional — each enabled display owns its own marker list
/// independently of the global one (the user's request: "user
/// may only want the markers on some screens").
///
/// Keyed in `WallpaperConfig.perDisplaySettings` by display
/// UUID so the entry survives reboots and replugs (see
/// `DisplayIdentity.uuidString(forID:)`).
struct PerDisplaySettings: Codable, Equatable {

  // MARK: – Map

  var centerMode: CenterMode? = nil
  var manualLatitude: Double? = nil
  var manualLongitude: Double? = nil
  var aspectFit: AspectFit? = nil

  /// Show the 24-hour band along the top of the map?
  var showTimezoneBand: Bool? = nil

  /// Draw the IANA timezone polygon outlines on top of the
  /// rendered map?
  var showTimezoneBoundaries: Bool? = nil

  // MARK: – Clock

  var clockPosition: ClockPosition? = nil
  var clockSource: ClockSource? = nil
  var manualTimezone: String? = nil
  var showUTC: Bool? = nil

  // MARK: – Home marker

  var showHomeMarker: Bool? = nil
  var homeLabel: String? = nil

  // MARK: – Markers

  /// This display's marker list. Always present (no `?`) — when
  /// per-display mode is enabled and a display has an entry,
  /// this array replaces the global `markers` for that display.
  /// Initially seeded with a copy of the global list the first
  /// time the user enables per-display settings.
  var markers: [Marker] = []

  // MARK: – Codable

  enum CodingKeys: String, CodingKey {
    case centerMode, manualLatitude, manualLongitude, aspectFit
    case showTimezoneBand, showTimezoneBoundaries
    case clockPosition, clockSource, manualTimezone, showUTC
    case showHomeMarker, homeLabel
    case markers
  }

  init() {}

  /// Decode with every key optional so adding fields later
  /// doesn't break saved configs.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.centerMode = try c.decodeIfPresent(CenterMode.self, forKey: .centerMode)
    self.manualLatitude = try c.decodeIfPresent(Double.self, forKey: .manualLatitude)
    self.manualLongitude = try c.decodeIfPresent(Double.self, forKey: .manualLongitude)
    self.aspectFit = try c.decodeIfPresent(AspectFit.self, forKey: .aspectFit)
    self.showTimezoneBand = try c.decodeIfPresent(Bool.self, forKey: .showTimezoneBand)
    self.showTimezoneBoundaries = try c.decodeIfPresent(Bool.self, forKey: .showTimezoneBoundaries)
    self.clockPosition = try c.decodeIfPresent(ClockPosition.self, forKey: .clockPosition)
    self.clockSource = try c.decodeIfPresent(ClockSource.self, forKey: .clockSource)
    self.manualTimezone = try c.decodeIfPresent(String.self, forKey: .manualTimezone)
    self.showUTC = try c.decodeIfPresent(Bool.self, forKey: .showUTC)
    self.showHomeMarker = try c.decodeIfPresent(Bool.self, forKey: .showHomeMarker)
    self.homeLabel = try c.decodeIfPresent(String.self, forKey: .homeLabel)
    self.markers = try c.decodeIfPresent([Marker].self, forKey: .markers) ?? []
  }
}
