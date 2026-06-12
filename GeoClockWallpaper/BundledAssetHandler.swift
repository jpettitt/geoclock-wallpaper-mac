import Foundation
import WebKit
import UniformTypeIdentifiers

/// `WKURLSchemeHandler` that serves the bundled WebAssets folder
/// from the app's Resources directory over a custom URL scheme
/// (`geoclock-app://`).
///
/// Why a custom scheme and not `file://`:
/// - `file://` has tricky CORS / module-loading behavior in
///   WebKit. Same-origin policy treats every `file://` URL as a
///   unique origin, which breaks `<script type="module">` in
///   ways that depend on the WebKit build. A custom scheme is a
///   single origin we control.
/// - Custom schemes also let us serve from anywhere — if a future
///   version downloads asset updates into Application Support and
///   wants to layer them over the bundle, the handler just
///   changes its lookup logic; the page itself doesn't know.
///
/// URL shape: `geoclock-app:///wallpaper.html`
/// (three slashes — empty host, absolute path).
///
/// The host is empty by convention; the path's leading slash maps
/// to the root of `Bundle.main`'s `WebAssets` folder.
final class BundledAssetHandler: NSObject, WKURLSchemeHandler {

  /// Registered scheme name. Must match the URL passed to
  /// `WKWebView.load(URLRequest(url:))`.
  static let scheme = "geoclock-app"

  /// Subdirectory inside `Contents/Resources/` that holds the
  /// synced web assets. Must match the folder-reference name in
  /// `project.yml`.
  private static let bundleSubpath = "WebAssets"

  func webView(
    _ webView: WKWebView,
    start urlSchemeTask: any WKURLSchemeTask
  ) {
    guard
      let url = urlSchemeTask.request.url,
      url.scheme == Self.scheme
    else {
      urlSchemeTask.didFailWithError(SchemeError.unsupportedURL)
      return
    }

    // Resolve the path component against the bundled WebAssets
    // directory. URL.path strips the leading slash; we prepend
    // the bundle subpath. Default to wallpaper.html when the URL
    // points at the root.
    var relativePath = url.path
    if relativePath.isEmpty || relativePath == "/" {
      relativePath = "/wallpaper.html"
    }
    let trimmed = String(relativePath.drop(while: { $0 == "/" }))

    // Refuse traversal segments outright. Only the bundled,
    // trusted page runs in this web view and the sandbox caps
    // reads anyway, but there's no legitimate reason for a
    // geoclock-app:// URL to contain ".." and CFBundle would
    // happily resolve a composed path outside WebAssets/.
    guard !trimmed.split(separator: "/").contains("..") else {
      urlSchemeTask.didFailWithError(SchemeError.unsupportedURL)
      return
    }

    guard
      let fileURL = Bundle.main.url(
        forResource: trimmed,
        withExtension: nil,
        subdirectory: Self.bundleSubpath
      )
    else {
      // Surface a 404 so the page sees a real HTTP-shaped failure
      // and not a silently-empty body — much easier to debug.
      let response = HTTPURLResponse(
        url: url,
        statusCode: 404,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "text/plain; charset=utf-8"]
      )!
      let body = "404 Not Found: \(trimmed)\n".data(using: .utf8)!
      urlSchemeTask.didReceive(response)
      urlSchemeTask.didReceive(body)
      urlSchemeTask.didFinish()
      return
    }

    do {
      let data = try Data(contentsOf: fileURL)
      let mimeType = Self.mimeType(for: fileURL)
      let response = HTTPURLResponse(
        url: url,
        statusCode: 200,
        httpVersion: "HTTP/1.1",
        headerFields: [
          "Content-Type": mimeType,
          "Content-Length": "\(data.count)",
          // Long cache: bundled assets never change at runtime
          // (the only way they update is a new app build). Telling
          // WebKit to cache aggressively cuts re-reads on each
          // render cycle.
          "Cache-Control": "public, max-age=31536000, immutable",
        ]
      )!
      urlSchemeTask.didReceive(response)
      urlSchemeTask.didReceive(data)
      urlSchemeTask.didFinish()
    } catch {
      urlSchemeTask.didFailWithError(error)
    }
  }

  func webView(
    _ webView: WKWebView,
    stop urlSchemeTask: any WKURLSchemeTask
  ) {
    // No long-running work to cancel — we read each file
    // synchronously inside `start(_:)`. Nothing to do.
  }

  // MARK: – Helpers

  /// Map a file URL to a MIME type. UniformTypeIdentifiers gives
  /// us native ext→mime for the common ones; we hard-code a few
  /// where UTType returns something unhelpful (or nothing) for
  /// our specific shipped files.
  private static func mimeType(for fileURL: URL) -> String {
    let ext = fileURL.pathExtension.lowercased()
    switch ext {
    case "html", "htm": return "text/html; charset=utf-8"
    case "js":          return "application/javascript; charset=utf-8"
    case "json":        return "application/json; charset=utf-8"
    case "css":         return "text/css; charset=utf-8"
    case "svg":         return "image/svg+xml"
    case "jpg", "jpeg": return "image/jpeg"
    case "png":         return "image/png"
    case "ico":         return "image/x-icon"
    default:
      // Fall back to UTType inference for anything we forgot.
      if let utType = UTType(filenameExtension: ext),
         let mime = utType.preferredMIMEType
      {
        return mime
      }
      return "application/octet-stream"
    }
  }

  private enum SchemeError: Error {
    case unsupportedURL
  }
}
