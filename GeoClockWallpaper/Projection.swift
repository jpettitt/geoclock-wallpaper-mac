import CoreGraphics
import Foundation

/// Two-stage projection used by the overlay layer to place
/// markers and the clock at the same on-screen position the
/// wallpaper image renders them at.
///
///   Stage 1  (lat, lon, centerLon) → viewBox px
///   Stage 2a viewBox px            → image px (the canvas the
///                                    JS rendered into)
///   Stage 2b image px              → screen px (translate +
///                                    scale by image-on-screen
///                                    placement)
///
/// Splitting Stage 2 into two halves keeps the geometry honest:
/// everything is expressed in the same coordinate space as the
/// pixels the user actually sees, by computing inside the image
/// canvas first (where we know exactly what the page laid out)
/// and only at the end mapping into screen space. The previous
/// single-stage version conflated image-internal padding with
/// screen-origin offsets and got latitude wrong by the
/// menu-bar height.
///
/// Pure functions, no state — the overlay view re-projects on
/// every redraw using the current state's snapshot of inputs.
enum Projection {

  /// Card viewBox constants — must match the SVG the card
  /// emits. If the card's MAP_W / MAP_H / BAND_H ever change,
  /// these have to follow.
  static let mapW: Double = 2048
  static let mapH: Double = 1024
  static let bandH: Double = 44

  /// viewBox y origin and total height depend on whether the
  /// hour band is being rendered. With the band on the card
  /// emits `viewBox="0 -44 2048 1068"`; with it off it shrinks
  /// to `viewBox="0 0 2048 1024"`. Stage 2 has to match the
  /// SVG the user is actually seeing — otherwise latitude
  /// shifts by half the band height.
  static func yMin(bandVisible: Bool) -> Double {
    bandVisible ? -bandH : 0
  }
  static func totalH(bandVisible: Bool) -> Double {
    bandVisible ? mapH + bandH : mapH
  }

  /// Stage 1: lat/lon to viewBox pixel.
  /// Mirrors `latLonToPx` from projection.ts.
  static func viewBoxPoint(
    lat: Double, lon: Double, centerLon: Double
  ) -> (x: Double, y: Double) {
    let leftEdgeLon = centerLon - 180
    var lonE = (lon - leftEdgeLon).truncatingRemainder(dividingBy: 360)
    if lonE < 0 { lonE += 360 }
    let x = (lonE / 360) * mapW
    let y = ((90 - lat) / 180) * mapH
    return (x, y)
  }

  /// Inputs for Stage 2.
  ///
  /// `imageSize` is the size of the bitmap the WebKit snapshot
  /// produced — the canvas the SVG was laid out in. The body
  /// of the wallpaper page reserves `menuBarHeight` pixels of
  /// padding at the top of that canvas; the map fills the
  /// remainder according to the user's aspect-fit choice.
  ///
  /// `screen` is the size of the overlay window in points.
  /// The image is painted into the window at top-left origin
  /// and scaled to fit per-axis (aspect is preserved by the
  /// renderer's `renderSize`, so per-axis ≈ uniform).
  struct ScreenContext {
    let screen: CGSize
    let imageSize: CGSize
    let aspect: AspectFit
    let menuBarHeight: Double
    /// Whether the card is rendering the hour band at the top
    /// of the map. Determines the SVG's viewBox y range.
    let bandVisible: Bool
  }

  /// Rectangle in the image canvas (Stage 2a) or in screen
  /// coords (Stage 2b after `paintedRect`). Origin is top-left
  /// of whichever canvas the rect belongs to.
  struct PaintedRect {
    let x: Double
    let y: Double
    let w: Double
    let h: Double
  }

