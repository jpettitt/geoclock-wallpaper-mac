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
/// Size-capped rotation: when debug.log passes ~5 MB it's moved
/// to debug.log.1 (replacing any previous one) and a fresh file
/// starts — bounded at ~10 MB total for an always-running agent.
enum Diagnostics {
  private static let queue = DispatchQueue(label: "world.geoclock.wallpaper.diagnostics")
  private static let dateFormatter = ISO8601DateFormatter()
  private static let maxLogBytes: UInt64 = 5 * 1024 * 1024

  /// Write a single line, prefixed with the current timestamp,
  /// to debug.log. Best-effort — failures are silent so we never
  /// add diagnostic crashes on top of the bug we're hunting.
  static func log(_ message: String) {
    NSLog("GeoClockWallpaper: \(message)")  // still go to unified log too

    queue.async {
      let timestamp = dateFormatter.string(from: Date())
      let line = "\(timestamp)  \(message)\n"
      guard let data = line.data(using: .utf8),
            let url = logFileURL()
      else { return }
      rotateIfNeeded(url)
      if let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
      } else {
        // File doesn't exist yet — create + write.
        _ = try? data.write(to: url, options: .atomic)
      }
    }
  }

  /// One-deep rotation, checked before each append (on the
  /// serial diagnostics queue, so no races). The size stat is a
  /// single inexpensive syscall per log line.
  private static func rotateIfNeeded(_ url: URL) {
    let fm = FileManager.default
    guard
      let attrs = try? fm.attributesOfItem(atPath: url.path),
      let size = attrs[.size] as? UInt64,
      size >= maxLogBytes
    else { return }
    let rotated = url.deletingLastPathComponent()
      .appendingPathComponent("debug.log.1")
    try? fm.removeItem(at: rotated)
    try? fm.moveItem(at: url, to: rotated)
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
