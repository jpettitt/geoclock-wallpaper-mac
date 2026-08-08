import AppKit
import CoreLocation

/// Publishes each display's rendered map frame plus the overlay
/// config to /Users/Shared/GeoClockWallpaper/ so the GeoClock
/// screensaver can composite the same map + live clock/marker
/// overlay without a web engine of its own.
///
/// Why /Users/Shared: the saver runs inside Apple's sandboxed
/// legacyScreenSaver host, whose entitlements grant read-only access
/// to the whole filesystem EXCEPT TCC-protected locations — and
/// other apps' sandbox containers are TCC-protected, so the saver
/// cannot read this app's own Application Support. /Users/Shared is
/// world-readable, not TCC-protected, and this (sandboxed) app may
/// write to it via a temporary-exception entitlement in project.yml.
///
/// Shared types/paths live in SaverShared.swift (compiled into both
/// targets). All writes are atomic + best-effort: wallpaper
/// rendering must never fail because the shared dir is unwritable.
enum SaverFrameExporter {

  static func exportConfig(
    _ config: WallpaperConfig,
    homeCoordinate: CLLocationCoordinate2D?
  ) {
    let payload = SaverShared.SaverConfig(
      exportedAt: Date(),
      config: config,
      homeLatitude: homeCoordinate?.latitude,
      homeLongitude: homeCoordinate?.longitude)
    do {
      try FileManager.default.createDirectory(
        at: SaverShared.framesDir, withIntermediateDirectories: true)
      try SaverShared.makeEncoder().encode(payload)
        .write(to: SaverShared.configURL, options: .atomic)
    } catch {
      Diagnostics.log("saver export: config write failed — \(error)")
    }
  }

  static func exportFrame(
    _ output: WallpaperRenderer.RenderOutput,
    displayUUID: String,
    centerLon: Double
  ) {
    do {
      try FileManager.default.createDirectory(
        at: SaverShared.framesDir, withIntermediateDirectories: true)
      let png = SaverShared.frameURL(forDisplayUUID: displayUUID)
      if let src = output.fileURL {
        // The renderer already wrote the PNG once — copy bytes
        // instead of re-encoding the NSImage (which costs a full
        // TIFF round-trip per display per refresh).
        let tmp = SaverShared.framesDir
          .appendingPathComponent(".\(displayUUID).png.tmp")
        try? FileManager.default.removeItem(at: tmp)
        try FileManager.default.copyItem(at: src, to: tmp)
        _ = try FileManager.default.replaceItemAt(png, withItemAt: tmp)
      } else if
        let tiff = output.image.tiffRepresentation,
        let rep = NSBitmapImageRep(data: tiff),
        let data = rep.representation(using: .png, properties: [:]) {
        try data.write(to: png, options: .atomic)
      }
      let meta = SaverShared.SaverFrameMeta(
        centerLon: centerLon,
        renderedAt: Date(),
        pixelWidth: Double(output.image.size.width),
        pixelHeight: Double(output.image.size.height))
      try SaverShared.makeEncoder().encode(meta).write(
        to: SaverShared.frameMetaURL(forDisplayUUID: displayUUID),
        options: .atomic)
    } catch {
      Diagnostics.log("saver export: frame write failed — \(error)")
    }
  }

  /// Remove the shared directory when the user turns the feature
  /// off — the whole point of the toggle is "stop leaving frames
  /// in a world-readable location".
  static func removeAll() {
    guard FileManager.default.fileExists(atPath: SaverShared.root.path)
    else { return }
    do {
      try FileManager.default.removeItem(at: SaverShared.root)
    } catch {
      Diagnostics.log("saver export: cleanup failed — \(error)")
    }
  }
}
