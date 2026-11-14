import XCTest
@testable import TideKit

final class TidalGatePlannerTests: XCTestCase {
    let t0 = ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z")!
    let nm = Navigation.metersPerNauticalMile

    /// A uniform stream along one axis, A·cos(2π(t − tMax)/T), knots.
    struct SinusoidalStream: CurrentField {
        let direction: Double, amplitude: Double, tMax: Date, period: TimeInterval
        func current(at position: GeoCoordinate, time: Date) -> ENUVector {
            ENUVector(direction: direction, magnitude: amplitude * cos(2 * .pi * time.timeIntervalSince(tMax) / period))
        }
    }

    struct Constant: CurrentField {
        let v: ENUVector
        func current(at position: GeoCoordinate, time: Date) -> ENUVector { v }
    }

    func eastLeg(_ nmiles: Double, from start: GeoCoordinate = .init(latitude: 37.5, longitude: -123.0)) -> (GeoCoordinate, GeoCoordinate) {
        (start, RhumbLine.destination(from: start, bearing: 90, distance: nmiles * nm))
    }

    func testCrossCurrentMatchesVectorTriangle() throws {
        let (a, b) = eastLeg(10)
        let planner = TidalGatePlanner(legs: [.init(from: a, to: b, current: Constant(v: ENUVector(direction: 180, magnitude: 1)))],
                                       speedThroughWater: 5)
        let plan = try planner.simulate(departure: t0)
        // SOG = √(5² − 1²) kn over 10 nm.
        XCTAssertEqual(plan.duration, 10 / 24.0.squareRoot() * 3_600, accuracy: 1)
        XCTAssertEqual(plan.legs[0].initialHeading, 90 - asin(0.2) * 180 / .pi, accuracy: 1e-6)
        XCTAssertEqual(plan.legs[0].averageSpeedOverGround, 24.0.squareRoot(), accuracy: 0.01)
    }

    func testFoulStreamStrongerThanBoatThrows() {
        let (a, b) = eastLeg(5)
        let planner = TidalGatePlanner(legs: [.init(from: a, to: b, current: Constant(v: ENUVector(direction: 270, magnitude: 7)))],
                                       speedThroughWater: 5)
        XCTAssertThrowsError(try planner.simulate(departure: t0)) {
            guard case .cannotMakeGood(legIndex: 0, _) = $0 as? TidalGatePlanner.PlanError else { return XCTFail("\($0)") }
        }
    }

    /// With a symmetric stream, the quickest passage is centred on maximum fair stream.
    func testShortestPassageIsCentredOnMaxFair() throws {
        let tMax = t0 + 10 * 3_600
        let stream = SinusoidalStream(direction: 90, amplitude: 2, tMax: tMax, period: 12.42 * 3_600)
        let (a, b) = eastLeg(15)
        let planner = TidalGatePlanner(legs: [.init(from: a, to: b, current: stream)], speedThroughWater: 5)
        let best = try XCTUnwrap(planner.bestDeparture(in: DateInterval(start: t0, duration: 12.42 * 3_600)))
        let centre = best.departure + best.duration / 2
        XCTAssertEqual(centre.timeIntervalSince(tMax), 0, accuracy: 3 * 60)
        XCTAssertGreaterThan(best.legs[0].averageSpeedOverGround, 6.5)
        // Leaving at the worst moment (centred on max foul) is far slower.
        let worst = try planner.simulate(departure: tMax + 6.21 * 3_600 - best.duration / 2)
        XCTAssertGreaterThan(worst.duration, best.duration * 1.5)
    }

