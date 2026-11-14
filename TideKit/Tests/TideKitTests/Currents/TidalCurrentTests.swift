import XCTest
@testable import TideKit

/// Tidal currents at the Golden Gate (NOAA SFB1203, bin 18, 9 m below the surface)
/// against NOAA's own published predictions for 1–7 November 2026
/// (`currents_predictions`, 30-minute and MAX_SLACK, fetched from api.tidesandcurrents.noaa.gov).
final class TidalCurrentTests: XCTestCase {
    func goldenGate() throws -> CurrentHarmonics {
        let bins = try NOAACoopsDecoding.currentHarmonics(from: Fixtures.data("harcon_current_SFB1203"))
        XCTAssertEqual(bins.map(\.bin), [5, 15, 18])
        return try XCTUnwrap(bins.first { $0.bin == 18 })
    }

    func testDecodesHarmonicsInKnots() throws {
        let h = try goldenGate()
        XCTAssertEqual(h.azimuth, 72.8)
        XCTAssertEqual(h.constituents.count, 25)
        let m2 = try XCTUnwrap(h.constituents.first { $0.name == "M2" })
        XCTAssertEqual(m2.majorAmplitude, 100.52 * 0.01 * 3_600 / 1_852, accuracy: 1e-12) // 1.954 kn
        XCTAssertEqual(h.meanMajor, 8.23 * 0.01 * 3_600 / 1_852, accuracy: 1e-12)
        XCTAssertEqual(h.predictor().unresolvedConstituents, [])
    }

    /// NOAA publishes cm/s to 0.1, i.e. 0.002 kn: we are at the rounding floor.
    func testVelocityMatchesNOAA() throws {
        let p = try goldenGate().predictor()
        let noaa = try NOAACoopsDecoding.currentPredictions(from: Fixtures.data("currents_pred_SFB1203_202611"))
        XCTAssertEqual(noaa.count, 336)
        var sse = 0.0, worst = 0.0
        for pt in noaa.points {
            let e = p.velocity(at: pt.date) - pt.value
            sse += e * e
            worst = max(worst, abs(e))
        }
        XCTAssertLessThan((sse / Double(noaa.count)).squareRoot(), 0.0015)
        XCTAssertLessThan(worst, 0.004)
    }

    func testSlackAndMaximaMatchNOAA() throws {
        let p = try goldenGate().predictor()
        let noaa = try NOAACoopsDecoding.currentEvents(from: Fixtures.data("currents_maxslack_SFB1203_202611"))
        let start = try XCTUnwrap(noaa.first?.date) - 3_600, end = try XCTUnwrap(noaa.last?.date) + 3_600
        let ours = p.events(from: start, to: end)
        XCTAssertEqual(ours.count, noaa.count)
        var worstTime = 0.0
        for n in noaa {
            let match = try XCTUnwrap(ours.filter { $0.kind == n.kind }.min { abs($0.date.timeIntervalSince(n.date)) < abs($1.date.timeIntervalSince(n.date)) })
            let dt = abs(match.date.timeIntervalSince(n.date))
            worstTime = max(worstTime, dt)
            // NOAA rounds event times to the minute.
            XCTAssertLessThan(dt, 90, "\(n.kind) at \(n.date)")
            if n.kind != .slack { XCTAssertEqual(match.velocity, n.velocity, accuracy: 0.01, "\(n.kind) at \(n.date)") }
        }
        print(String(format: "SFB1203 events: %d, worst time difference %.0f s", noaa.count, worstTime))
        // Events alternate slack / max.
        for (a, b) in zip(ours, ours.dropFirst()) { XCTAssertNotEqual(a.kind == .slack, b.kind == .slack) }
    }

    /// Set and drift from both axes (with the minor-axis mean) against NOAA's
    /// `vel_type=speed_dir` predictions, which NOAA rounds to whole degrees.
    func testSetAndDriftMatchNOAA() throws {
        let p = try goldenGate().predictor()
        let noaa = try NOAACoopsDecoding.currentSpeedDirection(from: Fixtures.data("currents_speeddir_SFB1203_202611"))
        XCTAssertEqual(noaa.count, 336)
        var worstDirection = 0.0, worstSpeed = 0.0
        for n in noaa {
            let sd = p.setAndDrift(at: n.date)
            worstSpeed = max(worstSpeed, abs(sd.drift - n.speed))
            // Direction is ill-defined near slack.
            if n.speed > 0.3 { worstDirection = max(worstDirection, abs(Navigation.angleDifference(from: n.direction, to: sd.set))) }
        }
        XCTAssertLessThan(worstDirection, 0.75)
        XCTAssertLessThan(worstSpeed, 0.004)

        let maxFlood = ISO8601DateFormatter().date(from: "2026-11-01T10:57:00Z")!
        XCTAssertEqual(p.component(along: 72.8, at: maxFlood), p.velocity(at: maxFlood), accuracy: 1e-9)
        XCTAssertEqual(p.component(along: 72.8 + 180, at: maxFlood), -p.velocity(at: maxFlood), accuracy: 1e-9)
    }
}