  /// Stage 2a — rectangle (in image pixels) the map actually
  /// paints into. The wallpaper page CSS reserves
  /// `menuBarHeight` of padding at the top of the body, and
  /// inside the remaining area the SVG honours
  /// `preserveAspectRatio` for the chosen aspect-fit mode.
  ///
  /// Returned in image coordinates, NOT screen coordinates —
  /// caller composes that with `imageToScreen` to land in the
  /// overlay window's space.
  static func paintedRectInImage(_ ctx: ScreenContext) -> PaintedRect? {
    let imgW = Double(ctx.imageSize.width)
    let imgH = Double(ctx.imageSize.height)
    let topPad = ctx.menuBarHeight
    let effW = imgW
    let effH = imgH - topPad
    guard effW > 0, effH > 0 else { return nil }
    let totalHv = totalH(bandVisible: ctx.bandVisible)
    switch ctx.aspect {
    case .stretch:
      return PaintedRect(x: 0, y: topPad, w: effW, h: effH)
    case .letterbox:
      let scale = min(effW / mapW, effH / totalHv)
      let w = mapW * scale
      let h = totalHv * scale
      return PaintedRect(
        x: (effW - w) / 2,
        y: topPad + (effH - h) / 2,
        w: w, h: h
      )
    case .cropOverflow:
      let scale = max(effW / mapW, effH / totalHv)
      let w = mapW * scale
      let h = totalHv * scale
      return PaintedRect(
        x: (effW - w) / 2,
        y: topPad + (effH - h) / 2,
        w: w, h: h
      )
    }
  }

  /// Transform an image-canvas point to a screen point. The
  /// image is painted into the overlay window at origin (0, 0)
  /// (see `OverlayView.wallpaperBackground`) and scaled so that
  /// `imageSize` covers `screen`. Aspect ratios are preserved
  /// by the renderer's `renderSize` heuristic, so the per-axis
  /// scales agree to within rounding; using each axis's own
  /// scale keeps the math exact either way.
  static func imageToScreen(
    _ pt: (x: Double, y: Double),
    in ctx: ScreenContext
  ) -> CGPoint {
    let sx = Double(ctx.screen.width) / Double(ctx.imageSize.width)
    let sy = Double(ctx.screen.height) / Double(ctx.imageSize.height)
    return CGPoint(x: pt.x * sx, y: pt.y * sy)
  }

  /// Stage 2b — painted rect mapped from image space onto the
  /// overlay window. This is what the debug grid and any
  /// overlay element wanting "the rect of the rendered map on
  /// screen" should use.
  static func paintedRect(in ctx: ScreenContext) -> PaintedRect? {
    guard let img = paintedRectInImage(ctx) else { return nil }
    let sx = Double(ctx.screen.width) / Double(ctx.imageSize.width)
    let sy = Double(ctx.screen.height) / Double(ctx.imageSize.height)
    return PaintedRect(
      x: img.x * sx,
      y: img.y * sy,
      w: img.w * sx,
      h: img.h * sy
    )
  }

  /// Stage 2: viewBox px → screen px.
  ///
  /// Returns nil when the point projects outside the visible
  /// screen rect (e.g. crop-overflow clipping a polar latitude
  /// on an ultrawide). Caller skips rendering for those.
  static func screenPoint(
    viewBoxPoint vb: (x: Double, y: Double),
    in ctx: ScreenContext
  ) -> CGPoint? {
    guard let imgRect = paintedRectInImage(ctx) else { return nil }
    // Normalise viewBox to [0, 1] on both axes. y is offset by
    // yMin so the visible region — hour band at top (when on)
    // through map bottom — maps to a continuous 0…1 range.
    let yMinV = yMin(bandVisible: ctx.bandVisible)
    let totalHv = totalH(bandVisible: ctx.bandVisible)
    let normX = vb.x / mapW
    let normY = (vb.y - yMinV) / totalHv

    // Step 2a: place inside the image canvas.
    let imgX = imgRect.x + normX * imgRect.w
    let imgY = imgRect.y + normY * imgRect.h

    // Step 2b: image → screen.
    let screenPt = imageToScreen((x: imgX, y: imgY), in: ctx)

    // Clip: if the marker projects outside the screen we don't
    // render it. The wallpaper image would have cropped it too.
    guard
      screenPt.x >= 0, screenPt.x <= Double(ctx.screen.width),
      screenPt.y >= 0, screenPt.y <= Double(ctx.screen.height)
    else { return nil }
    return screenPt
  }

  /// Convenience wrapper for the common case: lat/lon directly
  /// to screen px in one call.
  static func screenPoint(
    lat: Double, lon: Double,
    centerLon: Double,
    in ctx: ScreenContext
  ) -> CGPoint? {
    let vb = viewBoxPoint(lat: lat, lon: lon, centerLon: centerLon)
    return screenPoint(viewBoxPoint: vb, in: ctx)
  }
}
