import AppKit

/// Write access to the shared saver-frames folder
/// (/Users/Shared/GeoClockWallpaper) across both distribution
/// channels:
///
///   - Developer ID build: a temporary-exception entitlement grants
///     direct write access — silent, same as always.
///   - Mac App Store build: temporary-exception entitlements are
///     rejected in review, so access comes from the powerbox — the
///     user selects /Users/Shared in an NSOpenPanel once and we
///     persist a security-scoped bookmark.
///
/// One code path serves both: `ensureAccess()` probes for direct
/// access first (succeeds when the entitlement is present) and
/// falls back to the stored bookmark. UI calls
/// `requestAccessInteractively()` only when that returns false.
enum SaverAccess {

  /// Where the "Install screensaver…" button sends the user. A
  /// stable first-party redirect, deliberately not a pinned GitHub
  /// tag: the MAS app will lag saver releases behind review, and a
  /// baked-in tag would go stale.
  static let saverDownloadURL = URL(string: "https://geoclock.world/screensaver.html")!

  private static let bookmarkKey = "saverSharedFolderBookmark"

  /// Resolved + started security-scoped URL, held for the app's
  /// lifetime. We start once and never stop: exports run every few
  /// minutes forever and the scoped resource is a single folder,
  /// so bracketing every write buys nothing.
  private static var scopedURL: URL?

  /// Result of the one-time direct-write probe, cached so the
  /// filesystem is only poked once per launch. Must be probed
  /// BEFORE any bookmark is started — once scoped access is live,
  /// a create succeeding no longer proves the entitlement exists.
  private static var directAccessProbed: Bool?

  /// True when frames can be written right now, acquiring
  /// non-interactive access (entitlement probe, stored bookmark)
  /// as a side effect. Never shows UI.
  static func ensureAccess() -> Bool {
    if hasDirectAccess { return true }
    return resolveBookmark()
  }

  /// Ensure access, showing the powerbox panel if needed. Returns
  /// false only if the user cancelled. Main-thread only (runs a
  /// modal panel).
  @MainActor
  static func requestAccessInteractively() -> Bool {
    if ensureAccess() { return true }

    let panel = NSOpenPanel()
    panel.message = """
      The screensaver reads map frames from the shared folder \
      “Users → Shared”. Click “Grant Access” to allow GeoClock \
      Wallpaper to publish frames there.
      """
    panel.prompt = "Grant Access"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = URL(fileURLWithPath: "/Users/Shared")

    while true {
      guard panel.runModal() == .OK, let url = panel.url else {
        return false  // user cancelled
      }
      // The saver reads a FIXED path, and only a grant on
      // /Users/Shared itself survives removeAll() deleting our
      // subfolder (bookmarks are inode-based — a grant on the
      // subfolder dies with it). Anything else republishes frames
      // where the saver never looks, so loop until it's right.
      if url.standardizedFileURL.path == "/Users/Shared" {
        guard
          let data = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil),
          url.startAccessingSecurityScopedResource()
        else {
          Diagnostics.log("saver access: bookmark creation failed")
          return false
        }
        UserDefaults.standard.set(data, forKey: bookmarkKey)
        scopedURL = url
        return true
      }
      let alert = NSAlert()
      alert.messageText = "Please select the “Shared” folder"
      alert.informativeText = """
        The screensaver only looks in Users → Shared, so access \
        must be granted to that exact folder.
        """
      alert.runModal()
      panel.directoryURL = URL(fileURLWithPath: "/Users/Shared")
    }
  }

  // MARK: – Internal

  private static var hasDirectAccess: Bool {
    if let probed = directAccessProbed { return probed }
    // createDirectory(withIntermediateDirectories: true) is a
    // no-op-success when the folder exists and throws on sandbox
    // denial — exactly the probe we need, with no cleanup.
    let ok = (try? FileManager.default.createDirectory(
      at: SaverShared.framesDir,
      withIntermediateDirectories: true)) != nil
    directAccessProbed = ok
    return ok
  }

  private static func resolveBookmark() -> Bool {
    if scopedURL != nil { return true }
    guard let data = UserDefaults.standard.data(forKey: bookmarkKey)
    else { return false }
    var stale = false
    guard
      let url = try? URL(
        resolvingBookmarkData: data,
        options: .withSecurityScope,
        relativeTo: nil,
        bookmarkDataIsStale: &stale),
      url.startAccessingSecurityScopedResource()
    else {
      // Bookmark rotted (folder gone, permission reset). Drop it
      // so the Settings UI shows the grant button again instead
      // of silently no-op'ing forever.
      UserDefaults.standard.removeObject(forKey: bookmarkKey)
      Diagnostics.log("saver access: stored bookmark failed to resolve — cleared")
      return false
    }
    if stale,
       let fresh = try? url.bookmarkData(
         options: .withSecurityScope,
         includingResourceValuesForKeys: nil,
         relativeTo: nil) {
      UserDefaults.standard.set(fresh, forKey: bookmarkKey)
    }
    scopedURL = url
    return true
  }
}
