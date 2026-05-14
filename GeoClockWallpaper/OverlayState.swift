import AppKit
import Combine
import CoreLocation
import Foundation

/// Observable state container backing the overlay layer. Owns
/// everything the SwiftUI OverlayView needs to redraw — config
/// snapshot, current centerLon (matched to the wallpaper PNG),
/// home location, 1 Hz tick. The OverlayLayer hosts a single
/// instance shared across all per-screen windows.
///
/// Updated from three places:
///   - ConfigStore (Combine) → marker list, clock options,
///     aspect-fit, home toggles, menubar height
///   - LocationService → home coordinate
///   - WallpaperRenderer → currentCenterLon (set after each
///     render completes so we share the same value the
///     wallpaper PNG was drawn with)
///   - Self-driven 1 Hz timer → `now`, drives clock + marker
///     time text
final class OverlayState: ObservableObject {

  // MARK: – Inputs from elsewhere

  /// Last centerLon a wallpaper render committed to (global /
  /// single-display path). The overlay projects markers against
  /// this — keeping it synced with the wallpaper means a marker
  /// dot in the overlay sits exactly over the (now-hidden) dot
  /// the card would have drawn.
  @Published var currentCenterLon: Double = 0

  /// Per-display center longitudes — one per rendered screen so
  /// each overlay projects its markers against the centerLon
  /// the wallpaper for THAT screen was drawn at. Falls back to
  /// `currentCenterLon` when a display has no entry yet (first
  /// render in progress).
  @Published var centerLonsByDisplay: [CGDirectDisplayID: Double] = [:]

  /// Aspect-fit mode (Stretch / Letterbox / Crop overflow).
  /// Determines stage-2 projection.
  @Published var aspectFit: AspectFit = .cropOverflow

  /// Whether the card is rendering the 24-hour band at the top
  /// of the map. The SVG's viewBox y range depends on this:
  /// `[-44, 1024]` with the band on, `[0, 1024]` without. The
  /// overlay's projection has to match or latitude shifts by
  /// the band height.
  @Published var showTimezoneBand: Bool = true

  /// Menu-bar padding the wallpaper page reserves at top.
  /// Subtracted from screen-effective height in projection so
  /// the overlay tracks the painted region of the PNG.
  @Published var menuBarHeight: Double = 24

  /// User-placed location markers. Persisted in ConfigStore;
  /// we mirror here so SwiftUI bindings are local to the
  /// overlay layer.
  @Published var markers: [Marker] = []

  /// Whether to draw a dot at the user's home location.
  @Published var showHomeMarker: Bool = true
  /// Legacy combined toggle. Retained so older callers compile;
  /// the renderer reads `showHomeName` / `showHomeTime` below.
  @Published var showHomeMarkerLabel: Bool = false
  /// Split visibility flags — name, time, and weekday can each
  /// be toggled independently below the home dot.
  @Published var showHomeName: Bool = false
  @Published var showHomeTime: Bool = false
  @Published var showHomeDate: Bool = false

  /// User-customisable text shown when `showHomeName` is on.
  /// Defaults to "Home" — see `WallpaperConfig.homeLabel` for the
  /// rationale.
  @Published var homeLabel: String = "Home"

  /// Per-time-of-day fills for the home marker. Same day/night
  /// model as user markers, picked by `Sun.isDaylight` at the
  /// home coord on every redraw.
  @Published var homeDayColor: String = "#ff7a3d"
  @Published var homeNightColor: String = "#ff7a3d"

  /// Resolved home coordinate. Same source as the wallpaper's
  /// home marker — Core Location fix if available, else the
  /// time-zone centroid.
  @Published var homeCoordinate: CLLocationCoordinate2D?

  /// IANA timezone the home marker's clock should use. Resolved
  /// from `homeCoordinate` via `TimezoneResolver` whenever the
  /// coordinate changes — nil while the geocode is in flight,
  /// at which point the overlay falls back to `TimeZone.current`.
  @Published var homeTimezone: TimeZone?

  /// Clock display settings.
  @Published var clockPosition: ClockPosition = .bottomLeft
  @Published var clockSource: ClockSource = .matchCenter
  @Published var manualTimezone: String = ""
  @Published var showUTC: Bool = true

