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

  /// This display's marker list. Optional like every other
  /// override field: nil inherits the global `markers`; non-nil
  /// REPLACES them entirely for this display — including the
  /// empty list, which is the valid "no markers on this screen"
  /// choice. It must be Optional: the override-binding helpers
  /// materialize a PerDisplaySettings entry the first time ANY
  /// field is set on a display, and when markers was a plain
  /// `[Marker] = []` that materialization silently wiped the
  /// display's markers (set the clock position → all dots gone).
  var markers: [Marker]? = nil

  // MARK: – Codable

  enum CodingKeys: String, CodingKey {
    case centerMode, manualLatitude, manualLongitude, aspectFit
    case showTimezoneBand, showTimezoneBoundaries
    case clockPosition, clockSource, manualTimezone, showUTC
    case showHomeMarker, homeLabel
    case markers
    /// Disambiguates a deliberate empty markers list from the
    /// empty arrays the pre-Optional wipe bug persisted — see
    /// init(from:) / encode(to:).
    case markersExplicitlyEmpty
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
    // Healing decode for the pre-Optional bug: entries that were
    // accidentally materialized with an empty markers array (the
    // old override-binding wiped markers on any unrelated edit)
    // should go back to inheriting the global list. A non-empty
    // array is always a deliberate per-display list and survives.
    // Post-fix, a deliberate "no markers on this display" persists
    // as an explicit empty array via the custom encode below.
    let decodedMarkers = try c.decodeIfPresent([Marker].self, forKey: .markers)
    let explicitlyEmpty = try c.decodeIfPresent(Bool.self, forKey: .markersExplicitlyEmpty) ?? false
    if let m = decodedMarkers, m.isEmpty, !explicitlyEmpty {
      self.markers = nil
    } else {
      self.markers = decodedMarkers
    }
  }

  /// Custom encode: alongside an empty markers array we write a
  /// disambiguation flag, so a deliberate "no markers" survives the
  /// healing decode above (which otherwise maps [] → inherit to
  /// repair configs damaged by the pre-Optional wipe bug).
  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encodeIfPresent(centerMode, forKey: .centerMode)
    try c.encodeIfPresent(manualLatitude, forKey: .manualLatitude)
    try c.encodeIfPresent(manualLongitude, forKey: .manualLongitude)
    try c.encodeIfPresent(aspectFit, forKey: .aspectFit)
    try c.encodeIfPresent(showTimezoneBand, forKey: .showTimezoneBand)
    try c.encodeIfPresent(showTimezoneBoundaries, forKey: .showTimezoneBoundaries)
    try c.encodeIfPresent(clockPosition, forKey: .clockPosition)
    try c.encodeIfPresent(clockSource, forKey: .clockSource)
    try c.encodeIfPresent(manualTimezone, forKey: .manualTimezone)
    try c.encodeIfPresent(showUTC, forKey: .showUTC)
    try c.encodeIfPresent(showHomeMarker, forKey: .showHomeMarker)
    try c.encodeIfPresent(homeLabel, forKey: .homeLabel)
    try c.encodeIfPresent(markers, forKey: .markers)
    if let m = markers, m.isEmpty {
      try c.encode(true, forKey: .markersExplicitlyEmpty)
    }
  }

  /// True when no field overrides anything — the entry is pure
  /// noise (typically materialized then reverted) and callers can
  /// drop it from `perDisplaySettings` instead of persisting it.
  var isEmpty: Bool {
    centerMode == nil &&
    manualLatitude == nil &&
    manualLongitude == nil &&
    aspectFit == nil &&
    showTimezoneBand == nil &&
    showTimezoneBoundaries == nil &&
    clockPosition == nil &&
    clockSource == nil &&
    manualTimezone == nil &&
    showUTC == nil &&
    showHomeMarker == nil &&
    homeLabel == nil &&
    markers == nil
  }
}
