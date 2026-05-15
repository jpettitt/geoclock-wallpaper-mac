import XCTest
@testable import GeoClockWallpaper

/// `WallpaperConfig` is a long-lived persisted struct that's
/// grown several rounds of fields. Each round risked breaking
/// existing on-disk configs — the custom `init(from:)` is the
/// guardrail, and these tests pin the legacy-key migration
/// paths so future renames don't silently destroy user data.
final class WallpaperConfigTests: XCTestCase {

  private let decoder = JSONDecoder()
  private let encoder = JSONEncoder()

  // MARK: – Marker

  func testMarker_decodesLegacyColorIntoDayAndNight() throws {
    // Pre-split configs only had a single `color` field. New
    // decode should seed BOTH dayColor and nightColor from it
    // so the marker doesn't visually change colour on upgrade.
    let json = ##"{"label":"Tokyo","latitude":35.6,"longitude":139.7,"color":"#abcdef"}"##.data(using: .utf8)!
    let m = try decoder.decode(Marker.self, from: json)
    XCTAssertEqual(m.dayColor, "#abcdef")
    XCTAssertEqual(m.nightColor, "#abcdef")
  }

  func testMarker_dayAndNightColorWinOverLegacy() throws {
    // If both legacy `color` AND the new keys are present,
    // the new keys should win — a user who already saw the
    // split UI has explicitly set them.
    let json = ##"""
    {"label":"T","latitude":0,"longitude":0,
     "color":"#abcdef","dayColor":"#111111","nightColor":"#222222"}
    """##.data(using: .utf8)!
    let m = try decoder.decode(Marker.self, from: json)
    XCTAssertEqual(m.dayColor, "#111111")
    XCTAssertEqual(m.nightColor, "#222222")
  }

  func testMarker_missingShowFlagsDefaultToTrue() throws {
    // showLabel / showTime / showDate were added later. Missing
    // keys should default to true so legacy markers keep their
    // labels.
    let json = #"{"label":"T","latitude":0,"longitude":0}"#.data(using: .utf8)!
    let m = try decoder.decode(Marker.self, from: json)
    XCTAssertTrue(m.showLabel)
    XCTAssertTrue(m.showTime)
    XCTAssertTrue(m.showDate)
  }

  func testMarker_encodeDropsLegacyColorKey() throws {
    // The custom encoder should NEVER write the legacy `color`
    // key — only dayColor + nightColor — so the persisted JSON
    // drifts forward to the new schema on the next save.
    let m = Marker(label: "T", latitude: 1, longitude: 2,
                   dayColor: "#aaa", nightColor: "#bbb")
    let data = try encoder.encode(m)
    let s = String(data: data, encoding: .utf8)!
    XCTAssertFalse(s.contains("\"color\":"),
                   "encoded JSON should not echo the legacy 'color' key, got: \(s)")
    XCTAssertTrue(s.contains("\"dayColor\""))
    XCTAssertTrue(s.contains("\"nightColor\""))
  }

  // MARK: – WallpaperConfig top-level migration

  func testWallpaperConfig_legacyShowHomeMarkerLabelSeedsSplitFlags() throws {
    // Old configs only had `showHomeMarkerLabel` (one toggle
    // for name + time + date). New decoder should fan it out
    // to showHomeName / showHomeTime / showHomeDate so users
    // who had "show label" on don't suddenly see the home dot
    // with no text.
    let json = #"{"showHomeMarkerLabel":true}"#.data(using: .utf8)!
    let c = try decoder.decode(WallpaperConfig.self, from: json)
    XCTAssertTrue(c.showHomeMarkerLabel)
    XCTAssertTrue(c.showHomeName)
    XCTAssertTrue(c.showHomeTime)
    XCTAssertTrue(c.showHomeDate)
  }

  func testWallpaperConfig_newKeysWinOverLegacyShowHomeMarkerLabel() throws {
    let json = #"""
    {"showHomeMarkerLabel":true, "showHomeName":false,
     "showHomeTime":true, "showHomeDate":false}
    """#.data(using: .utf8)!
    let c = try decoder.decode(WallpaperConfig.self, from: json)
    XCTAssertFalse(c.showHomeName)
    XCTAssertTrue(c.showHomeTime)
    XCTAssertFalse(c.showHomeDate)
  }

  func testWallpaperConfig_missingKeysInheritDefaults() throws {
    // An empty config blob should NOT throw — every field is
    // backed by a default. This is what makes the field-add
    // story safe across releases.
    let json = "{}".data(using: .utf8)!
    let c = try decoder.decode(WallpaperConfig.self, from: json)
    XCTAssertEqual(c.centerMode, WallpaperConfig.defaults.centerMode)
    XCTAssertEqual(c.aspectFit, WallpaperConfig.defaults.aspectFit)
    XCTAssertEqual(c.launchAtStartup,
                   WallpaperConfig.defaults.launchAtStartup)
  }

  // MARK: – resolved(forDisplay:)

  func testResolved_unmodifiedWhenPerDisplayOff() {
    var cfg = WallpaperConfig.defaults
    cfg.perDisplayEnabled = false
    cfg.perDisplaySettings["uuid-1"] = {
      var pd = PerDisplaySettings()
      pd.aspectFit = .letterbox
      return pd
    }()
    let r = cfg.resolved(forDisplay: "uuid-1")
    XCTAssertEqual(r.aspectFit, cfg.aspectFit,
                   "per-display overrides must not apply when the master toggle is off")
  }

  func testResolved_unmodifiedWhenUUIDMissing() {
    var cfg = WallpaperConfig.defaults
    cfg.perDisplayEnabled = true
    let r = cfg.resolved(forDisplay: "no-such-uuid")
    XCTAssertEqual(r.aspectFit, cfg.aspectFit)
  }

  func testResolved_appliesNonNilOverrides() {
    var cfg = WallpaperConfig.defaults
    cfg.aspectFit = .stretch
    cfg.showHomeMarker = false
    cfg.perDisplayEnabled = true
    var pd = PerDisplaySettings()
    pd.aspectFit = .letterbox
    pd.showHomeMarker = true
    cfg.perDisplaySettings["uuid-1"] = pd

    let r = cfg.resolved(forDisplay: "uuid-1")
    XCTAssertEqual(r.aspectFit, .letterbox)
    XCTAssertTrue(r.showHomeMarker)
    // Untouched field falls through to the global value.
    XCTAssertEqual(r.centerMode, cfg.centerMode)
  }

  func testResolved_markersReplaceGlobalEntirely() {
    // The per-display markers list is non-optional and OWNS
    // that display's markers when an entry exists. We
    // intentionally don't merge — each display can have a
    // completely different list.
    var cfg = WallpaperConfig.defaults
    cfg.markers = [Marker(label: "Global", latitude: 0, longitude: 0)]
    cfg.perDisplayEnabled = true
    var pd = PerDisplaySettings()
    pd.markers = [Marker(label: "PerDisplay", latitude: 10, longitude: 20)]
    cfg.perDisplaySettings["uuid-1"] = pd

    let r = cfg.resolved(forDisplay: "uuid-1")
    XCTAssertEqual(r.markers.map(\.label), ["PerDisplay"])
  }

  func testResolved_emptyMarkersListMeansNoMarkers() {
    // An entry with an empty markers list is a VALID user
    // choice — "this display shows no markers" — not a
    // missing override. Verify we don't quietly fall back to
    // the global list.
    var cfg = WallpaperConfig.defaults
    cfg.markers = [Marker(label: "Global", latitude: 0, longitude: 0)]
    cfg.perDisplayEnabled = true
    cfg.perDisplaySettings["uuid-1"] = PerDisplaySettings()  // empty markers

    let r = cfg.resolved(forDisplay: "uuid-1")
    XCTAssertEqual(r.markers.count, 0,
                   "empty per-display markers must NOT inherit global list")
  }

  // MARK: – PerDisplaySettings Codable

  func testPerDisplaySettings_decodeMissingMarkersDefaultsToEmpty() throws {
    let json = "{}".data(using: .utf8)!
    let pd = try decoder.decode(PerDisplaySettings.self, from: json)
    XCTAssertEqual(pd.markers.count, 0)
    XCTAssertNil(pd.aspectFit)
    XCTAssertNil(pd.centerMode)
  }

  func testPerDisplaySettings_roundtripPreservesOverrides() throws {
    var pd = PerDisplaySettings()
    pd.aspectFit = .letterbox
    pd.showHomeMarker = false
    pd.homeLabel = "Office"
    pd.markers = [
      Marker(label: "A", latitude: 1, longitude: 2),
      Marker(label: "B", latitude: 3, longitude: 4),
    ]
    let data = try encoder.encode(pd)
    let back = try decoder.decode(PerDisplaySettings.self, from: data)
    XCTAssertEqual(back.aspectFit, .letterbox)
    XCTAssertEqual(back.showHomeMarker, false)
    XCTAssertEqual(back.homeLabel, "Office")
    XCTAssertEqual(back.markers.map(\.label), ["A", "B"])
  }
}
