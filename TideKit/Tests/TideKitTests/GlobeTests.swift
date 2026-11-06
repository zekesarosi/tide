import XCTest
@testable import TideKit

/// The Tide Globe's astronomy and ocean tide atlas.
final class GlobeTests: XCTestCase {
    // MARK: Ephemeris vs JPL Horizons (geocentric apparent RA/Dec, distance; 06:00 UT)

    struct Fix { let date: String; let ra: Double; let dec: Double; let au: Double }

    static let moonFixes: [Fix] = [
        Fix(date: "2020-01-01", ra: 351.96927, dec: -8.89659, au: 0.00270187229911),
        Fix(date: "2023-06-15", ra: 46.52602, dec: 18.96561, au: 0.00258714253185),
        Fix(date: "2025-01-10", ra: 59.86770, dec: 25.12560, au: 0.00248409945896),
        Fix(date: "2026-11-05", ra: 174.72161, dec: -0.33009, au: 0.00256971486569),
        Fix(date: "2028-03-20", ra: 297.62591, dec: -21.47468, au: 0.00268978442223),
        Fix(date: "2031-09-01", ra: 336.64745, dec: -4.52749, au: 0.00243318059735),
        Fix(date: "2034-12-24", ra: 75.90867, dec: 17.76100, au: 0.00239415014424),
        Fix(date: "2040-07-04", ra: 44.21355, dec: 15.22815, au: 0.00264498647833),
    ]
    static let sunFixes: [Fix] = [
        Fix(date: "2020-01-01", ra: 281.16501, dec: -23.03944, au: 0.98328764974648),
        Fix(date: "2023-06-15", ra: 83.36971, dec: 23.29835, au: 1.01572915997788),
        Fix(date: "2025-01-10", ra: 291.89650, dec: -21.91281, au: 0.98340710091338),
        Fix(date: "2026-11-05", ra: 220.38329, dec: -15.68902, au: 0.99162751025895),
        Fix(date: "2028-03-20", ra: 0.14112, dec: 0.06114, au: 0.99592699632986),
        Fix(date: "2031-09-01", ra: 160.25164, dec: 8.33216, au: 1.00934975731126),
        Fix(date: "2034-12-24", ra: 272.70135, dec: -23.40881, au: 0.98358904801552),
        Fix(date: "2040-07-04", ra: 103.99559, dec: 22.81155, au: 1.01672027624472),
    ]

