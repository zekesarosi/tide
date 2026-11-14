import XCTest
@testable import TideKit

/// Geodesics, rhumb lines and great-circle helpers against published references:
/// GeographicLib 2.1 (Karney) for WGS 84 geodesics, Vincenty's own 1975 example
/// (Flinders Peak → Buninyong), and Chris Veness's Movable Type worked examples.
final class GeodesyTests: XCTestCase {
    struct Case {
        let name: String
        let a: GeoCoordinate, b: GeoCoordinate
        let distance: Double, azi1: Double, azi2: Double
    }

    /// GeographicLib `Geodesic.WGS84.Inverse` (azimuths in [−180, 180) as it prints them).
    static let karney: [Case] = [
        Case(name: "Statue of Liberty → Westminster", a: .init(latitude: 40.6892, longitude: -74.0445),
             b: .init(latitude: 51.5007, longitude: -0.1246), distance: 5_589_857.3675, azi1: 51.223530251, azi2: 108.376207877),
        Case(name: "Golden Gate → Honolulu", a: .init(latitude: 37.8199, longitude: -122.4783),
             b: .init(latitude: 21.3069, longitude: -157.8583), distance: 3_853_627.5067, azi1: -108.211940208, azi2: -126.284991100),
        Case(name: "Sydney → Wellington", a: .init(latitude: -33.8568, longitude: 151.2153),
             b: .init(latitude: -41.2865, longitude: 174.7762), distance: 2_229_883.3232, azi1: 118.583553803, azi2: 104.058277991),
        Case(name: "Land's End → John o' Groats (approx.)", a: .init(latitude: 50, longitude: -5),
             b: .init(latitude: 58, longitude: -3), distance: 899_937.7057, azi1: 7.575054368, azi2: 9.197101983),
        Case(name: "Along a parallel", a: .init(latitude: 41, longitude: -71),
             b: .init(latitude: 41, longitude: -70), distance: 84_134.7255, azi1: 89.671965724, azi2: 90.328034276),
        Case(name: "Flinders Peak → Buninyong (Vincenty 1975)", a: .init(latitude: -37.95103342, longitude: 144.42486789),
             b: .init(latitude: -37.65282114, longitude: 143.92649554), distance: 54_972.2705, azi1: -53.131839974, azi2: -52.826368554),
        Case(name: "14 m", a: .init(latitude: 37.8, longitude: -122.4),
             b: .init(latitude: 37.8001, longitude: -122.4001), distance: 14.1689, azi1: -38.431240423, azi2: -38.431301713),
    ]

    func testVincentyInverseMatchesGeographicLib() {
        for c in Self.karney {
            let s = Geodesy.inverse(from: c.a, to: c.b)
            XCTAssertEqual(s.distance, c.distance, accuracy: 0.001, c.name) // 1 mm
            XCTAssertEqual(Navigation.angleDifference(from: c.azi1, to: s.initialBearing), 0, accuracy: 1e-6, c.name)
            XCTAssertEqual(Navigation.angleDifference(from: c.azi2, to: s.finalBearing), 0, accuracy: 1e-6, c.name)
        }
    }

    func testVincentyDirectMatchesGeographicLib() {
        // Vincenty's example: Flinders Peak, 306°52′05.37″, 54 972.271 m → Buninyong.
        let r = Geodesy.direct(from: .init(latitude: -37.95103342, longitude: 144.42486789), bearing: 306.86815920, distance: 54_972.271)
        XCTAssertEqual(r.coordinate.latitude, -37.652821143, accuracy: 1e-8)
        XCTAssertEqual(r.coordinate.longitude, 143.926495530, accuracy: 1e-8)
        XCTAssertEqual(r.finalBearing, 360 - 52.826369375, accuracy: 1e-6)

        let long = Geodesy.direct(from: .init(latitude: 40, longitude: -70), bearing: 45, distance: 1_852 * 500)
        XCTAssertEqual(long.coordinate.latitude, 45.605360141, accuracy: 1e-8)
        XCTAssertEqual(long.coordinate.longitude, -61.606100210, accuracy: 1e-8)
        XCTAssertEqual(long.finalBearing, 50.715807039, accuracy: 1e-6)
    }

