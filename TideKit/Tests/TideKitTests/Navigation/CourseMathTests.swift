import XCTest
@testable import TideKit

final class CourseMathTests: XCTestCase {
    /// Textbook vector triangle: track 090°, 5 kn through the water, stream setting 180° at 1 kn.
    /// Steer 090° − asin(1/5) = 078.46°; SOG = 5·cos(11.54°) = 4.899 kn.
    func testCourseToSteerCrossCurrent() throws {
        let s = try XCTUnwrap(CurrentTriangle.courseToSteer(course: 90, speedThroughWater: 5, set: 180, drift: 1))
        XCTAssertEqual(s.heading, 90 - asin(0.2) * 180 / .pi, accuracy: 1e-9)
        XCTAssertEqual(s.heading, 78.463, accuracy: 0.001)
        XCTAssertEqual(s.speedOverGround, 24.0.squareRoot(), accuracy: 1e-9)
        // Steering that heading really makes good 090°.
        let g = CurrentTriangle.groundTrack(heading: s.heading, speedThroughWater: 5, set: 180, drift: 1)
        XCTAssertEqual(g.course, 90, accuracy: 1e-9)
        XCTAssertEqual(g.speed, s.speedOverGround, accuracy: 1e-9)
    }

    func testCourseToSteerFairAndFoulStream() throws {
        let fair = try XCTUnwrap(CurrentTriangle.courseToSteer(course: 45, speedThroughWater: 6, set: 45, drift: 2))
        XCTAssertEqual(fair.heading, 45, accuracy: 1e-9)
        XCTAssertEqual(fair.speedOverGround, 8, accuracy: 1e-9)
        let foul = try XCTUnwrap(CurrentTriangle.courseToSteer(course: 45, speedThroughWater: 6, set: 225, drift: 2))
        XCTAssertEqual(foul.speedOverGround, 4, accuracy: 1e-9)
        // A 7 kn foul stream stops a 6 kn boat.
        XCTAssertNil(CurrentTriangle.courseToSteer(course: 45, speedThroughWater: 6, set: 225, drift: 7))
        // A cross stream faster than the boat can't be stemmed.
        XCTAssertNil(CurrentTriangle.courseToSteer(course: 0, speedThroughWater: 3, set: 90, drift: 4))
    }

    func testCourseToSteerWithLeeway() throws {
        // 5° leeway to starboard: steer 5° further to port than the water track.
        let s = try XCTUnwrap(CurrentTriangle.courseToSteer(course: 90, speedThroughWater: 5, set: 0, drift: 0, leeway: 5))
        XCTAssertEqual(s.heading, 85, accuracy: 1e-9)
        let g = CurrentTriangle.groundTrack(heading: 85, speedThroughWater: 5, set: 0, drift: 0, leeway: 5)
        XCTAssertEqual(g.course, 90, accuracy: 1e-9)
    }

    func testSetAndDriftRoundTrip() {
        let g = CurrentTriangle.groundTrack(heading: 350, speedThroughWater: 6, set: 120, drift: 1.5)
        let sd = CurrentTriangle.setAndDrift(heading: 350, speedThroughWater: 6, courseOverGround: g.course, speedOverGround: g.speed)
        XCTAssertEqual(sd.set, 120, accuracy: 1e-9)
        XCTAssertEqual(sd.drift, 1.5, accuracy: 1e-9)
    }

    func testVMGAndETA() {
        XCTAssertEqual(Passage.velocityMadeGood(courseOverGround: 60, speedOverGround: 6, towardBearing: 0), 3, accuracy: 1e-12)
        XCTAssertEqual(Passage.velocityMadeGood(courseOverGround: 180, speedOverGround: 6, towardBearing: 0), -6, accuracy: 1e-12)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let eta = Passage.eta(distance: Navigation.meters(fromNauticalMiles: 30), speed: Navigation.metersPerSecond(fromKnots: 6), from: now)
        XCTAssertEqual(eta!.timeIntervalSince(now), 5 * 3_600, accuracy: 1e-6)
        XCTAssertNil(Passage.eta(distance: 1_000, speed: 0, from: now))
    }

    func testRouteLegsAndProgress() throws {
        // The Battery → Sandy Hook → Ambrose: two rhumb-line legs.
        let route = Route(waypoints: [
            .init(latitude: 40.70, longitude: -74.02),
            .init(latitude: 40.48, longitude: -74.01),
            .init(latitude: 40.45, longitude: -73.83),
        ])
        let legs = route.legs
        XCTAssertEqual(legs.count, 2)
        XCTAssertEqual(route.totalDistance, legs[0].distance + legs[1].distance, accuracy: 1e-9)
        XCTAssertEqual(legs[0].bearing, 178, accuracy: 1) // nearly due south
        // A boat 100 m east (to port, heading south) of the first leg's midpoint.
        let mid = RhumbLine.destination(from: legs[0].start, bearing: legs[0].bearing, distance: legs[0].distance / 2)
        let boat = Geodesy.direct(from: mid, bearing: legs[0].bearing - 90, distance: 100).coordinate
        let p = try XCTUnwrap(route.progress(of: boat, onLeg: 0))
        XCTAssertEqual(p.crossTrack, -100, accuracy: 0.5)
        XCTAssertEqual(p.along, legs[0].distance / 2, accuracy: 1)
        let remaining = try XCTUnwrap(route.distanceRemaining(from: boat, onLeg: 0))
        XCTAssertEqual(remaining, legs[0].distance / 2 + legs[1].distance, accuracy: 1)
        XCTAssertNil(route.progress(of: boat, onLeg: 5))
    }
}
