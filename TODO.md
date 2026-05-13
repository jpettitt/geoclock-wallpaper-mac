# TODO

Living plan for the wallpaper app. We iterate on this until it
matches what we actually want to ship, then start picking items.

Status legend:
  ⏳  pending — not started
  🛠   in progress
  ✅  done (kept here briefly so the next steps make sense)

Priority bands are about ordering, not blockers — none of this is
locked in yet.

## ✅ Done so far

- Project scaffold (XcodeGen, SwiftUI, sandbox, GPL-3.0).
- Menu-bar status item + Refresh / Pause / Settings / Quit menu.
- Offscreen WKWebView render pipeline + `geoclock-app://`
  URL scheme handler that resolves to `Bundle.main/WebAssets/`.
  All web assets ship inside the .app; no network at render time.
- WallpaperApplier (`NSWorkspace.setDesktopImageURL` on every
  `NSScreen`).
- Scheduler: configurable interval (60–3600 s), pause/resume,
  wake-from-sleep observer.
- ConfigStore + Settings pane (slider, TZ field, raw JSON
  editor) wired via Combine.
- App icon (rendered from a single SVG into the seven sizes
  Apple's asset catalog wants).

---

## Must-have for a first release

### Distribution

- ⏳ **Codesigning with Developer ID.** Pass
  `DEVELOPMENT_TEAM=…` via xcconfig so the existing build works
  without hand-editing Xcode's Signing & Capabilities tab.
- ⏳ **Notarization.** `xcrun notarytool submit` + `stapler`.
  GitHub Actions workflow that takes a signed archive and ships
  a notarized one out the other side.
- ⏳ **DMG packaging.** `create-dmg` (or hand-rolled) with a
  background image telling users to drag the app into
  `/Applications`.
- ⏳ **Update channel.** Sparkle 2.x is the standard. Server-
  side is a static `appcast.xml` on R2 next to the DMG. Decide
  early because it shapes the bundle (`SUPublicEDKey`
  entitlement, Info.plist keys).

### Behavior polish

- ⏳ **Launch at login** via `SMAppService.mainApp`. Toggle in
  Settings; default off so first-launch users see a deliberate
  opt-in.
- ⏳ **Pause on sleep / screensaver; refresh on wake.** Hook
  `NSWorkspace.willSleepNotification` and
  `NSWorkspace.screensaverDidStartNotification` to stop the
  timer; `didWakeNotification` (already wired) and
  `screensaverDidStopNotification` fire an immediate render and
  then resume the regular cadence.
- ⏳ **Aspect-fit options.** The bundled wallpaper page
  currently uses `preserveAspectRatio="xMidYMid slice"` (crop-
  to-fill). Expose the three useful modes in Settings:
  - **Stretch** — distort map to fully fill screen.
  - **Letterbox** — preserve aspect, black bars where needed.
  - **Crop overflow** — preserve aspect, crop spillover
    (current behaviour, sensible default).

  Setter flips a CSS class or `viewBox` flag on the bundled
  page; no card change required.
- ⏳ **Center mode resolution chain.** Default order:
  1. **My location** — Core Location permission. Returns
     lat/lon every render, so a moving Mac follows along.
  2. **Time-zone guess** — when Core Location is denied or
     unavailable, look up the centroid of the system's IANA
     zone and use that. Crude but always available.
  3. **Manual lat/lon** — user-entered, persisted in
     UserDefaults.
  4. **Sun** — subsolar drift; same as the live demo's default.

  Editable in Settings; UI shows which fallback is active so
  users denying Location understand what the app picked.
- ⏳ **Native resolution detection.** Right now the renderer
  uses a fixed 5120 × 2880. Query `NSScreen.main?.frame` (or
  iterate displays) and pick the largest backing-store pixel
  size so 6K Pro Display owners get a sharp render and 1080p
  laptops aren't paying for 5K-worth of GPU work.
- ⏳ **Apply on display reconfiguration.** Subscribe to
  `NSApplication.didChangeScreenParametersNotification` and
  re-apply on display attach / detach.
- ⏳ **Active Space change re-apply.** macOS sometimes loses
  the wallpaper on Space switch. Hook
  `NSWorkspace.activeSpaceDidChangeNotification`.

### UX

- ⏳ **Structured marker editor.** Raw JSON in Settings is
  error-prone. Build a `List` of marker rows: entity (or
  inline-coord) picker, label, color well. Serialize back
  into the JSON config blob on save. Each row also shows a
  **visibility hint** so the user catches "this marker is
  never going to be on my screen" before saving:
  - **Cropped in current aspect.** In crop-overflow mode at
    certain screen aspects, some lat/lon points always
    project outside the screen rect (e.g., polar latitudes on
    ultrawide displays, or extreme east/west longitudes on
    4:3 displays under a fixed centering mode). When a marker
    falls in that always-cropped band, surface a row-level
    warning: "Outside the visible area in Crop Overflow on
    this display. Switch to Letterbox or move the marker."
  - **Partially visible in Sun mode.** When `center: sun`,
    centerLon drifts westward over each 24-hour cycle, so a
    marker may be on-screen for some hours and off-screen
    for others. Compute the visible longitude window for the
    current aspect/screen combo and convert it into a
    UTC-time-of-day window (`centerLon = -15·(t−12) − EoT`).
    Show "Visible roughly HH:MM–HH:MM UTC each day" as a
    sub-line. If the window is empty, escalate the row to
    the same warning style as the static-mode case.

  Both checks re-run when the user changes aspect mode,
  center mode, or moves the marker — visibility hints stay
  honest as Settings is edited.
- ⏳ **Last-render indicator in the menu bar.** Show
  "Refreshed 3 min ago" as a disabled menu item, plus a red
  dot on the status icon when the previous render failed.
- ⏳ **Visual preview in Settings.** Embed a small WKWebView at
  ~320×167 next to the form, mirroring the current config, so
  the user can see their changes before committing.

---

## Should-have

### Behavior

- ⏳ **Pause on battery.** Toggle in Settings; default off.
  Uses `IOPSCopyPowerSourcesInfo` to detect AC vs battery.
- ⏳ **Quiet hours.** Optional schedule window during which
  refreshes pause (e.g., 11 PM – 7 AM).
- ⏳ **Per-display config.** Different center longitude / TZ
  per monitor. Useful for the multi-monitor wall display case
  (one display showing "office" time, another showing "home").

### Reliability

- ⏳ **Retry on render failure.** Currently we log + wait for
  the next timer tick. Add exponential backoff for the case
  where the WKWebView fails mid-snapshot (transient WebKit
  crash, OOM, etc.).
- ⏳ **WebKit process lifecycle audit.** Confirm the WebContent
  process gets torn down between renders. If not, recycle it
  every N renders to bound memory.
- ⏳ **Idle-detect.** Skip a render cycle if the user hasn't
  touched the input devices in a long time AND the display is
  asleep (a no-op render saves battery).

### Tests

- ⏳ **ConfigStore unit tests.** Round-trip a config blob
  through `buildWallpaperPayload()` and assert markers, tz,
  intervals come out correct.
- ⏳ **BundledAssetHandler tests.** Mock `Bundle` to point at a
  test directory; assert 200/404 and content-type for the
  common paths.
- ⏳ **CI workflow.** macOS GitHub Actions runner builds
  Debug + Release on every push.

---

## Could-have

- ⏳ **Live overlay layer (transparent NSWindow at desktop
  level).** A single Swift-owned layer that draws every
  user-customizable element on top of the wallpaper PNG, so
  marker styling, clock precision, and label visibility can
  all be edited in Settings and reflected instantly without
  paying the wallpaper-redraw tax. Architecture:
  - One transparent, mouse-ignoring NSWindow per `NSScreen`,
    placed at `CGWindowLevelForKey(.desktopWindow)` — above
    the wallpaper, below user apps.
  - `collectionBehavior = [.canJoinAllSpaces, .stationary]`
    so it follows the user between Spaces; fullscreen apps
    correctly cover it.
  - Hosts a SwiftUI view that draws everything time- or
    user-configured:
    - main clock readout at the card's bottom-left position
      (HH:MM:SS + optional UTC line);
    - **all** markers — home marker + each configured
      location marker — as a `Circle` (the dot), a larger
      semi-transparent `Circle` (the halo), and a `Text`
      stack (name + live local time). Color, dot size, label
      font/size are app-side state.
  - 1 Hz `Timer.publish(every: 1)` re-renders the view. Cost
    ≈ 0% CPU.
  - Hide the card's in-map clock + marker rendering by
    injecting CSS into the bundled wallpaper page so the
    overlay owns the whole layer cleanly:
    `.local-time, .utc-time, .marker { display: none; }`
    (the `.marker` class wraps the entire dot+halo+text DOM
    block — see geo-clock-card.ts CSS).
  - Marker positioning needs the resolved `centerLon` and
    the same projection the card uses. Two options:
    - port the ~10-line `latLonToPx` to Swift, plus the
      subsolar-point math (~30 lines) for sun-centered mode,
      then compute centerLon and marker pixel positions
      app-side; or
    - have the wallpaper page postMessage `{ centerLon }`
      after layout (we already use `geoclockReady` for the
      snapshot trigger — adding `geoclockState` is one line
      in the page), and reuse a small Swift port of just
      `latLonToPx` to convert centerLon + (lat, lon) →
      pixel position.

    The second option keeps the subsolar math single-sourced
    in the card. Lean that way unless we end up wanting
    Swift-side scrubbing previews.
  - Hides automatically at lock screen / display sleep
    (because `NSWindow` already does).

  **Positioning math.** Marker placement is a two-stage
  transform; both stages need to be live and re-evaluated on
  the right events:
  1. `(lat, lon, centerLon)` → viewBox pixel (the card's
     2048 × 1068 coordinate space). `latLonToPx` from the
     card, ported to Swift.
  2. viewBox pixel → screen pixel — depends on which display
     and on the user's aspect-fit setting:
     - **Stretch** — `scaleX = screenW / 2048; scaleY = screenH / 1068`;
       distort. Marker x → `x * scaleX`, y → `y * scaleY`.
     - **Letterbox** — `scale = min(screenW / 2048, screenH / 1068)`;
       letterbox. Offset `(screenW - 2048*scale)/2,
       (screenH - 1068*scale)/2`. Marker → `offset + pt * scale`.
     - **Crop overflow** — `scale = max(...)`; crop. Same
       offset math, just negative on one axis. Markers that
       project outside the screen rect are hidden.

  Re-projection triggers (any of these → recompute every
  overlay element's screen position and redraw):
  - Wallpaper render cycle published a new `centerLon` (sun
    mode drifts every 5 min; manual / my-location modes only
    change when the user moves or edits the config).
  - `NSApplication.didChangeScreenParametersNotification` —
    display added/removed/resized, scale factor changed.
  - User changed aspect-fit mode in Settings.
  - User edited the marker list (add/remove/relocate).
  - User changed center mode (re-triggers a wallpaper render
    which then republishes centerLon).

  The overlay layer keeps a single observable "layout state"
  struct (`centerLon`, `aspectMode`, `[NSScreen: CGSize]`)
  and the SwiftUI view recomputes positions from it on every
  re-render. Cheap because there are at most a handful of
  markers per display.

  Side benefits of moving markers fully to the overlay:
  - Per-marker color picker in Settings is trivial
    (`SwiftUI.ColorPicker`).
  - Marker times can show seconds without any extra cost.
  - Live-edited markers reflect immediately (no wallpaper
    re-render needed to add/remove/recolor a pin).

  Edge cases: per-display positioning, screen reconfiguration,
  matching the card's font / shadow style so the overlay
  visuals look continuous with the map underneath.

- ⏳ **Image post-processing.** Optional Core Image filters —
  blur, vignette, color shift — for users who want a more
  stylized look.
- ⏳ **Lock screen / login window background.** Different API
  (`com.apple.desktop`), separate scope, may need separate
  helper app.
- ⏳ **Screen saver target.** Spin off a `.saver` bundle that
  uses the same WKWebView pipeline.
- ⏳ **Focus-mode integration.** Different config per macOS
  Focus (Work / Personal / Sleep).
- ⏳ **Homebrew cask submission** for `brew install --cask
  geoclock-wallpaper`.

---

## Won't-do (decided to scope out)

- *(none yet — add things here when we decide against them so
  the next person doesn't re-propose them)*

---

## Open questions

- ✅ **Distribution: Developer ID + DMG.** No App Store for v1.
  Re-evaluate after we ship and see if discoverability matters
  enough to justify the sandbox tightening.
- **What does "Pause" actually do?** Stop the timer, or also
  revert the wallpaper to whatever was there before? The latter
  needs us to capture the original wallpaper URL on first
  launch and store it.
- **Sparkle public key + appcast signing infrastructure.**
  Where does the EdDSA private key live? `op://`, 1Password
  vault, or a separate offline signing machine?
