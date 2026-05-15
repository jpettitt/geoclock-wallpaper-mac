import XCTest
@testable import GeoClockWallpaper

/// Pure-function projection tests. Pinned against the math
/// described in `Projection.swift` (mirrors the card's
/// `projection.ts`); a regression here means the Swift overlay
/// and the WebKit-rendered image will disagree about where a
/// pixel lives.
final class ProjectionTests: XCTestCase {

  // MARK: – Stage 1: lat/lon → viewBox px

  func testViewBoxPoint_centerLonZero() {
    // Greenwich-centered. Lon 0 lands at the middle of the
    // viewBox; lat 0 lands at MAP_H/2.
    let pt = Projection.viewBoxPoint(lat: 0, lon: 0, centerLon: 0)
    XCTAssertEqual(pt.x, Projection.mapW / 2, accuracy: 0.01)
    XCTAssertEqual(pt.y, Projection.mapH / 2, accuracy: 0.01)
  }

  func testViewBoxPoint_centerLonMatchesPoint() {
    // When centerLon matches the queried lon, the point falls
    // on the centerline (x = mapW / 2).
    let pt = Projection.viewBoxPoint(lat: 0, lon: 45, centerLon: 45)
    XCTAssertEqual(pt.x, Projection.mapW / 2, accuracy: 0.01)
  }

  func testViewBoxPoint_seamWrap() {
    // A point one degree east of the left edge should land at
    // 1/360th of mapW past x=0, not at x=mapW (which would be
    // one full wrap).
    let pt = Projection.viewBoxPoint(lat: 0, lon: -179, centerLon: 0)
    XCTAssertEqual(pt.x, Projection.mapW * 1 / 360, accuracy: 0.5)
  }

  func testViewBoxPoint_latitudeRange() {
    // lat=90 is the north pole → y=0; lat=-90 is south → y=mapH.
    let north = Projection.viewBoxPoint(lat: 90, lon: 0, centerLon: 0)
    XCTAssertEqual(north.y, 0, accuracy: 0.01)
    let south = Projection.viewBoxPoint(lat: -90, lon: 0, centerLon: 0)
    XCTAssertEqual(south.y, Projection.mapH, accuracy: 0.01)
  }

  // MARK: – yMin / totalH

  func testYMinAndTotalHRespectBandVisibility() {
    XCTAssertEqual(Projection.yMin(bandVisible: true), -Projection.bandH)
    XCTAssertEqual(Projection.totalH(bandVisible: true),
                   Projection.mapH + Projection.bandH)
    XCTAssertEqual(Projection.yMin(bandVisible: false), 0)
    XCTAssertEqual(Projection.totalH(bandVisible: false), Projection.mapH)
  }

  // MARK: – Stage 2a: viewBox → image canvas

  /// Build a ScreenContext with the supplied aspect-fit + sizes
  /// and no menu-bar padding. Used by every stage-2 test that
  /// doesn't care about the menubar offset.
  private func ctx(
    aspect: AspectFit,
    image: CGSize,
    screen: CGSize,
    menuBar: Double = 0,
    bandVisible: Bool = true
  ) -> Projection.ScreenContext {
    Projection.ScreenContext(
      screen: screen,
      imageSize: image,
      aspect: aspect,
      menuBarHeight: menuBar,
      bandVisible: bandVisible)
  }

  func testPaintedRect_stretchFillsImage() {
    // Stretch ignores aspect and fills the canvas, offset by
    // the menu-bar padding at the top.
    let rect = Projection.paintedRectInImage(
      ctx(aspect: .stretch,
          image: CGSize(width: 2048, height: 1324),
          screen: CGSize(width: 2048, height: 1324),
          menuBar: 38))!
    XCTAssertEqual(rect.x, 0, accuracy: 0.01)
    XCTAssertEqual(rect.y, 38, accuracy: 0.01)
    XCTAssertEqual(rect.w, 2048, accuracy: 0.01)
    XCTAssertEqual(rect.h, 1324 - 38, accuracy: 0.01)
  }

  func testPaintedRect_letterboxNarrowsByConstrainingAxis() {
    // 21:9 screen, viewBox aspect 1.917 — meet picks the
    // smaller axis (width) so we end up with side bars.
    let image = CGSize(width: 2048, height: 857)
    let rect = Projection.paintedRectInImage(
      ctx(aspect: .letterbox,
          image: image, screen: image))!
    let scale = min(2048 / Projection.mapW,
                    857 / Projection.totalH(bandVisible: true))
    XCTAssertEqual(rect.w, Projection.mapW * scale, accuracy: 0.5)
    XCTAssertEqual(rect.h, Projection.totalH(bandVisible: true) * scale,
                   accuracy: 0.5)
    // Centered on both axes.
    XCTAssertEqual(rect.x, (2048 - rect.w) / 2, accuracy: 0.5)
    XCTAssertEqual(rect.y, (857 - rect.h) / 2, accuracy: 0.5)
  }

