import XCTest
@testable import TideKit

/// WMM2025 against NCEI's official "Test Values for WMM2025" (WMM2025testvalues.pdf, Feb 2025).
final class MagneticModelTests: XCTestCase {
    struct Row {
        let year: Double, heightKm: Double, lat: Double, lon: Double
        let x: Double, y: Double, z: Double, h: Double, f: Double, i: Double, d: Double
        let gv: Double?
    }

    static let rows: [Row] = [
        Row(year: 2025.0, heightKm: 0, lat: 80, lon: 0, x: 6521.6, y: 145.9, z: 54791.5, h: 6523.2, f: 55178.5, i: 83.21, d: 1.28, gv: 1.28),
        Row(year: 2025.0, heightKm: 0, lat: 0, lon: 120, x: 39677.8, y: -109.6, z: -10580.2, h: 39677.9, f: 41064.3, i: -14.93, d: -0.16, gv: nil),
        Row(year: 2025.0, heightKm: 0, lat: -80, lon: 240, x: 6117.5, y: 15751.9, z: -52022.5, h: 16898.1, f: 54698.2, i: -72.00, d: 68.78, gv: -51.22),
        Row(year: 2025.0, heightKm: 100, lat: 80, lon: 0, x: 6216.0, y: 92.4, z: 52598.8, h: 6216.7, f: 52964.9, i: 83.26, d: 0.85, gv: 0.85),
        Row(year: 2025.0, heightKm: 100, lat: 0, lon: 120, x: 37688.6, y: -96.2, z: -10152.1, h: 37688.7, f: 39032.1, i: -15.08, d: -0.15, gv: nil),
        Row(year: 2025.0, heightKm: 100, lat: -80, lon: 240, x: 5907.6, y: 14780.3, z: -49540.7, h: 15917.1, f: 52035.0, i: -72.19, d: 68.21, gv: -51.79),
        Row(year: 2027.5, heightKm: 0, lat: 80, lon: 0, x: 6500.8, y: 294.5, z: 54869.4, h: 6507.5, f: 55253.9, i: 83.24, d: 2.59, gv: 2.59),
        Row(year: 2027.5, heightKm: 0, lat: 0, lon: 120, x: 39701.6, y: -167.4, z: -10381.8, h: 39702.0, f: 41036.9, i: -14.65, d: -0.24, gv: nil),
        Row(year: 2027.5, heightKm: 0, lat: -80, lon: 240, x: 6200.7, y: 15730.3, z: -51783.7, h: 16908.3, f: 54474.2, i: -71.92, d: 68.49, gv: -51.51),
        Row(year: 2027.5, heightKm: 100, lat: 80, lon: 0, x: 6196.7, y: 233.8, z: 52670.5, h: 6201.1, f: 53034.3, i: 83.29, d: 2.16, gv: 2.16),
        Row(year: 2027.5, heightKm: 100, lat: 0, lon: 120, x: 37711.5, y: -148.7, z: -9969.8, h: 37711.8, f: 39007.4, i: -14.81, d: -0.23, gv: nil),
        Row(year: 2027.5, heightKm: 100, lat: -80, lon: 240, x: 5984.0, y: 14760.1, z: -49317.7, h: 15927.0, f: 51825.7, i: -72.10, d: 67.93, gv: -52.07),
    ]

    func testOfficialTestValues() {
        let m = MagneticModel.wmm2025
        for r in Self.rows {
            let f = m.field(latitude: r.lat, longitude: r.lon, height: r.heightKm * 1_000, decimalYear: r.year)
            let label = "\(r.year) \(r.heightKm) km \(r.lat), \(r.lon)"
            // Published to 0.1 nT and 0.01°.
            XCTAssertEqual(f.north, r.x, accuracy: 0.11, label)
            XCTAssertEqual(f.east, r.y, accuracy: 0.11, label)
            XCTAssertEqual(f.down, r.z, accuracy: 0.11, label)
            XCTAssertEqual(f.horizontal, r.h, accuracy: 0.11, label)
            XCTAssertEqual(f.total, r.f, accuracy: 0.11, label)
            XCTAssertEqual(f.inclination, r.i, accuracy: 0.0051, label)
            XCTAssertEqual(f.declination, r.d, accuracy: 0.0051, label)
            let gv = m.gridVariation(latitude: r.lat, longitude: r.lon, declination: f.declination)
            if let expected = r.gv {
                XCTAssertEqual(gv!, expected, accuracy: 0.0051, label)
            } else {
                XCTAssertNil(gv, label)
            }
        }
    }

    func testDecimalYearAndValidity() {
        let m = MagneticModel.wmm2025
        let jan1 = ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")!
        XCTAssertEqual(MagneticModel.decimalYear(jan1), 2026, accuracy: 1e-12)
        let jul2 = ISO8601DateFormatter().date(from: "2026-07-02T12:00:00Z")!
        XCTAssertEqual(MagneticModel.decimalYear(jul2), 2026.5, accuracy: 1e-9)
        XCTAssertTrue(m.isValid(at: jan1))
        XCTAssertFalse(m.isValid(at: ISO8601DateFormatter().date(from: "2031-01-01T00:00:00Z")!))
    }

    /// Sanity: NOAA's calculator gives about 12.5° W at The Battery in late 2026, and about
    /// 12.8° E at the Golden Gate. The model must agree in sign and to within half a degree.
    func testVariationAtFamiliarHarbours() {
        let date = ISO8601DateFormatter().date(from: "2026-11-14T00:00:00Z")!
        let ny = MagneticModel.wmm2025.declination(at: .init(latitude: 40.7006, longitude: -74.0142), date: date)
        let sf = MagneticModel.wmm2025.declination(at: .init(latitude: 37.8199, longitude: -122.4783), date: date)
        XCTAssertEqual(ny, -12.5, accuracy: 0.5)
        XCTAssertEqual(sf, 12.8, accuracy: 0.5)
        XCTAssertEqual(MagneticModel.magnetic(fromTrue: 90, variation: ny), 90 - ny, accuracy: 1e-12)
        XCTAssertEqual(MagneticModel.trueBearing(fromMagnetic: MagneticModel.magnetic(fromTrue: 5, variation: 13), variation: 13), 5, accuracy: 1e-12)
    }
}
