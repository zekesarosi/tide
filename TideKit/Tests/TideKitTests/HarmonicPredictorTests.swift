import XCTest
@testable import TideKit

/// Validates the harmonic engine against NOAA CO-OPS official predictions
/// (fixtures downloaded from api.tidesandcurrents.noaa.gov, datum MSL, GMT).
final class HarmonicPredictorTests: XCTestCase {
    func predictor(_ station: String, datum: TidalDatum = .msl) throws -> HarmonicPredictor {
        let constituents = try NOAACoopsDecoding.harmonicConstituents(from: Fixtures.data("harcon_\(station)"))
        return HarmonicPredictor(constituents: constituents)
    }

    func assertMatchesNOAA(station: String, period: String, rms maxRMS: Double, max maxAbs: Double,
                           file: StaticString = #filePath, line: UInt = #line) throws {
        let p = try predictor(station)
        let noaa = try NOAACoopsDecoding.predictions(from: Fixtures.data("pred_\(station)_\(period)"))
        XCTAssertGreaterThan(noaa.count, 600, file: file, line: line)
        var sse = 0.0, worst = 0.0
        for point in noaa.points {
            let e = p.height(at: point.date) - point.value
            sse += e * e
            worst = max(worst, abs(e))
        }
        let rms = (sse / Double(noaa.count)).squareRoot()
        XCTAssertLessThan(rms, maxRMS, "\(station) \(period) RMS", file: file, line: line)
        XCTAssertLessThan(worst, maxAbs, "\(station) \(period) max", file: file, line: line)
    }

    // NOAA publishes predictions rounded to 1 mm, so ~0.3 mm RMS is the floor.

    func testTheBatteryNY() throws {
        try assertMatchesNOAA(station: "8518750", period: "202601", rms: 0.001, max: 0.002)
        try assertMatchesNOAA(station: "8518750", period: "203506", rms: 0.001, max: 0.002)
    }

    func testGalvestonTX() throws {
        try assertMatchesNOAA(station: "8771450", period: "202601", rms: 0.001, max: 0.002)
        try assertMatchesNOAA(station: "8771450", period: "203506", rms: 0.001, max: 0.002)
    }

    func testSeattleWA() throws {
        try assertMatchesNOAA(station: "9447130", period: "202601", rms: 0.0015, max: 0.003)
        try assertMatchesNOAA(station: "9447130", period: "203506", rms: 0.0015, max: 0.003)
    }

    /// Anchorage: ~11 m range and 120 constituents, incl. 80+ compound tides.
    func testAnchorageAK() throws {
        try assertMatchesNOAA(station: "9455920", period: "202601", rms: 0.002, max: 0.005)
        try assertMatchesNOAA(station: "9455920", period: "203506", rms: 0.002, max: 0.005)
    }

    func testAllAnchorageConstituentsResolve() throws {
        let p = try predictor("9455920")
        XCTAssertEqual(p.unresolvedConstituents, [])
        XCTAssertEqual(p.constituentCount, 120)
    }

    func testHighLowTimesMatchNOAA() throws {
        // NOAA hi/lo fixture is in MLLW; shift our MSL-based curve by MSL−MLLW.
        let datums = try NOAACoopsDecoding.datums(from: Fixtures.data("datums_8518750"))
        let shift = try XCTUnwrap(datums.offset(of: .msl, relativeTo: .mllw))
        let constituents = try NOAACoopsDecoding.harmonicConstituents(from: Fixtures.data("harcon_8518750"))
        let p = HarmonicPredictor(constituents: constituents, meanLevel: shift)

        let noaa = try NOAACoopsDecoding.extremes(from: Fixtures.data("hilo_8518750"))
        let start = try XCTUnwrap(noaa.first?.date).addingTimeInterval(-3_600)
        let end = try XCTUnwrap(noaa.last?.date).addingTimeInterval(3_600)
        let ours = p.extrema(from: start, to: end)
        XCTAssertEqual(ours.count, noaa.count)
        for (a, b) in zip(ours, noaa) {
            XCTAssertEqual(a.kind, b.kind)
            XCTAssertEqual(a.date.timeIntervalSince1970, b.date.timeIntervalSince1970, accuracy: 90) // NOAA rounds to the minute
            XCTAssertEqual(a.height, b.height, accuracy: 0.002)
        }
    }

    func testCompoundNameResolution() {
        func terms(_ name: String, _ speed: Double) -> String? {
            ConstituentCatalog.definition(named: name, speed: speed)?.terms
                .map { "\($0.coefficient)\($0.base.name)" }.joined(separator: " ")
        }
        XCTAssertEqual(terms("M4", 57.9682084), "2M2")
        XCTAssertEqual(terms("MK3", 44.0251729), "1M2 1K1")
        XCTAssertEqual(terms("2MK3", 42.9271398), "2M2 -1K1")
        XCTAssertEqual(terms("MKS2", 29.066242), "1M2 1K2 -1S2")
        XCTAssertEqual(terms("2MS8", 117.96821), "2M2 2S2")
        XCTAssertEqual(terms("M2KS2", 29.148378), "1M2 2K2 -2S2")
        XCTAssertEqual(terms("2SNMK2", 29.373487), "2S2 1N2 -1M2 -1K2")
        XCTAssertNil(ConstituentCatalog.definition(named: "XYZ9", speed: 1))
    }

    func testMeanLevelOffsetsCurve() throws {
        let c = [HarmonicConstituent(name: "M2", amplitude: 1, phaseGMT: 0, speed: 28.984104)]
        let a = HarmonicPredictor(constituents: c)
        let b = HarmonicPredictor(constituents: c, meanLevel: 1.5)
        let d = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(b.height(at: d) - a.height(at: d), 1.5, accuracy: 1e-12)
    }
}

enum Fixtures {
    static func data(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
                                "missing fixture \(name)")
        return try Data(contentsOf: url)
    }
}
