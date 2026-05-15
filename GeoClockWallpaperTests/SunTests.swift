import XCTest
@testable import GeoClockWallpaper

/// Astronomical-formula sanity tests for `Sun`. Mirrors the
/// card's `sun.ts` (low-precision USNO formulas, ≤0.01° accuracy
/// 1950–2050). We pin against a handful of known fixed points
/// rather than scraping ephemerides — what we care about most is
/// that the function STAYS in agreement with itself and with the
/// card; tiny absolute errors against the real sun are fine.
final class SunTests: XCTestCase {

  /// 2026 March 20, 14:33 UTC — Northern equinox. Subsolar
  /// latitude should be very close to 0°.
  func testEquinoxDeclinationNearZero() {
    let date = Date(timeIntervalSince1970: 1774017180)  // 2026-03-20 14:33Z
    let p = Sun.subsolarPoint(at: date)
    XCTAssertEqual(p.lat, 0, accuracy: 0.5)
  }

  /// 2026 June 21, 08:24 UTC — Northern solstice. Declination
  /// ≈ +23.44°.
  func testJuneSolsticeDeclinationNearAxialTilt() {
    let date = Date(timeIntervalSince1970: 1782030240)
    let p = Sun.subsolarPoint(at: date)
    XCTAssertEqual(p.lat, 23.44, accuracy: 0.2)
  }

  func testSubsolarLongitudeMoves15DegPerHour() {
    // The subsolar longitude rotates westward at ≈ 15°/hour
    // (modulo the equation of time, which changes very slowly).
    // Compare two samples one hour apart and confirm the
    // longitude moves by roughly 15° west.
    let t1 = Date(timeIntervalSince1970: 1774017180)
    let t2 = t1.addingTimeInterval(3600)
    let p1 = Sun.subsolarPoint(at: t1)
    let p2 = Sun.subsolarPoint(at: t2)
    // Wrap-aware delta: shortest signed angular distance.
    var delta = p2.lon - p1.lon
    while delta > 180 { delta -= 360 }
    while delta < -180 { delta += 360 }
    XCTAssertEqual(delta, -15, accuracy: 0.1)
  }

  func testAltitudeAtSubsolarPointIsNinety() {
    // The sun is directly overhead at the subsolar point: the
    // altitude there is +90°.
    let date = Date(timeIntervalSince1970: 1774017180)
    let sub = Sun.subsolarPoint(at: date)
    let alt = Sun.altitude(lat: sub.lat, lon: sub.lon, at: date)
    XCTAssertEqual(alt, 90, accuracy: 0.01)
  }

  func testAltitudeAtAntisolarPointIsMinusNinety() {
    // 180° around the planet from the subsolar point the sun
    // is at -90° (straight down through the earth).
    let date = Date(timeIntervalSince1970: 1774017180)
    let sub = Sun.subsolarPoint(at: date)
    let antiLat = -sub.lat
    let antiLon = sub.lon + 180  // wrap200 in altitude is fine
    let alt = Sun.altitude(lat: antiLat, lon: antiLon, at: date)
    XCTAssertEqual(alt, -90, accuracy: 0.01)
  }

  func testIsDaylightTrueAtSubsolar() {
    let date = Date(timeIntervalSince1970: 1774017180)
    let sub = Sun.subsolarPoint(at: date)
    XCTAssertTrue(Sun.isDaylight(lat: sub.lat, lon: sub.lon, at: date))
  }

  func testIsDaylightFalseAtAntisolar() {
    let date = Date(timeIntervalSince1970: 1774017180)
    let sub = Sun.subsolarPoint(at: date)
    XCTAssertFalse(Sun.isDaylight(
      lat: -sub.lat, lon: sub.lon + 180, at: date))
  }
}