  func testPaintedRect_cropOverflowOversizesByCoveringAxis() {
    // Same 21:9 image under cropOverflow — slice picks the
    // LARGER axis so the painted rect extends past the canvas
    // on the constrained dimension, producing the expected
    // off-canvas crop.
    let image = CGSize(width: 2048, height: 857)
    let rect = Projection.paintedRectInImage(
      ctx(aspect: .cropOverflow,
          image: image, screen: image))!
    let scale = max(2048 / Projection.mapW,
                    857 / Projection.totalH(bandVisible: true))
    XCTAssertEqual(rect.w, Projection.mapW * scale, accuracy: 0.5)
    XCTAssertEqual(rect.h, Projection.totalH(bandVisible: true) * scale,
                   accuracy: 0.5)
  }

  func testPaintedRect_returnsNilWhenMenubarSwallowsHeight() {
    // Pathological: menu bar >= image height. Should refuse to
    // return a painted rect rather than producing negative h.
    let r = Projection.paintedRectInImage(
      ctx(aspect: .letterbox,
          image: CGSize(width: 100, height: 38),
          screen: CGSize(width: 100, height: 38),
          menuBar: 38))
    XCTAssertNil(r)
  }

  // MARK: – Stage 2b: image → screen

  func testImageToScreen_uniformScale() {
    // image (2048x1324) projected to screen (2056x1329). Per-
    // axis scale is ~1.0039.
    let c = ctx(aspect: .letterbox,
                image: CGSize(width: 2048, height: 1324),
                screen: CGSize(width: 2056, height: 1329))
    let pt = Projection.imageToScreen((x: 1024, y: 662), in: c)
    XCTAssertEqual(pt.x, 1024 * (2056.0 / 2048.0), accuracy: 0.05)
    XCTAssertEqual(pt.y, 662 * (1329.0 / 1324.0), accuracy: 0.05)
  }

  // MARK: – screenPoint clipping + menu-bar offset

  func testScreenPoint_offscreenReturnsNil() {
    // y intentionally far below the screen → out of bounds.
    let c = ctx(aspect: .stretch,
                image: CGSize(width: 2048, height: 1000),
                screen: CGSize(width: 2048, height: 1000))
    // viewBoxPoint(lat: 90) gives y=0; with menubar=0 and stretch
    // we'd hit y=0 which is on-screen. Pick a fake VB point off the
    // canvas instead by going negative.
    let vb = (x: -100.0, y: 500.0)
    XCTAssertNil(Projection.screenPoint(viewBoxPoint: vb, in: c))
  }

  func testScreenPoint_appliesMenubarOffset() {
    // With a menubar reserved at the top of the canvas, the
    // top of the viewBox (y == yMin) maps to y == menuBar on
    // screen — not y == 0.
    let menuBar: Double = 38
    let c = ctx(aspect: .stretch,
                image: CGSize(width: 2048, height: 1324),
                screen: CGSize(width: 2048, height: 1324),
                menuBar: menuBar,
                bandVisible: true)
    let vbAtTop = (x: 0.0, y: Projection.yMin(bandVisible: true))
    let pt = Projection.screenPoint(viewBoxPoint: vbAtTop, in: c)
    XCTAssertNotNil(pt)
    XCTAssertEqual(pt!.y, menuBar, accuracy: 0.5)
  }

  // MARK: – screenPoints wrap-tile copies

  func testScreenPoints_singleCopyWhenViewBoxFillsScreen() {
    // Square-ish screen exactly matching the viewBox aspect —
    // only one wrap is on-screen.
    let image = CGSize(width: Projection.mapW,
                       height: Projection.totalH(bandVisible: true))
    let c = ctx(aspect: .stretch, image: image, screen: image)
    let pts = Projection.screenPoints(
      lat: 0, lon: 0, centerLon: 0, in: c)
    XCTAssertEqual(pts.count, 1)
  }

  func testScreenPoints_extraCopyInLetterboxBars() {
    // Screen far wider than viewBox + letterbox. The wrap-tile
    // copies at lonE ± 360° land in the side bars and should
    // be returned by screenPoints.
    let image = CGSize(width: 4000, height: 800)
    let c = ctx(aspect: .letterbox, image: image, screen: image,
                bandVisible: false)
    // A point near the left edge of the viewBox: lon close to
    // leftEdgeLon means the shift-+1 copy lands far inside the
    // right bar.
    let pts = Projection.screenPoints(
      lat: 0, lon: -179, centerLon: 0, in: c)
    XCTAssertGreaterThanOrEqual(pts.count, 1,
                                "central copy must be present")
    // Two copies expected: one near left edge, one wrapped to
    // far right. We don't pin exact positions — just the count.
    XCTAssertGreaterThanOrEqual(pts.count, 2,
                                "wrap copy should appear in the wide letterbox")
  }
}
