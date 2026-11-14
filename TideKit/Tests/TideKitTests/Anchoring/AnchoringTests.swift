import XCTest
@testable import TideKit

final class SwingModelTests: XCTestCase {
    func testTautReachAndScope() {
        // 30 m of rode, 5 m of water, roller 1 m up: √(30² − 6²).
        XCTAssertEqual(SwingModel.tautReach(rodeLength: 30, verticalDrop: 6), 864.0.squareRoot(), accuracy: 1e-12)
        XCTAssertEqual(SwingModel.tautReach(rodeLength: 5, verticalDrop: 6), 0)
        XCTAssertEqual(SwingModel.scope(rodeLength: 30, verticalDrop: 6), 5)
    }

    /// 40 m of 10 mm chain (≈ 17 N/m submerged), 6 m drop, 1 kN horizontal pull:
    /// a = H/w = 58.82 m, suspended length √(h² + 2ah) = 27.24 m, reach = 12.76 + a·asinh(s/a) = 39.11 m.
    func testCatenaryReach() {
        let r = SwingModel.catenaryReach(rodeLength: 40, verticalDrop: 6, horizontalForce: 1_000, weightPerMeter: 17)
        XCTAssertEqual(r.reach, 39.110128159, accuracy: 1e-6)
        XCTAssertFalse(r.liftsAnchor)
        // No load: the chain hangs straight down and the rest lies on the bottom.
        XCTAssertEqual(SwingModel.catenaryReach(rodeLength: 40, verticalDrop: 6, horizontalForce: 0, weightPerMeter: 17).reach, 34)
        // Huge load: the chain lifts off the anchor and the reach tends to the taut line.
        let storm = SwingModel.catenaryReach(rodeLength: 40, verticalDrop: 6, horizontalForce: 50_000, weightPerMeter: 17)
        XCTAssertTrue(storm.liftsAnchor)
        XCTAssertEqual(storm.reach, SwingModel.tautReach(rodeLength: 40, verticalDrop: 6), accuracy: 1e-12)
        // Reach grows with load and never exceeds the taut line.
        var last = 0.0
        for f in stride(from: 0.0, through: 3_000, by: 250) {
            let r = SwingModel.catenaryReach(rodeLength: 40, verticalDrop: 6, horizontalForce: f, weightPerMeter: 17).reach
            XCTAssertGreaterThanOrEqual(r, last)
            XCTAssertLessThanOrEqual(r, SwingModel.tautReach(rodeLength: 40, verticalDrop: 6) + 1e-9)
            last = r
        }
    }

    /// Anchored off The Battery in 3 m (MLLW) on 2 Jan 2026 with the real tide.
    func testAnchorPlanFollowsTheTide() throws {
        let constituents = try NOAACoopsDecoding.harmonicConstituents(from: Fixtures.data("harcon_8518750"))
        let datums = try NOAACoopsDecoding.datums(from: Fixtures.data("datums_8518750"))
        let msl = try XCTUnwrap(datums.offset(of: .msl, relativeTo: .mllw))
        let tide = HarmonicPredictor(constituents: constituents, meanLevel: msl)
        let start = ISO8601DateFormatter().date(from: "2026-01-02T00:00:00Z")!
        let window = DateInterval(start: start, duration: 86_400)
        let setup = AnchorSetup(rodeLength: 25, bowHeight: 1.2, antennaAftOfBow: 8, draught: 1.8, chainWeightPerMeter: 17)
        let plan = AnchorPlan(anchor: .init(latitude: 40.70, longitude: -74.02), setup: setup, chartedDepth: 3, window: window, tide: tide)

        let extremes = tide.extrema(from: window.start, to: window.end)
        let low = try XCTUnwrap(extremes.filter { $0.kind == .low }.min { $0.height < $1.height })
        let high = try XCTUnwrap(extremes.filter { $0.kind == .high }.max { $0.height < $1.height })
        XCTAssertEqual(plan.minimumDepth, 3 + low.height, accuracy: 1e-9)
        XCTAssertEqual(plan.maximumDepth, 3 + high.height, accuracy: 1e-9)
        XCTAssertEqual(plan.maximumSwingRadius, SwingModel.tautReach(rodeLength: 25, verticalDrop: 3 + low.height + 1.2) + 8, accuracy: 1e-9)
        XCTAssertEqual(plan.minimumScope, 25 / (3 + high.height + 1.2), accuracy: 1e-9)
        // The Battery's ~1.4 m range moves the swing radius by ~0.3 m with this much rode.
        let minR = try XCTUnwrap(plan.samples.map(\.swingRadius).min())
        XCTAssertEqual(plan.maximumSwingRadius - minR, 0.39, accuracy: 0.05)
        // 25 m in 5.6 m of water at high tide is under 5:1.
        XCTAssertEqual(plan.advisories(), [.shortScope(minimum: plan.minimumScope, recommended: 5)])
        // Anchoring in 2 m with a 1.8 m keel goes aground at low water (MLLW lows here dip below 0).
        let shallow = AnchorPlan(anchor: plan.anchor, setup: setup, chartedDepth: 1.9, window: window, tide: tide)
        XCTAssertTrue(shallow.advisories(recommendedScope: 1).contains { if case .shallowAtLowWater = $0 { return true } else { return false } })
    }