    func testSlackGateConstrainsArrival() throws {
        let tMax = t0 + 6 * 3_600
        let period = 12.42 * 3_600
        let stream = SinusoidalStream(direction: 90, amplitude: 3, tMax: tMax, period: period)
        let (a, b) = eastLeg(8)
        let planner = TidalGatePlanner(legs: [.init(from: a, to: b, current: stream)],
                                       gates: [.init(atEndOfLeg: 0, .maximumStream(0.5), name: "bar")], speedThroughWater: 6)
        let plans = planner.departures(in: DateInterval(start: t0, duration: 24 * 3_600), every: 10 * 60)
        let best = try XCTUnwrap(plans.first)
        XCTAssertTrue(best.isFeasible)
        XCTAssertLessThanOrEqual(best.legs[0].streamAtEnd, 0.5)
        // Every feasible plan arrives within ±(asin(0.5/3)/2π)·T of a slack.
        let halfWidth = asin(0.5 / 3) / (2 * .pi) * period
        for p in plans where p.isFeasible {
            let phase = p.arrival.timeIntervalSince(tMax + period / 4).truncatingRemainder(dividingBy: period / 2)
            let off = min(abs(phase), period / 2 - abs(phase))
            XCTAssertLessThanOrEqual(off, halfWidth + 60)
        }
        XCTAssertTrue(plans.contains { !$0.isFeasible })
    }

    func testWindowAndFairCurrentGates() throws {
        let (a, mid) = eastLeg(5)
        let b = RhumbLine.destination(from: mid, bearing: 0, distance: 5 * nm)
        let window = DateInterval(start: t0 + 2 * 3_600, duration: 3_600)
        let planner = TidalGatePlanner(
            legs: [.init(from: a, to: mid, current: NoCurrent()), .init(from: mid, to: b, current: Constant(v: ENUVector(direction: 0, magnitude: 1)))],
            gates: [.init(atEndOfLeg: 1, .window(window)), .init(atEndOfLeg: 1, .minimumFairCurrent(0.5))],
            speedThroughWater: 5)
        let p = try planner.simulate(departure: t0)
        // 5 nm at 5 kn, then 5 nm at 6 kn: 1 h 50 min.
        XCTAssertEqual(p.duration, 3_600 + 50 * 60, accuracy: 1)
        XCTAssertEqual(p.violatedGates, [0]) // arrives 10 min early
        XCTAssertTrue(try planner.simulate(departure: t0 + 30 * 60).isFeasible)
        XCTAssertEqual(planner.bestDeparture(in: DateInterval(start: t0, duration: 3 * 3_600), objective: .earliestArrival)?.arrival.timeIntervalSince(window.start) ?? -1, 0, accuracy: 61)
    }

    /// Entering San Francisco Bay through the Golden Gate on 1 Nov 2026 at 6 kn: the quickest
    /// passage rides the strong morning flood (NOAA max flood 10:57 UTC, 2.50 kn), not the
    /// weaker evening one (22:18 UTC, 1.82 kn).
    func testGoldenGateInboundRidesTheFlood() throws {
        let bins = try NOAACoopsDecoding.currentHarmonics(from: Fixtures.data("harcon_current_SFB1203"))
        let station = try XCTUnwrap(bins.first { $0.bin == 18 }).predictor()
        let outside = GeoCoordinate(latitude: 37.800, longitude: -122.560) // off Point Bonita
        let inside = GeoCoordinate(latitude: 37.830, longitude: -122.400)  // off Alcatraz
        let planner = TidalGatePlanner(legs: [.init(from: outside, to: inside, current: StationCurrentField(station))],
                                       gates: [.init(atEndOfLeg: 0, .minimumFairCurrent(0))], speedThroughWater: 6)
        let best = try XCTUnwrap(planner.bestDeparture(in: DateInterval(start: t0, duration: 24 * 3_600)))
        let maxFlood = ISO8601DateFormatter().date(from: "2026-11-01T10:57:00Z")!
        let centre = best.departure + best.duration / 2
        XCTAssertEqual(centre.timeIntervalSince(maxFlood), 0, accuracy: 45 * 60)
        XCTAssertTrue(best.isFeasible)
        XCTAssertGreaterThan(best.legs[0].averageSpeedOverGround, 7.5)
    }
}
