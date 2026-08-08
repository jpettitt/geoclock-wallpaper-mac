import Foundation

/// Types + paths shared between the app's SaverFrameExporter (write
/// side) and the GeoClockSaver screensaver (read side). Kept free of
/// AppKit/WebKit imports so the saver target can compile this file
/// without dragging in the renderer stack.
enum SaverShared {

  static let root = URL(
    fileURLWithPath: "/Users/Shared/GeoClockWallpaper", isDirectory: true)
  static var framesDir: URL {
    root.appendingPathComponent("frames", isDirectory: true)
  }
  static var configURL: URL {
    root.appendingPathComponent("saver-config.json")
  }
  static func frameURL(forDisplayUUID uuid: String) -> URL {
    framesDir.appendingPathComponent("\(uuid).png")
  }
  static func frameMetaURL(forDisplayUUID uuid: String) -> URL {
    framesDir.appendingPathComponent("\(uuid).json")
  }

  /// Everything the saver needs beyond the frame bitmaps. The
  /// WallpaperConfig rides along verbatim so the saver can reuse
  /// OverlayState.applyConfig — one mapping, not two.
  struct SaverConfig: Codable {
    var version = 1
    var exportedAt: Date
    var config: WallpaperConfig
    var homeLatitude: Double?
    var homeLongitude: Double?
  }

  struct SaverFrameMeta: Codable {
    var centerLon: Double
    var renderedAt: Date
    var pixelWidth: Double
    var pixelHeight: Double
  }

  static func makeEncoder() -> JSONEncoder {
    let enc = JSONEncoder()
    enc.dateEncodingStrategy = .iso8601
    return enc
  }

  static func makeDecoder() -> JSONDecoder {
    let dec = JSONDecoder()
    dec.dateDecodingStrategy = .iso8601
    return dec
  }
}