    func testPlanWithoutTide() {
        let plan = AnchorPlan(anchor: .init(latitude: 0, longitude: 0), setup: AnchorSetup(rodeLength: 35, bowHeight: 1),
                              chartedDepth: 4, window: DateInterval(start: Date(), duration: 3_600), tide: nil)
        XCTAssertEqual(plan.samples.count, 1)
        XCTAssertEqual(plan.minimumScope, 7)
        XCTAssertEqual(plan.advisories(), [])
    }
}

final class AnchorWatchTests: XCTestCase {
    let anchor = GeoCoordinate(latitude: 41.2, longitude: -70.6) // off Martha's Vineyard
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    lazy var plane = LocalTangentPlane(origin: anchor)

    func gaussian(_ rng: inout SeededGenerator) -> Double {
        let u1 = Double.random(in: Double.ulpOfOne..<1, using: &rng), u2 = Double.random(in: 0..<1, using: &rng)
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }

    /// GPS-like noise: a slowly wandering bias (σ ≈ 3 m, ~2 min correlation) plus 1 m white noise.
    struct Noise {
        var bias = ENUVector.zero
        mutating func next(_ rng: inout SeededGenerator, _ g: (inout SeededGenerator) -> Double) -> ENUVector {
            let k = 0.99
            bias = bias * k + ENUVector(east: g(&rng), north: g(&rng)) * (3 * (1 - k * k).squareRoot())
            return bias + ENUVector(east: g(&rng), north: g(&rng))
        }
    }

    /// Two hours swinging through ±70° on a 30 m arc with realistic noise and 1 % wild
    /// fixes (60 m spikes): the watch must never alarm.
    func testSwingingWithNoiseAndSpikesNeverAlarms() {
        var rng = SeededGenerator(seed: 42)
        var noise = Noise()
        var watch = AnchorWatch(anchor: anchor, radius: 35)
        var alarms = 0, warnings = 0
        for s in stride(from: 0, to: 7_200, by: 1) {
            let angle = 225 + 70 * sin(2 * .pi * Double(s) / 900)
            var p = ENUVector(direction: angle, magnitude: 30) + noise.next(&rng, gaussian)
            if Double.random(in: 0..<1, using: &rng) < 0.01 { p = p + ENUVector(direction: Double.random(in: 0..<360, using: &rng), magnitude: 60) }
            let status = watch.update(with: PositionFix(coordinate: plane.unproject(p), horizontalAccuracy: 5, time: t0 + Double(s)))
            if status.isAlarm { alarms += 1 }
            if case .warning = status { warnings += 1 }
        }
        XCTAssertEqual(alarms, 0)
        XCTAssertLessThan(warnings, 60)
        XCTAssertGreaterThan(watch.rejectedFixes, 30) // the spikes were caught
    }

    /// The anchor breaks out after 30 minutes and the boat drags downwind at 0.5 kn.
    /// The alarm must sound soon after the boat leaves the circle, and not before.
    func testDraggingAlarmsPromptly() throws {
        var rng = SeededGenerator(seed: 7)
        var noise = Noise()
        // 30 m of reach plus 8 m for GPS wander (σ ≈ 3 m).
        var watch = AnchorWatch(anchor: anchor, radius: 38)
        let drag = Navigation.metersPerSecond(fromKnots: 0.5)
        var crossed: Date?, alarmed: Date?
        for s in stride(from: 0, to: 3_600, by: 1) {
            let t = t0 + Double(s)
            let base = ENUVector(direction: 225 + 20 * sin(Double(s) / 120), magnitude: 30)
            let truth = s < 1_800 ? base : base + ENUVector(direction: 225, magnitude: drag * Double(s - 1_800))
            if crossed == nil, truth.magnitude > 38 { crossed = t }
            let status = watch.update(with: PositionFix(coordinate: plane.unproject(truth + noise.next(&rng, gaussian)), horizontalAccuracy: 4, time: t))
            if status.isAlarm, alarmed == nil {
                alarmed = t
                if case .dragging = status {} else { XCTFail("expected dragging, got \(status)") }
            }
        }
        let c = try XCTUnwrap(crossed), a = try XCTUnwrap(alarmed, "never alarmed")
        let delay = a.timeIntervalSince(c)
        // Margin (2 m at 4 m accuracy) at 0.26 m/s, median lag, dwell and noise: well under 2 minutes.
        XCTAssertGreaterThan(delay, 0)
        XCTAssertLessThan(delay, 120)
    }

