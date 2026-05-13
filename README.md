# geoclock-wallpaper-mac

A macOS menu-bar app that sets your desktop wallpaper to a live
[geoclock.world](https://geoclock.world) render, refreshed on a
timer (default every 5 minutes).

Companion to [`geo-clock-card`](https://github.com/jpettitt/geo-clock-card)
— the Home Assistant Lovelace card the live demo is built from.
This app doesn't reimplement any of the card's rendering: it loads
the existing [`/wallpaper.html`](https://geoclock.world/wallpaper.html)
in an offscreen `WKWebView`, snapshots it, and writes the result
to `NSWorkspace.setDesktopImageURL`. New card features (markers,
time-source overrides, theming) flow in for free.

## Status

Alpha — minimum-viable "first wallpaper renders on launch + every
5 min" loop. Not yet signed/notarized.

## Build

You'll need [XcodeGen](https://github.com/yonaskolb/XcodeGen) to
generate the `.xcodeproj` from `project.yml`:

```bash
brew install xcodegen
xcodegen generate
open GeoClockWallpaper.xcodeproj
```

Then in Xcode: set the development team in the target's Signing &
Capabilities tab (any free Apple ID works for local dev), select
the `GeoClockWallpaper` scheme, and ⌘R to run.

When the app launches it appears as a 🌍 in the menu bar
(no Dock icon — `LSUIElement = YES`). First wallpaper render takes
~5–10 s after the bundle and NASA imagery download from R2.

## Architecture

```text
┌───────────────────────────────────────────────────────────────┐
│  AppDelegate                                                  │
│    ├─ NSStatusItem (menu bar, no main window)                 │
│    ├─ Scheduler           Timer + wake/space notifications    │
│    └─ WallpaperRenderer   WKWebView + takeSnapshot            │
│           │                                                   │
│           └─ loads https://geoclock.world/wallpaper.html      │
│              calls window.geoclockConfigure({config, hass})   │
│              waits for `geoclockReady` script-message         │
│              snapshot → PNG → ~/Library/Application Support/  │
│                                  GeoClockWallpaper/           │
│                                                               │
│  WallpaperApplier                                             │
│    └─ NSWorkspace.setDesktopImageURL on every NSScreen        │
└───────────────────────────────────────────────────────────────┘
```

## Config

User config lives in `UserDefaults` and is editable from the
Settings window (⌘, from the menu bar). All fields are optional;
the defaults render a sun-centered map with the visitor's device
time-zone shown as the main clock.

| Key | Type | Default | Notes |
| --- | --- | --- | --- |
| `updateInterval` | seconds | `300` (5 min) | Clamped 60–3600. |
| `cardConfigJSON` | JSON string | `{"center":"sun"}` | Raw card config; markers + theming go here. See the card's [config docs](https://github.com/jpettitt/geo-clock-card#configuration). |
| `mainTimeZone` | IANA tzid | nil | If set, overrides the card's `mainTimeSource` to `home` and pins the clock to this zone. |
| `paused` | bool | `false` | Toggled from the menu bar. |

The full config object passed to `geoclockConfigure()` is built
from these fields (plus the inline-marker shortcuts the wallpaper
page exposes). See `ConfigStore.swift` for the assembly.

## Multi-monitor

When the app calls `setDesktopImageURL`, macOS gets to pick how
the image fits each display. For best results pick "Fill Screen"
under System Settings → Wallpaper for every monitor before first
launch — the image renders at 1.917:1 (the card's natural aspect),
which fills 16:9 with a tiny side-crop and 21:9 with a small
top/bottom crop.

## The "wallpaper protocol" contract

The single integration surface with the card repo:

| Surface | Form | Stability |
| --- | --- | --- |
| Page URL | `https://geoclock.world/wallpaper.html` | Stable. Owned by `geo-clock-card`. |
| JS API | `window.geoclockConfigure({ config, hass })` | Stable. Returns Promise. |
| Ready signal | `webkit.messageHandlers.geoclockReady.postMessage('ready')` | Stable. |
| Config shape | See `geo-clock-card`'s `types.ts` plus the wallpaper page's shortcuts (`mainTimeZone`, inline-coord markers) | Backward-compatible additions only. |

Changes to that contract are coordinated by updating both repos'
READMEs in lockstep.

## License

GPL-3.0-or-later. See [`LICENSE`](LICENSE).

Modified versions must be released under the same license and must
remain open-source. If you want to distribute a closed-source fork
or embed this code in proprietary software, please open an issue —
relicensing happens but only with the copyright holder's consent.
