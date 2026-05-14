import AppKit
import SwiftUI

/// SwiftUI Settings pane. TabView at the top splits the surface
/// into four screens (Map / Clock / Markers / Schedule) that
/// match the conceptual sections of the TODO. Every control
/// binds directly through `$config.config.<field>` so edits
/// propagate to the menu-bar render loop without plumbing.
///
/// All UI here is the v1 first pass — Core Location, marker
/// visibility hints, and the per-display section are stubbed
/// or marked `TODO` and will land later.
struct SettingsView: View {
  @EnvironmentObject var store: ConfigStore

  var body: some View {
    TabView {
      MapSettingsTab()
        .tabItem { Label("Map", systemImage: "globe") }
      ClockSettingsTab()
        .tabItem { Label("Clock", systemImage: "clock") }
      MarkersSettingsTab()
        .tabItem { Label("Markers", systemImage: "mappin") }
      DisplaysSettingsTab()
        .tabItem { Label("Displays", systemImage: "display.2") }
      ThisDisplaySettingsTab()
        .tabItem { Label("This display", systemImage: "display") }
      ScheduleSettingsTab()
        .tabItem { Label("Schedule", systemImage: "timer") }
    }
    .padding()
    // Tall enough for the Map tab's three sections without
    // scrolling on macOS 13+. Each Form section block is
    // ~80–100 px, plus ~40 px for the tab bar and the window
    // chrome.
    .frame(width: 560, height: 560)
    .environmentObject(store)
  }
}

// MARK: – Map tab

private struct MapSettingsTab: View {
  @EnvironmentObject var store: ConfigStore
  @ObservedObject private var location = LocationService.shared

