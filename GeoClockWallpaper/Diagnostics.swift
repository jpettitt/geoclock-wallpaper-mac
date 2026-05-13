import Foundation

/// Append-only diagnostic log file. NSLog reliably reaches the
/// unified log but querying it after the fact from outside the
/// sandbox is awkward (apps launched via `open` get their stdio
/// stripped from `log show` predicates in some configurations).
/// A flat file inside the app's Application Support folder is
/// always reachable from Terminal — `tail -f
/// ~/Library/Containers/world.geoclock.wallpaper/Data/Library/
/// Application\ Support/GeoClockWallpaper/debug.log` shows
/// everything in real time.
///
/// Volume: a handful of lines per render cycle, ~150 bytes each.
/// We don't rotate; users running into bloat can just delete the
/// file (it'll be recreated on next write).
enum Diagnostics {
  /// Write a single line, prefixed with the current timestamp,
  /// to debug.log. Best-effort — failures are silent so we never
  /// add diagnostic crashes on top of the bug we're hunting.
  static func log(_ message: String) {
    NSLog("GeoClockWallpaper: \(message)")  // still go to unified
                                              // log too, for users
                                              // who already have it
                                              // open in Console.app
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "\(timestamp)  \(message)\n"
    guard let data = line.data(using: .utf8),
          let url = logFileURL()
    else { return }
    if let handle = try? FileHandle(forWritingTo: url) {
      defer { try? handle.close() }
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: data)
    } else {
      // File doesn't exist yet — create + write.
      _ = try? data.write(to: url, options: .atomic)
    }
  }

  private static func logFileURL() -> URL? {
    let fm = FileManager.default
    guard let supportDir = try? fm.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    ).appendingPathComponent("GeoClockWallpaper", isDirectory: true)
    else { return nil }
    try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
    return supportDir.appendingPathComponent("debug.log")
  }
}