  /// Default marker color (hex) for markers that don't override.
  /// Retained for legacy decoding; the day/night split below is
  /// what the renderer reads.
  @Published var markerDefaultColor: String = "#3da9fc"

  /// Per-time-of-day default fills for markers without an
  /// explicit `color` override. Picked by `Sun.isDaylight` on
  /// each marker's coords at `now`.
  @Published var markerDayColor: String = "#ff9933"
  @Published var markerNightColor: String = "#3da9fc"

  // MARK: – Self-driven

  /// The "current time" the SwiftUI view uses for clock and
  /// marker time text. Ticks once per second.
  @Published var now: Date = Date()

  /// `true` once we've received at least one centerLon update
  /// from the renderer. Before that, overlay hides itself —
  /// otherwise it'd render markers at a stale or zero centerLon
  /// while the wallpaper itself shows a different view.
  @Published var hasInitialRender: Bool = false

  /// Per-display rendered wallpaper bitmaps, keyed by
  /// `CGDirectDisplayID`. Each overlay window looks up its own
  /// image so a multi-monitor setup with different aspect
  /// ratios isn't forced to crop one render across every screen.
  /// Empty until the first per-screen render lands.
  @Published var wallpaperImages: [CGDirectDisplayID: NSImage] = [:]

  /// Set of display UUID strings the user has opted to NOT
  /// render the wallpaper on. We persist UUIDs (via
  /// `DisplayIdentity.uuidString(forID:)`) because the
  /// `CGDirectDisplayID` value can shift across reboots when
  /// multiple monitors are connected.
  @Published var disabledDisplays: Set<String> = []

  /// Full snapshot of the latest `WallpaperConfig`. Mirrors the
  /// individual flat `@Published` fields above (kept for
  /// readability in views that don't need the per-display
  /// override system), and gives views that DO need it access
  /// to `perDisplaySettings` for `resolvedConfig(forScreen:)`.
  @Published var config: WallpaperConfig = .defaults

  /// UUID of the display the Settings window is currently
  /// presented on. Nil when Settings is closed. Drives two
  /// behaviours: the "This display" tab in Settings shows
  /// PerDisplayConfigView for this UUID, and
  /// `PerDisplayPanelManager` suppresses the floating panel
  /// for whichever display Settings is occupying so the user
  /// never sees the same controls twice.
  @Published var settingsWindowDisplayUUID: String?

  // MARK: – Init

  private var tickTimer: Timer?

  init() {
    startTick()
  }

  deinit { tickTimer?.invalidate() }

  private func startTick() {
    let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
      self?.now = Date()
    }
    RunLoop.main.add(t, forMode: .common)
    tickTimer = t
  }

  // MARK: – External setters (called by AppDelegate)

  func updateCenterLon(_ value: Double) {
    currentCenterLon = value
    if !hasInitialRender { hasInitialRender = true }
  }

  /// Resolve the config a specific overlay should render with.
  /// Folds the per-display overrides keyed by the screen's UUID
  /// onto the global config. Falls back to the global config
  /// when per-display mode is off, the screen has no UUID, or
  /// the screen has no per-display entry.
  func resolvedConfig(forScreen screen: NSScreen) -> WallpaperConfig {
    let uuid = DisplayIdentity.uuidString(of: screen)
    return config.resolved(forDisplay: uuid)
  }

  func applyConfig(_ cfg: WallpaperConfig) {
    config = cfg
    aspectFit = cfg.aspectFit
    showTimezoneBand = cfg.showTimezoneBand
    markers = cfg.markers
    showHomeMarker = cfg.showHomeMarker
    showHomeMarkerLabel = cfg.showHomeMarkerLabel
    showHomeName = cfg.showHomeName
    showHomeTime = cfg.showHomeTime
    showHomeDate = cfg.showHomeDate
    homeLabel = cfg.homeLabel
    homeDayColor = cfg.homeDayColor
    homeNightColor = cfg.homeNightColor
    disabledDisplays = Set(cfg.disabledDisplays)
    clockPosition = cfg.clockPosition
    clockSource = cfg.clockSource
    manualTimezone = cfg.manualTimezone
    showUTC = cfg.showUTC
    markerDefaultColor = cfg.markerDefaultColor
    markerDayColor = cfg.markerDayColor
    markerNightColor = cfg.markerNightColor
  }
}
