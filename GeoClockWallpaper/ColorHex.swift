import AppKit
import SwiftUI

/// Hex <-> Color helpers shared by the Settings UI and the overlay
/// (marker/clock colors are stored as hex strings in the config).
/// Lives in its own file because both the app and the GeoClockSaver
/// screensaver target compile it.
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