    func testDirectInverseRoundTrip() {
        for c in Self.karney {
            let s = Geodesy.inverse(from: c.a, to: c.b)
            let d = Geodesy.direct(from: c.a, bearing: s.initialBearing, distance: s.distance)
            XCTAssertEqual(Geodesy.inverse(from: d.coordinate, to: c.b).distance, 0, accuracy: 1e-4, c.name)
        }
    }

    /// Vincenty does not converge here; we fall back to the sphere (GeographicLib: 19 944 127.42 m).
    func testNearlyAntipodalFallsBackGracefully() {
        let s = Geodesy.inverse(from: .init(latitude: 0, longitude: 0), to: .init(latitude: 0.5, longitude: 179.7))
        XCTAssertEqual(s.distance, 19_944_127.4208, accuracy: 0.006 * 19_944_127.4208)
    }

    func testCoincidentPoints() {
        let p = GeoCoordinate(latitude: 12, longitude: 34)
        XCTAssertEqual(Geodesy.inverse(from: p, to: p).distance, 0)
        XCTAssertEqual(RhumbLine.inverse(from: p, to: p).distance, 0)
    }

    // MARK: Rhumb lines

    /// Reference: isometric latitude ψ = asinh(tan φ) − e·atanh(e sin φ) with the meridian
    /// arc from GeographicLib, evaluated independently in Python.
    func testRhumbLineInverse() {
        let cases: [(GeoCoordinate, GeoCoordinate, Double, Double)] = [
            (.init(latitude: 40.6892, longitude: -74.0445), .init(latitude: 51.5007, longitude: -0.1246), 5_814_788.7575, 78.072833320),
            (.init(latitude: 50, longitude: -5), .init(latitude: 58, longitude: -3), 899_967.6495, 8.346428974),
            (.init(latitude: -33.8568, longitude: 151.2153), .init(latitude: -41.2865, longitude: 174.7762), 2_235_813.3188, 111.642884623),
            (.init(latitude: 37.8199, longitude: -122.4783), .init(latitude: 21.3069, longitude: -157.8583), 3_869_254.3698, 241.765848660),
            (.init(latitude: 41, longitude: -71), .init(latitude: 41, longitude: -70), 84_135.1851, 90),
        ]
        for (a, b, dist, brg) in cases {
            let r = RhumbLine.inverse(from: a, to: b)
            XCTAssertEqual(r.distance, dist, accuracy: 0.001)
            XCTAssertEqual(r.bearing, brg, accuracy: 1e-8)
            // A rhumb line is never shorter than the geodesic.
            XCTAssertGreaterThanOrEqual(r.distance, Geodesy.inverse(from: a, to: b).distance)
            // Destination along the rhumb line lands on b.
            let d = RhumbLine.destination(from: a, bearing: r.bearing, distance: r.distance)
            XCTAssertEqual(d.latitude, b.latitude, accuracy: 1e-9)
            XCTAssertEqual(d.longitude, b.longitude, accuracy: 1e-9)
        }
    }

    func testRhumbLineCrossesAntimeridian() {
        let a = GeoCoordinate(latitude: -17.7, longitude: 178.0), b = GeoCoordinate(latitude: -18.1, longitude: -178.5)
        let r = RhumbLine.inverse(from: a, to: b)
        XCTAssertGreaterThan(r.bearing, 90); XCTAssertLessThan(r.bearing, 180)
        XCTAssertLessThan(r.distance, 400_000)
        let d = RhumbLine.destination(from: a, bearing: r.bearing, distance: r.distance)
        XCTAssertEqual(d.longitude, -178.5, accuracy: 1e-9)
    }

    // MARK: Great circles (Movable Type examples, R = 6371 km)

    func testCrossTrackAndAlongTrackMovableType() {
        let start = GeoCoordinate(latitude: 53.3206, longitude: -1.7297)
        let end = GeoCoordinate(latitude: 53.1887, longitude: 0.1334)
        let p = GeoCoordinate(latitude: 53.2611, longitude: -0.7972)
        let r = 6_371_000.0
        XCTAssertEqual(GreatCircle.crossTrackDistance(of: p, from: start, to: end, radius: r), -307.5, accuracy: 0.1)
        XCTAssertEqual(GreatCircle.alongTrackDistance(of: p, from: start, to: end, radius: r), 62_331, accuracy: 1)
        // Behind the start point the along-track distance is negative.
        let behind = GreatCircle.destination(from: start, bearing: 270, distance: 5_000)
        XCTAssertLessThan(GreatCircle.alongTrackDistance(of: behind, from: start, to: end), 0)
    }

