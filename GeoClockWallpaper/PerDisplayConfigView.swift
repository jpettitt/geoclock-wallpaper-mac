import AppKit
import SwiftUI

/// SwiftUI form rendered inside each floating per-display
/// panel. Reads/writes `store.config.perDisplaySettings[uuid]`
/// directly through helper bindings — every override field is
/// `Optional`, with `nil` meaning "inherit the global config
/// value at render time".
///
/// Layout mirrors the global Settings tabs (Map / Clock /
/// Home / Markers) but each control is paired with a small
/// "↻" reset affordance when the user has set an override, so
/// they can revert any single field without touching the rest.
///
/// Markers are special: the per-display marker list is a
/// non-optional `[Marker]` that replaces the global list
/// entirely for this display when present. The first time the
/// user touches the marker section we seed it with a copy of
/// the global markers so they have something to edit rather
/// than starting from a blank list.
struct PerDisplayConfigView: View {

  let displayUUID: String
  let displayName: String

  @EnvironmentObject var store: ConfigStore

  var body: some View {
    Form {
      Section(displayName) {
        Text("Settings below override the global config for this display only. Empty fields inherit from Settings.")
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(uuidShortLabel)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
      }

      Section("Map") {
        centerModeRow
        if effectiveCenterMode == .manual {
          // Latitude doesn't affect map centering on an
          // equirectangular projection — only longitude does —
          // and hiding the lat field keeps the wallpaper page
          // from synthesizing a fake home entity (which would
          // otherwise put an unhideable home-marker at the
          // centering point).
          manualLongitudeRow
        }
        aspectFitRow
        showTimezoneBandRow
        showTimezoneBoundariesRow
      }

      Section("Clock") {
        clockPositionRow
        clockSourceRow
        if effectiveClockSource == .manualTimezone {
          manualTimezoneRow
        }
        showUTCRow
      }

      Section("Home marker") {
        showHomeMarkerRow
        homeLabelRow
      }

      Section("Markers — this display only") {
        if perDisplay()?.markers == nil {
          // Inherit state: this display shows the global marker
          // list untouched. Customizing forks a copy (or starts
          // empty) — from then on edits here don't affect other
          // displays.
          Text("This display inherits the global markers (\(store.config.markers.count)). Customize to give it its own list.")
            .font(.caption)
            .foregroundStyle(.secondary)
          HStack {
            Button("Customize — copy global markers") { copyGlobalMarkers() }
              .disabled(store.config.markers.isEmpty)
            Button("Customize — start empty") {
              markersBinding.wrappedValue = []
            }
          }
        } else {
          if markersBinding.wrappedValue.isEmpty {
            Text("No markers on this display.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          ForEach(customMarkersBinding) { $marker in
            let markerID = marker.id
            MarkerRow(
              marker: $marker,
              defaultDayHex: store.config.markerDayColor,
              defaultNightHex: store.config.markerNightColor,
              onDelete: {
                deleteMarker(id: markerID)
              })
            Divider()
          }
          HStack {
            Button(action: addMarker) {
              Label("Add marker", systemImage: "plus")
            }
            Button("Revert to global markers") {
              var s = store.config.perDisplaySettings[displayUUID]
                ?? PerDisplaySettings()
              s.markers = nil
              setOrPrune(s)
            }
          }
        }
      }

      Section {
        Button(role: .destructive, action: clearOverrides) {
          Text("Reset all overrides for this display")
        }
        .disabled(!hasAnyOverride)
      }
    }
    .formStyle(.grouped)
  }

  // MARK: – Reused rows

  private var centerModeRow: some View {
    HStack {
      Picker("Center on", selection: override(\.centerMode)) {
        Text("Inherit (\(store.config.centerMode.displayName))")
          .tag(Optional<CenterMode>.none)
        ForEach(CenterMode.allCases) { mode in
          Text(mode.displayName)
            .tag(Optional<CenterMode>.some(mode))
        }
      }
      resetButton(\.centerMode)
    }
  }

  private var manualLongitudeRow: some View {
    HStack {
      TextField(
        "Center longitude",
        value: doubleBinding(\.manualLongitude,
                             fallback: store.config.manualLongitude),
        format: .number.precision(.fractionLength(0...4))
      )
      resetButton(\.manualLongitude)
    }
  }

  private var aspectFitRow: some View {
    HStack {
      Picker("Fit", selection: override(\.aspectFit)) {
        Text("Inherit (\(store.config.aspectFit.displayName))")
          .tag(Optional<AspectFit>.none)
        ForEach(AspectFit.allCases) { fit in
          Text(fit.displayName)
            .tag(Optional<AspectFit>.some(fit))
        }
      }
      resetButton(\.aspectFit)
    }
  }

  private var showTimezoneBandRow: some View {
    HStack {
      Picker("Hour band", selection: override(\.showTimezoneBand)) {
        Text("Inherit (\(store.config.showTimezoneBand ? "show" : "hide"))")
          .tag(Optional<Bool>.none)
        Text("Show").tag(Optional<Bool>.some(true))
        Text("Hide").tag(Optional<Bool>.some(false))
      }
      .pickerStyle(.segmented)
      resetButton(\.showTimezoneBand)
    }
  }

  private var showTimezoneBoundariesRow: some View {
    HStack {
      Picker("Time-zone boundaries", selection: override(\.showTimezoneBoundaries)) {
        Text("Inherit (\(store.config.showTimezoneBoundaries ? "show" : "hide"))")
          .tag(Optional<Bool>.none)
        Text("Show").tag(Optional<Bool>.some(true))
        Text("Hide").tag(Optional<Bool>.some(false))
      }
      .pickerStyle(.segmented)
      resetButton(\.showTimezoneBoundaries)
    }
  }

  private var clockPositionRow: some View {
    HStack {
      Picker("Clock position", selection: override(\.clockPosition)) {
        Text("Inherit (\(store.config.clockPosition.displayName))")
          .tag(Optional<ClockPosition>.none)
        ForEach(ClockPosition.allCases) { pos in
          Text(pos.displayName)
            .tag(Optional<ClockPosition>.some(pos))
        }
      }
      resetButton(\.clockPosition)
    }
  }

  private var clockSourceRow: some View {
    HStack {
      Picker("Clock source", selection: override(\.clockSource)) {
        Text("Inherit (\(store.config.clockSource.displayName))")
          .tag(Optional<ClockSource>.none)
        ForEach(ClockSource.allCases) { src in
          Text(src.displayName)
            .tag(Optional<ClockSource>.some(src))
        }
      }
      resetButton(\.clockSource)
    }
  }

  private var manualTimezoneRow: some View {
    HStack {
      TextField(
        "IANA zone (e.g. America/Los_Angeles)",
        text: stringBinding(\.manualTimezone,
                            fallback: store.config.manualTimezone))
      resetButton(\.manualTimezone)
    }
  }

  private var showUTCRow: some View {
    HStack {
      Picker("UTC line", selection: override(\.showUTC)) {
        Text("Inherit (\(store.config.showUTC ? "show" : "hide"))")
          .tag(Optional<Bool>.none)
        Text("Show").tag(Optional<Bool>.some(true))
        Text("Hide").tag(Optional<Bool>.some(false))
      }
      .pickerStyle(.segmented)
      resetButton(\.showUTC)
    }
  }

  private var showHomeMarkerRow: some View {
    HStack {
      Picker("Home marker", selection: override(\.showHomeMarker)) {
        Text("Inherit (\(store.config.showHomeMarker ? "show" : "hide"))")
          .tag(Optional<Bool>.none)
        Text("Show").tag(Optional<Bool>.some(true))
        Text("Hide").tag(Optional<Bool>.some(false))
      }
      .pickerStyle(.segmented)
      resetButton(\.showHomeMarker)
    }
  }

  private var homeLabelRow: some View {
    HStack {
      TextField(
        store.config.homeLabel.isEmpty ? "Home" : store.config.homeLabel,
        text: stringBinding(\.homeLabel,
                            fallback: store.config.homeLabel))
      resetButton(\.homeLabel)
    }
  }

  // MARK: – Resolved values (for "inherits …" labels)

  /// Resolved centerMode for this display — drives the show/hide
  /// of the manual-lat/lon rows below the picker.
  private var effectiveCenterMode: CenterMode {
    perDisplay()?.centerMode ?? store.config.centerMode
  }

  private var effectiveClockSource: ClockSource {
    perDisplay()?.clockSource ?? store.config.clockSource
  }

  private var uuidShortLabel: String {
    "UUID \(displayUUID.prefix(8))…"
  }

  private var hasAnyOverride: Bool {
    guard let pd = perDisplay() else { return false }
    return
      pd.centerMode != nil ||
      pd.manualLongitude != nil ||
      pd.aspectFit != nil ||
      pd.showTimezoneBand != nil ||
      pd.showTimezoneBoundaries != nil ||
      pd.clockPosition != nil ||
      pd.clockSource != nil ||
      pd.manualTimezone != nil ||
      pd.showUTC != nil ||
      pd.showHomeMarker != nil ||
      pd.homeLabel != nil ||
      pd.markers != nil
  }

  // MARK: – Bindings

  /// Snapshot of the per-display settings for this UUID, or nil
  /// if the user hasn't set any overrides yet.
  private func perDisplay() -> PerDisplaySettings? {
    store.config.perDisplaySettings[displayUUID]
  }

  /// Read/write `Binding` into one Optional field on this
  /// display's `PerDisplaySettings`. Setting the binding to nil
  /// reverts that field to inherited; setting to a concrete
  /// value materialises a `PerDisplaySettings` entry if needed.
  /// Entries that end up with no overrides at all are pruned so
  /// "select a picker then put it back to Inherit" doesn't leave
  /// junk entries in the persisted config.
  private func override<T>(
    _ kp: WritableKeyPath<PerDisplaySettings, T?>
  ) -> Binding<T?> {
    Binding(
      get: { store.config.perDisplaySettings[displayUUID]?[keyPath: kp] },
      set: { newValue in
        var s = store.config.perDisplaySettings[displayUUID]
          ?? PerDisplaySettings()
        s[keyPath: kp] = newValue
        setOrPrune(s)
      }
    )
  }

  /// Store the settings entry, or remove it entirely when every
  /// field reverted to inherit.
  private func setOrPrune(_ s: PerDisplaySettings) {
    if s.isEmpty {
      store.config.perDisplaySettings.removeValue(forKey: displayUUID)
    } else {
      store.config.perDisplaySettings[displayUUID] = s
    }
  }

  /// String-typed override with a fallback (the inherited
  /// value). Bound to a `Binding<String>` so TextField is happy.
  /// Empty string → override = nil (reverts to inherit).
  private func stringBinding(
    _ kp: WritableKeyPath<PerDisplaySettings, String?>,
    fallback: String
  ) -> Binding<String> {
    Binding(
      get: { override(kp).wrappedValue ?? fallback },
      set: { v in override(kp).wrappedValue = v.isEmpty ? nil : v }
    )
  }

  /// Double-typed override with a fallback. Cleared field is
  /// represented as 0 → nil (reverts to inherit).
  private func doubleBinding(
    _ kp: WritableKeyPath<PerDisplaySettings, Double?>,
    fallback: Double
  ) -> Binding<Double> {
    Binding(
      get: { override(kp).wrappedValue ?? fallback },
      set: { v in override(kp).wrappedValue = v }
    )
  }

  /// Reset button for any override field — clears the value
  /// back to nil so the renderer inherits the global setting.
  @ViewBuilder
  private func resetButton<T: Equatable>(
    _ kp: WritableKeyPath<PerDisplaySettings, T?>
  ) -> some View {
    if override(kp).wrappedValue != nil {
      Button(action: { override(kp).wrappedValue = nil }) {
        Image(systemName: "arrow.counterclockwise")
      }
      .buttonStyle(.borderless)
      .help("Revert to inherited value")
    }
  }

  /// Markers list as a non-optional Binding over this display's
  /// CUSTOMIZED list. Only used by UI shown when the override is
  /// non-nil; writing through it (re)materialises the override.
  /// Reading while still inheriting returns [] defensively.
  private var markersBinding: Binding<[Marker]> {
    Binding(
      get: { store.config.perDisplaySettings[displayUUID]?.markers ?? [] },
      set: { newValue in
        var s = store.config.perDisplaySettings[displayUUID]
          ?? PerDisplaySettings()
        s.markers = newValue
        store.config.perDisplaySettings[displayUUID] = s
      }
    )
  }

  /// Same data as `markersBinding` — alias kept separate so the
  /// ForEach call site reads clearly as "the customized list".
  private var customMarkersBinding: Binding<[Marker]> { markersBinding }

  // MARK: – Actions

  private func addMarker() {
    markersBinding.wrappedValue.append(Marker())
  }

  private func deleteMarker(id: UUID) {
    var s = store.config.perDisplaySettings[displayUUID]
      ?? PerDisplaySettings()
    var list = s.markers ?? []
    list.removeAll { $0.id == id }
    s.markers = list
    store.config.perDisplaySettings[displayUUID] = s
  }

  private func copyGlobalMarkers() {
    // Fresh UUIDs so the per-display copies are independent
    // identities — editing one doesn't shadow the global entry
    // by accident.
    let copies = store.config.markers.map { m in
      Marker(
        id: UUID(),
        label: m.label,
        latitude: m.latitude,
        longitude: m.longitude,
        dayColor: m.dayColor,
        nightColor: m.nightColor,
        place: m.place,
        tzid: m.tzid,
        showLabel: m.showLabel,
        showTime: m.showTime,
        showDate: m.showDate)
    }
    markersBinding.wrappedValue = copies
  }

  private func clearOverrides() {
    store.config.perDisplaySettings.removeValue(forKey: displayUUID)
  }
}

// `displayName` extensions for AspectFit / CenterMode /
// ClockPosition / ClockSource live in WallpaperConfig.swift.
