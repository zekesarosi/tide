import XCTest
@testable import TideKit

/// CPA/TCPA against closed-form geometry.
final class CollisionAvoidanceTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let origin = GeoCoordinate(latitude: 40.55, longitude: -73.95) // Lower Bay, NY
    let nm = Navigation.metersPerNauticalMile

    func offset(_ east: Double, _ north: Double) -> GeoCoordinate {
        LocalTangentPlane(origin: origin).unproject(ENUVector(east: east * nm, north: north * nm))
    }

    /// Own ship north at 10 kn; target 2 nm E, 2 nm N, heading west at 10 kn.
    /// Both reach (0, 2 nm) after 12 minutes: a collision.
    func testCrossingCollisionCourse() {
        let own = KinematicState(position: origin, speedOverGround: 10, courseOverGround: 0, time: t0)
        let tgt = KinematicState(position: offset(2, 2), speedOverGround: 10, courseOverGround: 270, time: t0)
        let a = CollisionAvoidance.closestApproach(own: own, target: tgt)
        XCTAssertEqual(a.timeToCPA, 720, accuracy: 1)
        XCTAssertEqual(a.distanceAtCPA, 0, accuracy: 5)
        XCTAssertEqual(a.range, 2 * 2.0.squareRoot() * nm, accuracy: 2)
        XCTAssertEqual(a.bearing, 45, accuracy: 0.05)
        XCTAssertEqual(GreatCircle.distance(from: a.ownPositionAtCPA, to: offset(0, 2)), 0, accuracy: 10)
        XCTAssertEqual(CollisionAvoidance.threat(of: a, thresholds: .init()), .dangerous)
    }

    /// Reciprocal courses, 0.5 nm apart laterally, 6 nm ahead, closing at 20 kn:
    /// TCPA = 18 min, CPA = 0.5 nm (passing port to port).
    func testHeadOnOffset() {
        let own = KinematicState(position: origin, speedOverGround: 10, courseOverGround: 0, time: t0)
        let tgt = KinematicState(position: offset(0.5, 6), speedOverGround: 10, courseOverGround: 180, time: t0)
        let a = CollisionAvoidance.closestApproach(own: own, target: tgt)
        XCTAssertEqual(a.timeToCPA, 18 * 60, accuracy: 1)
        XCTAssertEqual(a.distanceAtCPA / nm, 0.5, accuracy: 0.002)
        // 0.5 nm is on the default limit; a 0.3 nm limit makes it merely closing.
        XCTAssertEqual(CollisionAvoidance.threat(of: a, thresholds: .init(cpaLimit: 0.3 * nm)), .closing)
    }

    func testParallelSameSpeedHasNoRelativeMotion() {
        let own = KinematicState(position: origin, speedOverGround: 7, courseOverGround: 90, time: t0)
        let tgt = KinematicState(position: offset(0, 1), speedOverGround: 7, courseOverGround: 90, time: t0)
        let a = CollisionAvoidance.closestApproach(own: own, target: tgt)
        XCTAssertEqual(a.timeToCPA, 0)
        XCTAssertEqual(a.distanceAtCPA / nm, 1, accuracy: 0.001)
        XCTAssertFalse(a.isClosing)
    }

    func testOpeningTargetHasNegativeTCPA() {
        let own = KinematicState(position: origin, speedOverGround: 6, courseOverGround: 0, time: t0)
        let tgt = KinematicState(position: offset(0, -1), speedOverGround: 6, courseOverGround: 180, time: t0)
        let a = CollisionAvoidance.closestApproach(own: own, target: tgt)
        XCTAssertLessThan(a.timeToCPA, 0)
        XCTAssertEqual(a.distanceAtCPA, a.range, accuracy: 1e-6)
        XCTAssertEqual(CollisionAvoidance.threat(of: a, thresholds: .init()), .none)
    }

    /// A report 60 s old is dead-reckoned to now before computing CPA.
    func testStaleReportIsExtrapolated() {
        let own = KinematicState(position: origin, speedOverGround: 0, courseOverGround: 0, time: t0 + 60)
        // 60 s ago the target was 1 nm south heading north at 12 kn: now it is 0.8 nm south.
        let tgt = KinematicState(position: offset(0, -1), speedOverGround: 12, courseOverGround: 0, time: t0)
        let a = CollisionAvoidance.closestApproach(own: own, target: tgt)
        XCTAssertEqual(a.range / nm, 0.8, accuracy: 0.001)
        XCTAssertEqual(a.timeToCPA, 240, accuracy: 0.5)
    }

    func testTargetTableMergesAndRanksThreats() throws {
        var table = AISTargetTable()
        var d = AISDecoder()
        // Static data for the type 5 vessel, then a synthetic position report for it.
        for l in ["!AIVDM,2,1,1,A,55?MbV02;H;s<HtKR20EHE:0@T4@Dn2222222216L961O5Gf0NSQEp6ClRp8,0*1C", "!AIVDM,2,2,1,A,88888888880,2*25"] {
            if let m = try d.decode(line: l, at: t0)?.message { table.ingest(m, at: t0) }
        }
        let collider = AISMessage(type: 1, repeatIndicator: 0, mmsi: 351759000, body: .position(.init(
            navigationStatus: .underWayUsingEngine, rateOfTurn: nil, speedOverGround: 10, positionAccuracyHigh: true,
            position: offset(2, 2), courseOverGround: 270, trueHeading: 270, timestampSecond: 0, raim: false, isClassB: false), staticData: nil))
        let passer = AISMessage(type: 18, repeatIndicator: 0, mmsi: 338091445, body: .position(.init(
            navigationStatus: nil, rateOfTurn: nil, speedOverGround: 10, positionAccuracyHigh: true,
            position: offset(3, 6), courseOverGround: 180, trueHeading: nil, timestampSecond: 0, raim: false, isClassB: true), staticData: nil))
        table.ingest(collider, at: t0)
        table.ingest(passer, at: t0)
        let own = KinematicState(position: origin, speedOverGround: 10, courseOverGround: 0, time: t0)
        let ranked = table.assess(own: own, at: t0)
        XCTAssertEqual(ranked.count, 2)
        XCTAssertEqual(ranked[0].target.name, "EVER DIADEM")
        XCTAssertEqual(ranked[0].target.dimensions?.length, 295)
        XCTAssertEqual(ranked[0].threat, .dangerous)
        XCTAssertEqual(ranked[1].threat, .closing)
        XCTAssertTrue(ranked[1].target.isClassB)
        // Positions go stale for assessment, then targets expire.
        XCTAssertEqual(table.assess(own: own.extrapolated(to: t0 + 400), at: t0 + 400).count, 0)
        table.expire(at: t0 + 601)
        XCTAssertTrue(table.targets.isEmpty)
    }

    func testEmergencyDeviceMMSI() {
        let sart = AISMessage(type: 1, repeatIndicator: 0, mmsi: 970_123_456, body: .unsupported)
        XCTAssertTrue(sart.isEmergencyDevice)
        XCTAssertFalse(AISMessage(type: 1, repeatIndicator: 0, mmsi: 366_053_209, body: .unsupported).isEmergencyDevice)
    }
}