    func testDestinationAndBearingMovableType() {
        // 53°19′14″N 001°43′47″W, 096°01′18″, 124.8 km → 53°11′18″N 000°08′00″E.
        let a = GeoCoordinate(latitude: 53 + 19 / 60.0 + 14 / 3600.0, longitude: -(1 + 43 / 60.0 + 47 / 3600.0))
        let d = GreatCircle.destination(from: a, bearing: 96 + 1 / 60.0 + 18 / 3600.0, distance: 124_800, radius: 6_371_000)
        XCTAssertEqual(d.latitude, 53 + 11 / 60.0 + 18 / 3600.0, accuracy: 1 / 3600.0)
        XCTAssertEqual(d.longitude, 8 / 60.0, accuracy: 1 / 3600.0)
        // Land's End 50°03′59″N 005°42′53″W → John o' Groats 58°38′38″N 003°04′12″W:
        // 968.9 km, initial bearing 009°07′11″.
        let landsEnd = GeoCoordinate(latitude: 50 + 3 / 60.0 + 59 / 3600.0, longitude: -(5 + 42 / 60.0 + 53 / 3600.0))
        let johnOGroats = GeoCoordinate(latitude: 58 + 38 / 60.0 + 38 / 3600.0, longitude: -(3 + 4 / 60.0 + 12 / 3600.0))
        XCTAssertEqual(GreatCircle.distance(from: landsEnd, to: johnOGroats, radius: 6_371_000), 968_900, accuracy: 50)
        XCTAssertEqual(GreatCircle.initialBearing(from: landsEnd, to: johnOGroats), 9 + 7 / 60.0 + 11 / 3600.0, accuracy: 1 / 3600.0)
    }

    func testIntermediateAndDensify() {
        let a = GeoCoordinate(latitude: 37.8199, longitude: -122.4783), b = GeoCoordinate(latitude: 21.3069, longitude: -157.8583)
        let mid = GreatCircle.intermediate(from: a, to: b, fraction: 0.5)
        XCTAssertEqual(GreatCircle.distance(from: a, to: mid), GreatCircle.distance(from: mid, to: b), accuracy: 0.01)
        let pts = GreatCircle.densify(from: a, to: b, maxSegment: 100_000)
        XCTAssertEqual(pts.first!.latitude, a.latitude, accuracy: 1e-9)
        XCTAssertEqual(pts.last!.latitude, b.latitude, accuracy: 1e-9)
        for (p, q) in zip(pts, pts.dropFirst()) { XCTAssertLessThanOrEqual(GreatCircle.distance(from: p, to: q), 100_000) }
        // Every densified point is on the track.
        for p in pts { XCTAssertEqual(GreatCircle.crossTrackDistance(of: p, from: a, to: b), 0, accuracy: 0.01) }
    }

    func testLocalTangentPlaneRoundTripAndScale() {
        let o = GeoCoordinate(latitude: 40.7006, longitude: -74.0142)
        let plane = LocalTangentPlane(origin: o)
        let p = Geodesy.direct(from: o, bearing: 60, distance: 500).coordinate
        let v = plane.project(p)
        XCTAssertEqual(v.magnitude, 500, accuracy: 0.05)
        XCTAssertEqual(v.direction, 60, accuracy: 0.01)
        let back = plane.unproject(v)
        XCTAssertEqual(back.latitude, p.latitude, accuracy: 1e-12)
        XCTAssertEqual(back.longitude, p.longitude, accuracy: 1e-12)
    }

    func testAngleHelpers() {
        XCTAssertEqual(Navigation.wrap360(-10), 350)
        XCTAssertEqual(Navigation.wrap180(190), -170)
        XCTAssertEqual(Navigation.angleDifference(from: 350, to: 10), 20)
        XCTAssertEqual(Navigation.angleDifference(from: 10, to: 350), -20)
        XCTAssertEqual(Navigation.knots(fromMetersPerSecond: 1_852.0 / 3_600), 1, accuracy: 1e-12)
    }
}