  var body: some View {
    Form {
      Section("Centering") {
        Picker("Center on", selection: $store.config.centerMode) {
          ForEach(CenterMode.allCases) { mode in
            Text(mode.displayName).tag(mode)
          }
        }
        if store.config.centerMode == .manual {
          // Only longitude matters for centering — the map is
          // equirectangular and the latitude doesn't change
          // which slice of the world is on-screen. Skipping
          // the lat input also keeps the card from synthesizing
          // a "home" entity, which would otherwise drop an
          // unhideable home-marker at the centering point.
          TextField(
            "Center longitude",
            value: $store.config.manualLongitude,
            format: .number.precision(.fractionLength(0...4))
          )
        }
        if store.config.centerMode == .myLocation {
          Text(location.statusDescription())
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        if store.config.centerMode == .timezoneGuess {
          Text("Uses the geographic centroid of your Mac's IANA time zone. (Centroid lookup is on the TODO list — for now this behaves the same as “Follow the sun”.)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Section("Fit to screen") {
        // Menu picker (1 row) rather than radio group (3 rows)
        // — same options, much tighter so the Map tab fits in
        // the default Settings window without scrolling.
        Picker("When the map's aspect doesn't match", selection: $store.config.aspectFit) {
          ForEach(AspectFit.allCases) { mode in
            Text(mode.displayName).tag(mode)
          }
        }
      }

      Section("Layers") {
        Toggle("Time-zone boundaries", isOn: $store.config.showTimezoneBoundaries)
        Toggle("Hour-of-day band", isOn: $store.config.showTimezoneBand)
      }
    }
    .formStyle(.grouped)
  }
}

// MARK: – Clock tab

private struct ClockSettingsTab: View {
  @EnvironmentObject var store: ConfigStore

  var body: some View {
    Form {
      Section("Position") {
        Picker("Position", selection: $store.config.clockPosition) {
          ForEach(ClockPosition.allCases) { pos in
            Text(pos.displayName).tag(pos)
          }
        }
        .pickerStyle(.radioGroup)
      }

      if store.config.clockPosition != .hidden {
        Section("Time zone") {
          Picker("Source", selection: $store.config.clockSource) {
            ForEach(ClockSource.allCases) { src in
              Text(src.displayName).tag(src)
            }
          }
          if store.config.clockSource == .manualTimezone {
            TextField(
              "IANA tzid (e.g. America/Los_Angeles)",
              text: $store.config.manualTimezone
            )
            .textFieldStyle(.roundedBorder)
          }
        }

        Section("Format") {
          Toggle("Show UTC line under local time",
                 isOn: $store.config.showUTC)
        }
      }
    }
    .formStyle(.grouped)
  }
}

// MARK: – Markers tab

private struct MarkersSettingsTab: View {
  @EnvironmentObject var store: ConfigStore

  var body: some View {
    Form {
      Section("Home marker") {
        Toggle("Show home marker",
               isOn: $store.config.showHomeMarker)
        if store.config.showHomeMarker {
          // Editable label — the dot pins the current device
          // location, which may not actually be the user's home
          // (e.g. travelling), so let them override the text.
          TextField(
            "Label",
            text: $store.config.homeLabel,
            prompt: Text("Home"))
            .textFieldStyle(.roundedBorder)
          // All visibility toggles on one labelled row, all
          // colour pickers on the row below — splits the row
          // semantically (what's shown vs how it's coloured)
          // while staying compact vertically.
          HStack(spacing: 16) {
            Text("Show:")
            Toggle("Name", isOn: $store.config.showHomeName)
            Toggle("Time", isOn: $store.config.showHomeTime)
            Toggle("Date", isOn: $store.config.showHomeDate)
          }
          HStack(spacing: 16) {
            HexColorPicker(
              title: "Day",
              hex: $store.config.homeDayColor)
            HexColorPicker(
              title: "Night",
              hex: $store.config.homeNightColor)
          }
        }
      }

      Section("Default marker colours") {
        HexColorPicker(
          title: "Daylight side",
          hex: $store.config.markerDayColor)
        HexColorPicker(
          title: "Night side",
          hex: $store.config.markerNightColor)
        Text("Used when a marker doesn't set its own colour. The dot flips automatically as the terminator crosses the location.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("Pinned locations") {
        if store.config.markers.isEmpty {
          Text("No markers yet. Add one to pin a city's local time on the map.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        ForEach($store.config.markers) { $marker in
          let markerID = marker.id
          MarkerRow(
            marker: $marker,
            defaultDayHex: store.config.markerDayColor,
            defaultNightHex: store.config.markerNightColor,
            onDelete: {
              store.config.markers.removeAll { $0.id == markerID }
            })
          Divider()
        }
        Button(action: addMarker) {
          Label("Add marker", systemImage: "plus")
        }
      }
    }
    .formStyle(.grouped)
  }

  private func addMarker() {
    store.config.markers.append(Marker())
  }
}

/// One row of the marker list. Place-name entry drives a
/// forward-geocode that fills the latitude, longitude, and IANA
/// timezone in one round-trip; the resolved coords are shown
/// read-only below. A small error glyph surfaces when the last
/// lookup failed (no result / network down).
struct MarkerRow: View {
  @Binding var marker: Marker
  /// Day-side fallback colour shown as the picker placeholder
  /// when the marker hasn't set its own day colour.
  let defaultDayHex: String
  /// Night-side fallback colour. Mirrors `defaultDayHex` for the
  /// corresponding night picker.
  let defaultNightHex: String
  /// Callback invoked when the trash button is tapped. Callers
  /// remove the marker from the source list they own (global
  /// `config.markers` or a per-display `perDisplaySettings[uuid]
  /// .markers`). Without this hook the trash button would
  /// always hit the global list regardless of which panel
  /// hosted the row.
  let onDelete: () -> Void

  /// Transient per-row state. Tracks the place text the user is
  /// editing (separate from `marker.place` so we don't overwrite
  /// the saved query mid-typing), whether a lookup is in flight,
  /// and whether the last lookup failed.
  @State private var placeDraft: String = ""
  @State private var lookupInFlight: Bool = false
  @State private var lookupFailed: Bool = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        TextField("Label (optional)", text: $marker.label)
          .textFieldStyle(.roundedBorder)
        Spacer()
        Button(role: .destructive, action: remove) {
          Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
      }
      HStack(spacing: 6) {
        TextField(
          "Place — city, country",
          text: $placeDraft
        )
        .textFieldStyle(.roundedBorder)
        .onSubmit(resolvePlace)
        // Submit-button-style affordance so users who don't think
        // to press Return have a visible action. Disabled when the
        // text is empty so we don't pound CLGeocoder on a blank.
        if lookupInFlight {
          ProgressView().controlSize(.small)
        } else {
          Button(action: resolvePlace) {
            Image(systemName: "magnifyingglass")
          }
          .buttonStyle(.borderless)
          .disabled(placeDraft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        if lookupFailed {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .help("Couldn't find that place. Check spelling or your connection and try again.")
        }
      }
      // Visibility toggles on one labelled row; colour pickers
      // on the row below. Splits "what's shown" from "how it's
      // coloured" while keeping each line compact.
      HStack(spacing: 16) {
        Text("Show:")
        Toggle("Name", isOn: $marker.showLabel)
        Toggle("Time", isOn: $marker.showTime)
        Toggle("Date", isOn: $marker.showDate)
      }
      HStack(spacing: 16) {
        HexColorPicker(
          title: "Day",
          hex: $marker.dayColor,
          placeholder: defaultDayHex)
        HexColorPicker(
          title: "Night",
          hex: $marker.nightColor,
          placeholder: defaultNightHex)
      }
      // Resolved coordinates — read-only confirmation that the
      // geocode landed on the right point. Hidden until something
      // is set, so a freshly-added row isn't a wall of zeros.
      if marker.latitude != 0 || marker.longitude != 0 {
        Text(coordSummary)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 4)
    .onAppear {
      // Seed the draft with whatever place query was last saved
      // so editing an existing marker shows the same string they
      // typed before.
      if placeDraft.isEmpty { placeDraft = marker.place }
    }
  }

  /// Lat/lon line shown under the place field. Uses 4 decimal
  /// places (~11 m precision) — enough for the user to recognise
  /// the city without a wall of digits.
  private var coordSummary: String {
    String(
      format: "%.4f°, %.4f°  •  %@",
      marker.latitude, marker.longitude,
      marker.tzid ?? "—"
    )
  }

  private func resolvePlace() {
    let query = placeDraft.trimmingCharacters(in: .whitespaces)
    guard !query.isEmpty else { return }
    lookupInFlight = true
    lookupFailed = false
    TimezoneResolver.shared.forward(place: query) { result in
      lookupInFlight = false
      guard let result = result else {
        lookupFailed = true
        return
      }
      // Write back to the binding so the change persists. If the
      // user hadn't typed a label yet, default it to the place
      // name they just looked up — most users want the marker to
      // read "Paris" without a second edit.
      marker.place = query
      marker.latitude = result.latitude
      marker.longitude = result.longitude
      marker.tzid = result.tzid
      if marker.label.isEmpty {
        marker.label = result.displayName ?? query
      }
    }
  }

  private func remove() {
    onDelete()
  }
}

// MARK: – Displays tab

/// Lists every connected `NSScreen` so the user can opt out of
/// rendering the wallpaper on individual monitors. The toggle
/// state is persisted as the display's UUID (stable across
/// reboots / replug), not its runtime `CGDirectDisplayID`.
///
/// On a single-display setup the per-monitor toggle is hidden —
/// disabling the only display would just produce a black
/// wallpaper everywhere, which is what unchecking "Launch at
/// startup" accomplishes more directly.
private struct DisplaysSettingsTab: View {
  @EnvironmentObject var store: ConfigStore
  @State private var screens: [NSScreen] = NSScreen.screens

  /// Refresh `screens` whenever the system tells us the display
  /// layout changed — plug, unplug, resolution swap. Without
  /// this the tab would show stale state if the user opens it,
  /// plugs in a monitor, then expects to see the new row.
  private let screenChangePublisher = NotificationCenter.default.publisher(
    for: NSApplication.didChangeScreenParametersNotification)

  var body: some View {
    Form {
      Section("Connected displays") {
        if screens.isEmpty {
          Text("No displays detected.")
            .foregroundStyle(.secondary)
        } else if screens.count == 1, let s = screens.first {
          DisplayRow(screen: s, canToggle: false)
          Text("Per-monitor toggles appear here once a second display is connected.")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          ForEach(displayItems, id: \.id) { item in
            DisplayRow(screen: item.screen, canToggle: true)
          }
        }
      }

      Section("Per-display settings") {
        Toggle("Use per-display settings",
               isOn: $store.config.perDisplayEnabled)
        if store.config.perDisplayEnabled {
          Text("Each enabled display gets a floating settings panel positioned in its top-right corner. Override the global Map / Clock / Home / Markers controls per screen, or leave fields blank to inherit.")
            .font(.caption)
            .foregroundStyle(.secondary)
          Button("Show panels") {
            NotificationCenter.default.post(
              name: .showPerDisplayPanels, object: nil)
          }
        } else {
          Text("All displays share the global settings above. Turn this on to give each monitor its own centering, aspect, clock placement, and marker list.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Section {
        Text("Disabling a display stops GeoClockWallpaper from drawing on that monitor. Your system wallpaper for that screen stays visible underneath.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .onReceive(screenChangePublisher) { _ in
      screens = NSScreen.screens
    }
  }

  /// Build an Identifiable list off `screens` so ForEach has a
  /// stable key even when NSScreen instances get re-issued.
  private var displayItems: [DisplayItem] {
    screens.compactMap { screen in
      guard let id = DisplayIdentity.id(of: screen) else { return nil }
      return DisplayItem(id: id, screen: screen)
    }
  }

  private struct DisplayItem {
    let id: CGDirectDisplayID
    let screen: NSScreen
  }
}

/// One row in the Displays tab. Shows the display's name +
/// pt size and (when `canToggle` is true) a "Show wallpaper"
/// switch that toggles membership in
/// `config.disabledDisplays`.
private struct DisplayRow: View {
  let screen: NSScreen
  let canToggle: Bool
  @EnvironmentObject var store: ConfigStore

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(screen.localizedName)
          .font(.body)
        Text(String(
          format: "%.0f × %.0f pt  •  scale %.0fx",
          screen.frame.width, screen.frame.height,
          screen.backingScaleFactor))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      if canToggle, let uuid = DisplayIdentity.uuidString(of: screen) {
        Toggle("Show wallpaper", isOn: enabledBinding(for: uuid))
          .labelsHidden()
      }
    }
    .padding(.vertical, 2)
  }

  /// Inverts the disabled-set semantics for the UI: the toggle
  /// reads "on = wallpaper enabled" while the persisted state
  /// is "off = uuid in disabledDisplays".
  private func enabledBinding(for uuid: String) -> Binding<Bool> {
    Binding(
      get: { !store.config.disabledDisplays.contains(uuid) },
      set: { isEnabled in
        if isEnabled {
          store.config.disabledDisplays.removeAll { $0 == uuid }
        } else if !store.config.disabledDisplays.contains(uuid) {
          store.config.disabledDisplays.append(uuid)
        }
      }
    )
  }
}

// MARK: – This display tab

/// Per-display override panel embedded directly in Settings —
/// targets whichever screen the Settings window is currently
/// on. The Displays tab's master toggle ("Use per-display
/// settings") gates whether the controls are live; when off,
/// this tab shows a hint and a quick-enable button.
///
/// While Settings is on a given screen, the floating panel
/// for that same display is suppressed by
/// `PerDisplayPanelManager` so the user never sees the same
/// controls twice. Drag Settings to another monitor and the
/// content here re-targets that monitor; the floating panel
/// for the screen Settings just left reappears.
private struct ThisDisplaySettingsTab: View {
  @EnvironmentObject var store: ConfigStore
  @EnvironmentObject var overlay: OverlayState

  var body: some View {
    Group {
      if !store.config.perDisplayEnabled {
        offState
      } else if let uuid = overlay.settingsWindowDisplayUUID,
                let name = displayName(forUUID: uuid) {
        PerDisplayConfigView(displayUUID: uuid, displayName: name)
      } else {
        unknownState
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  /// Shown when the master "Use per-display settings" toggle
  /// in the Displays tab is off.
  private var offState: some View {
    Form {
      Section("Per-display settings are off") {
        Text("Turn on per-display settings to give each connected monitor its own centering, aspect, clock placement, and marker list. The settings on the other tabs become the global defaults that every display inherits unless you override them here.")
          .font(.callout)
          .foregroundStyle(.secondary)
        Button("Enable per-display settings") {
          store.config.perDisplayEnabled = true
        }
      }
    }
    .formStyle(.grouped)
  }

  /// Fallback when we can't figure out which display Settings
  /// is on (very rare — usually only during the moment between
  /// window-creation and AppKit posting `windowDidChangeScreen`).
  private var unknownState: some View {
    Form {
      Section {
        Text("Move the Settings window onto the display you want to configure. This tab targets whichever screen Settings is currently on.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }

  /// Resolve a display UUID back to a human name (the
  /// `localizedName` of the matching `NSScreen`). Returns nil
  /// when the display has been unplugged while Settings is
  /// open — caller falls through to `unknownState`.
  private func displayName(forUUID uuid: String) -> String? {
    NSScreen.screens.first(where: {
      DisplayIdentity.uuidString(of: $0) == uuid
    })?.localizedName
  }
}

// MARK: – Schedule tab

private struct ScheduleSettingsTab: View {
  @EnvironmentObject var store: ConfigStore

  // Local mirror so the slider's continuous drag doesn't fire a
  // ConfigStore.persist() on every frame; we sync on release.
  @State private var intervalSeconds: Double = 300

  var body: some View {
    Form {
      Section("Refresh cadence") {
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Slider(value: $intervalSeconds, in: 60...3600, step: 60)
              .onChange(of: intervalSeconds) { new in
                store.config.updateInterval = Int(new)
              }
            Text(intervalLabel(seconds: Int(intervalSeconds)))
              .monospacedDigit()
              .frame(width: 80, alignment: .trailing)
          }
          Text("How often the wallpaper is re-rendered. The map's underlying motion is much slower than this — 5 minutes is overkill for visible change. Faster intervals cost more battery and SSD writes.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Toggle("Paused", isOn: $store.config.paused)
      }

      Section("Login") {
        Toggle("Launch at startup", isOn: $store.config.launchAtStartup)
        Text("Adds GeoClockWallpaper to your macOS Login Items so it starts automatically when you sign in. You can also revoke this from System Settings → General → Login Items.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section {
        Button("Reset all settings to defaults", role: .destructive) {
          store.resetToDefaults()
          intervalSeconds = Double(store.config.updateInterval)
        }
      }
    }
    .formStyle(.grouped)
    .onAppear {
      intervalSeconds = Double(store.config.updateInterval)
    }
  }

  private func intervalLabel(seconds: Int) -> String {
    if seconds < 60 { return "\(seconds) s" }
    let minutes = seconds / 60
    return minutes == 1 ? "1 min" : "\(minutes) min"
  }
}

// MARK: – Color picker that round-trips through hex

/// SwiftUI `ColorPicker` wrapped to read/write a hex-string
/// `Binding`. The model layer stores colors as `#RRGGBB` strings
/// because that's what the card config expects; the user shouldn't
/// see hex unless they want to.
///
/// Empty `hex` strings render the picker showing the supplied
/// `placeholder` color (defaulting to gray), and committing a
/// new color writes a non-empty hex back into the binding. To
/// clear a color back to "inherit from default" the user can
/// option-click — handled by an explicit reset gesture on the
/// label if/when we surface one.
struct HexColorPicker: View {
  let title: String
  @Binding var hex: String
  var placeholder: String = "#808080"

  var body: some View {
    HStack(spacing: 6) {
      if !title.isEmpty {
        Text(title)
      }
      ColorPicker(
        "",
        selection: Binding(
          get: { Color(hex: hex.isEmpty ? placeholder : hex) ?? .gray },
          set: { hex = $0.toHex() ?? hex }
        ),
        supportsOpacity: false
      )
      .labelsHidden()
      .frame(width: 44)
    }
  }
}

// MARK: – Color ↔ hex helpers

extension Color {
  /// Parse `#RRGGBB` / `#RRGGBBAA` / `RRGGBB`. Returns nil for
  /// anything else — caller falls back to a default.
  init?(hex: String) {
    var s = hex.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6 || s.count == 8,
          let v = UInt64(s, radix: 16)
    else { return nil }
    let r, g, b, a: Double
    if s.count == 8 {
      r = Double((v & 0xFF00_0000) >> 24) / 255
      g = Double((v & 0x00FF_0000) >> 16) / 255
      b = Double((v & 0x0000_FF00) >> 8) / 255
      a = Double( v & 0x0000_00FF       ) / 255
    } else {
      r = Double((v & 0xFF0000) >> 16) / 255
      g = Double((v & 0x00FF00) >> 8) / 255
      b = Double( v & 0x0000FF       ) / 255
      a = 1
    }
    self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
  }

  /// Convert to `#RRGGBB`. NSColor round-trip because SwiftUI
  /// Color doesn't expose its components directly on pre-macOS
  /// 14. Returns nil on weird color spaces we can't quantize.
  func toHex() -> String? {
    let ns = NSColor(self).usingColorSpace(.sRGB)
    guard let ns = ns else { return nil }
    let r = Int((ns.redComponent * 255).rounded())
    let g = Int((ns.greenComponent * 255).rounded())
    let b = Int((ns.blueComponent * 255).rounded())
    return String(format: "#%02X%02X%02X", r, g, b)
  }
}