    func testGPSLostAndPoorFixes() {
        var watch = AnchorWatch(anchor: anchor, radius: 30)
        XCTAssertEqual(watch.status, .waiting)
        watch.update(with: PositionFix(coordinate: plane.unproject(ENUVector(east: 10, north: 0)), horizontalAccuracy: 5, time: t0))
        if case let .holding(d) = watch.status { XCTAssertEqual(d, 10, accuracy: 1e-6) } else { XCTFail("\(watch.status)") }
        // A 65 m-accuracy fix far outside is ignored.
        watch.update(with: PositionFix(coordinate: plane.unproject(ENUVector(east: 200, north: 0)), horizontalAccuracy: 65, time: t0 + 1))
        XCTAssertEqual(watch.rejectedFixes, 1)
        if case let .holding(d) = watch.status { XCTAssertEqual(d, 10, accuracy: 1e-6) } else { XCTFail("\(watch.status)") }
        XCTAssertEqual(watch.tick(at: t0 + 59), watch.status)
        XCTAssertEqual(watch.tick(at: t0 + 61), .gpsLost(since: t0))
        XCTAssertTrue(watch.status.isAlarm)
        // Recovers with the next good fix.
        watch.update(with: PositionFix(coordinate: plane.unproject(ENUVector(east: 0, north: 12)), horizontalAccuracy: 5, time: t0 + 70))
        if case .holding = watch.status {} else { XCTFail("\(watch.status)") }
    }

    func testRealMoveIsAcceptedAfterRepeatedSpikes() {
        var watch = AnchorWatch(anchor: anchor, radius: 30)
        for s in 0..<10 { watch.update(with: PositionFix(coordinate: plane.unproject(ENUVector(east: 5, north: 0)), horizontalAccuracy: 3, time: t0 + Double(s))) }
        // The boat really is 150 m away now (e.g. the watch was set on the wrong spot).
        var last = watch.status
        for s in 10..<60 { last = watch.update(with: PositionFix(coordinate: plane.unproject(ENUVector(east: 150, north: 0)), horizontalAccuracy: 3, time: t0 + Double(s))) }
        if case let .dragging(d, _) = last { XCTAssertEqual(d, 150, accuracy: 0.01) } else { XCTFail("\(last)") }
    }

    func testCreepingWarning() {
        var watch = AnchorWatch(anchor: anchor, radius: 80)
        // Swinging around a centre that creeps 25 m over 20 minutes, inside a generous circle.
        var status = watch.status
        for s in stride(from: 0, to: 1_200, by: 5) {
            let centre = ENUVector(east: 0, north: -20 - 25 * Double(s) / 1_200)
            let p = centre + ENUVector(direction: 360 * Double(s) / 300, magnitude: 8)
            status = watch.update(with: PositionFix(coordinate: plane.unproject(p), horizontalAccuracy: 3, time: t0 + Double(s)))
        }
        guard case let .warning(_, .creeping(m)) = status else { return XCTFail("\(status)") }
        XCTAssertEqual(m, 12.5, accuracy: 3)
    }

    func testAnchorPositionAndCircleFit() throws {
        let antenna = GeoCoordinate(latitude: 41.2, longitude: -70.6)
        let dropped = AnchorWatch.anchorPosition(antenna: antenna, heading: 90, antennaAftOfBow: 10)
        XCTAssertEqual(Geodesy.inverse(from: antenna, to: dropped).distance, 10, accuracy: 1e-6)
        XCTAssertEqual(Geodesy.inverse(from: antenna, to: dropped).initialBearing, 90, accuracy: 1e-6)

        // A 120° arc of noisy fixes on a 40 m circle around a known anchor.
        var rng = SeededGenerator(seed: 3)
        let pts = (0..<300).map { i -> GeoCoordinate in
            let p = ENUVector(direction: 180 + 120 * Double(i) / 299, magnitude: 40) + ENUVector(east: gaussian(&rng), north: gaussian(&rng)) * 2
            return plane.unproject(p)
        }
        let fit = try XCTUnwrap(AnchorWatch.estimateAnchor(from: pts))
        XCTAssertLessThan(Geodesy.inverse(from: fit.anchor, to: anchor).distance, 3)
        XCTAssertEqual(fit.radius, 40, accuracy: 3)
        XCTAssertNil(AnchorWatch.estimateAnchor(from: [anchor, anchor, anchor]))
    }
}