    func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s + "T06:00:00Z")! }

    func angleDiff(_ a: Double, _ b: Double) -> Double { abs(Angle.normalize(a - b + 180) - 180) }

    func testMoonMatchesHorizons() {
        for f in Self.moonFixes {
            let m = Ephemeris.moon(date(f.date))
            XCTAssertLessThan(angleDiff(m.rightAscension, f.ra) * cos(f.dec.radians), 0.2, f.date)
            XCTAssertLessThan(abs(m.declination - f.dec), 0.2, f.date)
            XCTAssertLessThan(abs(m.distance - f.au * Ephemeris.astronomicalUnit), 600, f.date)
        }
    }

    func testSunMatchesHorizons() {
        for f in Self.sunFixes {
            let s = Ephemeris.sun(date(f.date))
            XCTAssertLessThan(angleDiff(s.rightAscension, f.ra), 0.03, f.date)
            XCTAssertLessThan(abs(s.declination - f.dec), 0.03, f.date)
            XCTAssertLessThan(abs(s.distance / Ephemeris.astronomicalUnit - f.au), 1e-4, f.date)
        }
    }

    func testSubpointAndPhase() {
        // 2026-11-09 ~07:02 UT is new Moon; 2026-11-24 ~14:53 UT is full Moon.
        XCTAssertLessThan(Ephemeris.lunarIllumination(ISO8601DateFormatter().date(from: "2026-11-09T07:00:00Z")!), 0.01)
        XCTAssertGreaterThan(Ephemeris.lunarIllumination(ISO8601DateFormatter().date(from: "2026-11-24T15:00:00Z")!), 0.99)
        // At 12:00 UT on the March equinox the Sun is overhead near (0°, ~0°E).
        let noon = ISO8601DateFormatter().date(from: "2028-03-20T12:00:00Z")!
        let p = Ephemeris.sun(noon).subpoint(at: noon)
        XCTAssertEqual(p.latitude, 0, accuracy: 0.3)
        XCTAssertEqual(p.longitude, 0, accuracy: 2.5) // equation of time ≈ 7.5 min
    }

    // MARK: Atlas format

    func testHalfFloat() {
        XCTAssertEqual(TideAtlas.halfToFloat(0x3C00), 1)
        XCTAssertEqual(TideAtlas.halfToFloat(0xC000), -2)
        XCTAssertEqual(TideAtlas.halfToFloat(0x3555), 0.333_251_95, accuracy: 1e-7)
        XCTAssertEqual(TideAtlas.halfToFloat(0x0001), 5.960_464_5e-8, accuracy: 1e-12)
        XCTAssertEqual(TideAtlas.halfToFloat(0x0000), 0)
    }

    /// A 3×4 atlas with a uniform M2 of 1 m at G = 90°, and S2 of 0.5 m at 0°.
    func syntheticAtlas() throws -> TideAtlas {
        var d = Data("TATL".utf8)
        func u16(_ v: Int) { d.append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8)]) }
        func f32(_ v: Float) { withUnsafeBytes(of: v.bitPattern.littleEndian) { d.append(contentsOf: $0) } }
        u16(1); u16(3); u16(4); u16(2)
        f32(-60); f32(60); f32(0); f32(90)
        d.append(contentsOf: Array("M2      ".utf8)); d.append(contentsOf: Array("S2      ".utf8))
        for _ in 0..<12 { u16(0x0000); u16(0x3C00) }  // M2: (0, 1) → H = 1, G = 90°
        for _ in 0..<12 { u16(0x3800); u16(0x0000) }  // S2: (0.5, 0) → H = 0.5, G = 0°
        return try TideAtlas(data: d)
    }

    func testSyntheticAtlasMatchesPredictor() throws {
        let atlas = try syntheticAtlas()
        XCTAssertEqual(atlas.constituents.map(\.name), ["M2", "S2"])
        let c = atlas.harmonicConstituents(latitude: 12.3, longitude: 300)
        XCTAssertEqual(c.count, 2)
        XCTAssertEqual(c[0].amplitude, 1, accuracy: 1e-6)
        XCTAssertEqual(c[0].phaseGMT, 90, accuracy: 1e-6)
        XCTAssertEqual(c[1].phaseGMT, 0, accuracy: 1e-6)
        let p = HarmonicPredictor(constituents: c)
        var t = date("2026-11-05")
        for _ in 0..<24 {
            XCTAssertEqual(atlas.height(latitude: 12.3, longitude: 300, at: t), p.height(at: t), accuracy: 1e-6)
            t += 3_600
        }
    }

    func testRejectsBadData() {
        XCTAssertThrowsError(try TideAtlas(data: Data("nope".utf8)))
        var d = Data("TATL".utf8); d.append(contentsOf: [1, 0, 3, 0, 4, 0, 1, 0])
        d.append(Data(count: 16)); d.append(contentsOf: Array("ZZ9     ".utf8))
        XCTAssertThrowsError(try TideAtlas(data: d)) { XCTAssertEqual($0 as? TideAtlas.LoadError, .unknownConstituent("ZZ9")) }
    }

    // MARK: The shipped GOT4.10c atlas

    func shippedAtlas() throws -> TideAtlas {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/Resources/Globe/got410c.tideatlas")
        guard let data = try? Data(contentsOf: url) else { throw XCTSkip("atlas not found at \(url.path)") }
        return try TideAtlas(data: data)
    }

    func testShippedAtlasShape() throws {
        let a = try shippedAtlas()
        XCTAssertEqual(a.latitudeCount, 361)
        XCTAssertEqual(a.longitudeCount, 720)
        XCTAssertEqual(a.constituents.map(\.name), ["M2", "S2", "N2", "K2", "K1", "O1", "P1", "Q1"])
        XCTAssertEqual(a.halfFloatGrid(7).count, 361 * 720 * 4)
        // Mid-continent: nothing.
        XCTAssertTrue(a.harmonicConstituents(latitude: 40, longitude: -100).isEmpty)
    }

    /// The atlas tide just outside the Golden Gate tracks NOAA's own San
    /// Francisco prediction (37 constituents) over three days: same shape,
    /// within an hour.
    func testShippedAtlasTracksSanFranciscoGauge() throws {
        let a = try shippedAtlas()
        let station = HarmonicPredictor(constituents: try NOAACoopsDecoding.harmonicConstituents(from: Fixtures.data("harcon_9414290")))
        let model = HarmonicPredictor(constituents: a.harmonicConstituents(latitude: 37.7, longitude: -123.0))
        let t0 = date("2026-11-05")
        let s = (0..<432).map { station.height(at: t0 + Double($0) * 600) }
        func corr(lag: Int) -> Double {
            let m = (0..<432).map { model.height(at: t0 + Double($0 + lag) * 600) }
            let ms = s.reduce(0, +) / 432, mm = m.reduce(0, +) / 432
            var c = 0.0, vs = 0.0, vm = 0.0
            for i in 0..<432 { c += (s[i] - ms) * (m[i] - mm); vs += (s[i] - ms) * (s[i] - ms); vm += (m[i] - mm) * (m[i] - mm) }
            return c / (vs * vm).squareRoot()
        }
        let best = (-12...12).max { corr(lag: $0) < corr(lag: $1) }!
        XCTAssertGreaterThan(corr(lag: best), 0.97)
        XCTAssertLessThanOrEqual(abs(best), 6, "model leads/lags the gauge by \(best * 10) min")
    }

    /// Open water next to NOAA gauges: the model's M2 should be close to the
    /// gauge's own (gauges sit in harbours, so allow for local amplification).
    func testShippedAtlasAgreesWithGauges() throws {
        let a = try shippedAtlas()
        // San Francisco (9414290): M2 0.576 m, κ 208.2°. Offshore of the Golden Gate.
        let sf = try XCTUnwrap(a.constant(named: "M2", latitude: 37.7, longitude: -123.0))
        XCTAssertEqual(sf.amplitude, 0.55, accuracy: 0.12)
        XCTAssertLessThan(angleDiff(sf.phase, 208.2), 20)
        // Seattle (9447130): K1 0.834 m, κ 276.8°. The atlas grid can't resolve
        // Puget Sound, so check the Strait of Juan de Fuca entrance looks diurnal-strong.
        let jdf = try XCTUnwrap(a.constant(named: "K1", latitude: 48.4, longitude: -124.8))
        XCTAssertGreaterThan(jdf.amplitude, 0.35)
        // The North Atlantic M2 amphidrome (~50°N 39°W): almost no tide.
        let amph = (0..<21).flatMap { i in (0..<21).map { j in a.constant(named: "M2", latitude: 44 + Double(i) * 0.5, longitude: -46 + Double(j) * 0.5)!.amplitude } }.min()!
        XCTAssertLessThan(amph, 0.05)
    }
}
