import Foundation

/// A reference ellipsoid.
public struct Ellipsoid: Sendable, Hashable {
    /// Semi-major axis, metres.
    public let semiMajorAxis: Double
    /// Flattening.
    public let flattening: Double

    public static let wgs84 = Ellipsoid(semiMajorAxis: 6_378_137.0, flattening: 1 / 298.257223563)

    public var semiMinorAxis: Double { semiMajorAxis * (1 - flattening) }
    public var eccentricitySquared: Double { flattening * (2 - flattening) }
    /// Mean radius R₁ = (2a + b) / 3, used by the spherical formulas.
    public var meanRadius: Double { (2 * semiMajorAxis + semiMinorAxis) / 3 }
}

/// Distance and azimuths between two points.
public struct GeodesicSolution: Sendable, Hashable {
    /// Metres along the line.
    public var distance: Double
    /// Bearing at the start, degrees true in [0, 360).
    public var initialBearing: Double
    /// Forward bearing at the end, degrees true in [0, 360).
    public var finalBearing: Double
}

/// Geodesics (shortest paths) on the WGS 84 ellipsoid by Vincenty's method
/// (Survey Review 1975), plus spherical great-circle helpers.
///
/// Vincenty's inverse agrees with Karney's GeographicLib to well under a millimetre
/// for any pair that is not nearly antipodal. Within about half a degree of the
/// antipode it can fail to converge; those pairs (never a single navigational leg)
/// fall back to the spherical great circle, which is good to about 0.5 %.
public enum Geodesy {
    // MARK: Ellipsoidal (Vincenty)

    /// Shortest distance and bearings from `a` to `b` on the ellipsoid.
    public static func inverse(from a: GeoCoordinate, to b: GeoCoordinate, ellipsoid e: Ellipsoid = .wgs84) -> GeodesicSolution {
        if a.latitude == b.latitude && Navigation.wrap180(a.longitude - b.longitude) == 0 {
            return GeodesicSolution(distance: 0, initialBearing: 0, finalBearing: 0)
        }
        if let s = vincentyInverse(a, b, e) { return s }
        let s = GreatCircle.distance(from: a, to: b, radius: e.meanRadius)
        return GeodesicSolution(distance: s, initialBearing: GreatCircle.initialBearing(from: a, to: b),
                                finalBearing: GreatCircle.finalBearing(from: a, to: b))
    }

    /// The point reached by travelling `distance` metres from `start` on initial bearing `bearing`.
    public static func direct(from start: GeoCoordinate, bearing: Double, distance: Double,
                              ellipsoid e: Ellipsoid = .wgs84) -> (coordinate: GeoCoordinate, finalBearing: Double) {
        let a = e.semiMajorAxis, f = e.flattening, b = e.semiMinorAxis
        let alpha1 = bearing * .pi / 180
        let sinA1 = sin(alpha1), cosA1 = cos(alpha1)
        let tanU1 = (1 - f) * tan(start.latitude * .pi / 180)
        let cosU1 = 1 / (1 + tanU1 * tanU1).squareRoot(), sinU1 = tanU1 * cosU1
        let sigma1 = atan2(tanU1, cosA1)
        let sinAlpha = cosU1 * sinA1
        let cos2Alpha = 1 - sinAlpha * sinAlpha
        let uSq = cos2Alpha * (a * a - b * b) / (b * b)
        let bigA = 1 + uSq / 16384 * (4096 + uSq * (-768 + uSq * (320 - 175 * uSq)))
        let bigB = uSq / 1024 * (256 + uSq * (-128 + uSq * (74 - 47 * uSq)))

        var sigma = distance / (b * bigA)
        var sinSigma = 0.0, cosSigma = 0.0, cos2SigmaM = 0.0
        for _ in 0..<200 {
            cos2SigmaM = cos(2 * sigma1 + sigma)
            sinSigma = sin(sigma); cosSigma = cos(sigma)
            let dSigma = bigB * sinSigma * (cos2SigmaM + bigB / 4 * (cosSigma * (-1 + 2 * cos2SigmaM * cos2SigmaM)
                - bigB / 6 * cos2SigmaM * (-3 + 4 * sinSigma * sinSigma) * (-3 + 4 * cos2SigmaM * cos2SigmaM)))
            let next = distance / (b * bigA) + dSigma
            if abs(next - sigma) < 1e-12 { sigma = next; break }
            sigma = next
        }
        cos2SigmaM = cos(2 * sigma1 + sigma)
        sinSigma = sin(sigma); cosSigma = cos(sigma)

        let x = sinU1 * sinSigma - cosU1 * cosSigma * cosA1
        let phi2 = atan2(sinU1 * cosSigma + cosU1 * sinSigma * cosA1, (1 - f) * (sinAlpha * sinAlpha + x * x).squareRoot())
        let lambda = atan2(sinSigma * sinA1, cosU1 * cosSigma - sinU1 * sinSigma * cosA1)
        let c = f / 16 * cos2Alpha * (4 + f * (4 - 3 * cos2Alpha))
        let l = lambda - (1 - c) * f * sinAlpha * (sigma + c * sinSigma * (cos2SigmaM + c * cosSigma * (-1 + 2 * cos2SigmaM * cos2SigmaM)))
        let alpha2 = atan2(sinAlpha, -x)
        let end = GeoCoordinate(latitude: phi2 * 180 / .pi, longitude: Navigation.wrap180(start.longitude + l * 180 / .pi))
        return (end, Navigation.wrap360(alpha2 * 180 / .pi))
    }

    static func vincentyInverse(_ p1: GeoCoordinate, _ p2: GeoCoordinate, _ e: Ellipsoid) -> GeodesicSolution? {
        let a = e.semiMajorAxis, f = e.flattening, b = e.semiMinorAxis
        let l = Navigation.wrap180(p2.longitude - p1.longitude) * .pi / 180
        let tanU1 = (1 - f) * tan(p1.latitude * .pi / 180), tanU2 = (1 - f) * tan(p2.latitude * .pi / 180)
        let cosU1 = 1 / (1 + tanU1 * tanU1).squareRoot(), sinU1 = tanU1 * cosU1
        let cosU2 = 1 / (1 + tanU2 * tanU2).squareRoot(), sinU2 = tanU2 * cosU2

        var lambda = l
        var sinLambda = 0.0, cosLambda = 0.0, sinSigma = 0.0, cosSigma = 0.0, sigma = 0.0
        var cos2Alpha = 0.0, cos2SigmaM = 0.0, sinAlpha = 0.0
        var converged = false
        for _ in 0..<200 {
            sinLambda = sin(lambda); cosLambda = cos(lambda)
            let t1 = cosU2 * sinLambda, t2 = cosU1 * sinU2 - sinU1 * cosU2 * cosLambda
            sinSigma = (t1 * t1 + t2 * t2).squareRoot()
            if sinSigma == 0 { return GeodesicSolution(distance: 0, initialBearing: 0, finalBearing: 0) }
            cosSigma = sinU1 * sinU2 + cosU1 * cosU2 * cosLambda
            sigma = atan2(sinSigma, cosSigma)
            sinAlpha = cosU1 * cosU2 * sinLambda / sinSigma
            cos2Alpha = 1 - sinAlpha * sinAlpha
            cos2SigmaM = cos2Alpha != 0 ? cosSigma - 2 * sinU1 * sinU2 / cos2Alpha : 0 // equatorial line
            let c = f / 16 * cos2Alpha * (4 + f * (4 - 3 * cos2Alpha))
            let next = l + (1 - c) * f * sinAlpha * (sigma + c * sinSigma * (cos2SigmaM + c * cosSigma * (-1 + 2 * cos2SigmaM * cos2SigmaM)))
            if abs(next) > .pi { return nil } // antipodal: no convergence
            if abs(next - lambda) < 1e-12 { lambda = next; converged = true; break }
            lambda = next
        }
        guard converged else { return nil }
        sinLambda = sin(lambda); cosLambda = cos(lambda)

        let uSq = cos2Alpha * (a * a - b * b) / (b * b)
        let bigA = 1 + uSq / 16384 * (4096 + uSq * (-768 + uSq * (320 - 175 * uSq)))
        let bigB = uSq / 1024 * (256 + uSq * (-128 + uSq * (74 - 47 * uSq)))
        let dSigma = bigB * sinSigma * (cos2SigmaM + bigB / 4 * (cosSigma * (-1 + 2 * cos2SigmaM * cos2SigmaM)
            - bigB / 6 * cos2SigmaM * (-3 + 4 * sinSigma * sinSigma) * (-3 + 4 * cos2SigmaM * cos2SigmaM)))
        let s = b * bigA * (sigma - dSigma)
        let alpha1 = atan2(cosU2 * sinLambda, cosU1 * sinU2 - sinU1 * cosU2 * cosLambda)
        let alpha2 = atan2(cosU1 * sinLambda, -sinU1 * cosU2 + cosU1 * sinU2 * cosLambda)
        return GeodesicSolution(distance: s, initialBearing: Navigation.wrap360(alpha1 * 180 / .pi),
                                finalBearing: Navigation.wrap360(alpha2 * 180 / .pi))
    }
}

/// Great circles on a sphere (default: WGS 84 mean radius). Used for cross-track
/// geometry and for densifying routes; use `Geodesy` for precise distances.
public enum GreatCircle {
    public static var defaultRadius: Double { Ellipsoid.wgs84.meanRadius }

    /// Haversine distance, metres.
    public static func distance(from a: GeoCoordinate, to b: GeoCoordinate, radius: Double = defaultRadius) -> Double {
        radius * angularDistance(a, b)
    }

    static func angularDistance(_ a: GeoCoordinate, _ b: GeoCoordinate) -> Double {
        let p1 = a.latitude * .pi / 180, p2 = b.latitude * .pi / 180
        let dp = p2 - p1, dl = Navigation.wrap180(b.longitude - a.longitude) * .pi / 180
        let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * atan2(h.squareRoot(), (1 - h).squareRoot())
    }

    /// Initial bearing, degrees true.
    public static func initialBearing(from a: GeoCoordinate, to b: GeoCoordinate) -> Double {
        let p1 = a.latitude * .pi / 180, p2 = b.latitude * .pi / 180
        let dl = Navigation.wrap180(b.longitude - a.longitude) * .pi / 180
        let y = sin(dl) * cos(p2)
        let x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
        return Navigation.wrap360(atan2(y, x) * 180 / .pi)
    }

    /// Bearing on arrival at `b`, degrees true.
    public static func finalBearing(from a: GeoCoordinate, to b: GeoCoordinate) -> Double {
        Navigation.wrap360(initialBearing(from: b, to: a) + 180)
    }

    /// Destination after `distance` metres on initial bearing `bearing`.
    public static func destination(from a: GeoCoordinate, bearing: Double, distance: Double,
                                   radius: Double = defaultRadius) -> GeoCoordinate {
        let d = distance / radius, t = bearing * .pi / 180
        let p1 = a.latitude * .pi / 180, l1 = a.longitude * .pi / 180
        let p2 = asin(sin(p1) * cos(d) + cos(p1) * sin(d) * cos(t))
        let l2 = l1 + atan2(sin(t) * sin(d) * cos(p1), cos(d) - sin(p1) * sin(p2))
        return GeoCoordinate(latitude: p2 * 180 / .pi, longitude: Navigation.wrap180(l2 * 180 / .pi))
    }

    /// The point a `fraction` (0…1) of the way along the great circle from `a` to `b`.
    public static func intermediate(from a: GeoCoordinate, to b: GeoCoordinate, fraction: Double) -> GeoCoordinate {
        let d = angularDistance(a, b)
        guard d > 0 else { return a }
        let p1 = a.latitude * .pi / 180, l1 = a.longitude * .pi / 180
        let p2 = b.latitude * .pi / 180, l2 = b.longitude * .pi / 180
        let ka = sin((1 - fraction) * d) / sin(d), kb = sin(fraction * d) / sin(d)
        let x = ka * cos(p1) * cos(l1) + kb * cos(p2) * cos(l2)
        let y = ka * cos(p1) * sin(l1) + kb * cos(p2) * sin(l2)
        let z = ka * sin(p1) + kb * sin(p2)
        return GeoCoordinate(latitude: atan2(z, (x * x + y * y).squareRoot()) * 180 / .pi,
                             longitude: atan2(y, x) * 180 / .pi)
    }

    /// Splits the great circle from `a` to `b` into points no more than `maxSegment` metres apart
    /// (including both ends). Useful for drawing a great-circle route as rhumb-line segments.
    public static func densify(from a: GeoCoordinate, to b: GeoCoordinate, maxSegment: Double) -> [GeoCoordinate] {
        let d = distance(from: a, to: b)
        let n = max(1, Int((d / max(maxSegment, 1)).rounded(.up)))
        return (0...n).map { intermediate(from: a, to: b, fraction: Double($0) / Double(n)) }
    }

    /// Signed cross-track distance (metres) of `p` from the great circle `start`→`end`.
    /// Positive means `p` is to starboard (right) of the track.
    public static func crossTrackDistance(of p: GeoCoordinate, from start: GeoCoordinate, to end: GeoCoordinate,
                                          radius: Double = defaultRadius) -> Double {
        let d13 = angularDistance(start, p)
        let t13 = initialBearing(from: start, to: p) * .pi / 180
        let t12 = initialBearing(from: start, to: end) * .pi / 180
        return asin(sin(d13) * sin(t13 - t12)) * radius
    }

    /// Distance (metres) from `start` to the point on the track abeam of `p`. Negative
    /// when `p` is abaft `start`.
    public static func alongTrackDistance(of p: GeoCoordinate, from start: GeoCoordinate, to end: GeoCoordinate,
                                          radius: Double = defaultRadius) -> Double {
        let d13 = angularDistance(start, p)
        let t13 = initialBearing(from: start, to: p) * .pi / 180
        let t12 = initialBearing(from: start, to: end) * .pi / 180
        let dxt = asin(sin(d13) * sin(t13 - t12))
        let c = cos(d13) / cos(dxt)
        let dat = acos(min(1, max(-1, c)))
        return (cos(t12 - t13) < 0 ? -dat : dat) * radius
    }
}

/// Rhumb lines (loxodromes: constant true bearing) on the WGS 84 ellipsoid, via the
/// isometric latitude and the meridian arc. A rhumb line is a straight line on a
/// Mercator chart.
public enum RhumbLine {
    /// Isometric latitude ψ (radians) for geodetic latitude φ (radians).
    static func isometricLatitude(_ phi: Double, _ e: Ellipsoid) -> Double {
        let ecc = e.eccentricitySquared.squareRoot()
        let s = ecc * sin(phi)
        return asinh(tan(phi)) - ecc * atanh(s)
    }

    /// Meridian arc length from the equator to latitude φ (radians), metres (Helmert's series).
    static func meridianArc(_ phi: Double, _ e: Ellipsoid) -> Double {
        let n = e.flattening / (2 - e.flattening)
        let n2 = n * n, n3 = n2 * n, n4 = n2 * n2
        let a0 = e.semiMajorAxis / (1 + n) * (1 + n2 / 4 + n4 / 64)
        let b2 = -3.0 / 2 * n + 9.0 / 16 * n3
        let b4 = 15.0 / 16 * n2 - 15.0 / 32 * n4
        let b6 = -35.0 / 48 * n3
        let b8 = 315.0 / 512 * n4
        return a0 * (phi + b2 * sin(2 * phi) + b4 * sin(4 * phi) + b6 * sin(6 * phi) + b8 * sin(8 * phi))
    }

    /// Inverse of `meridianArc` by Newton iteration.
    static func latitude(fromMeridianArc m: Double, _ e: Ellipsoid) -> Double {
        var phi = m / e.semiMajorAxis
        for _ in 0..<10 {
            let w2 = 1 - e.eccentricitySquared * sin(phi) * sin(phi)
            let rho = e.semiMajorAxis * (1 - e.eccentricitySquared) / (w2 * w2.squareRoot())
            let dphi = (m - meridianArc(phi, e)) / rho
            phi += dphi
            if abs(dphi) < 1e-14 { break }
        }
        return phi
    }

    /// Constant bearing (degrees true) and distance (metres) from `a` to `b`.
    public static func inverse(from a: GeoCoordinate, to b: GeoCoordinate,
                               ellipsoid e: Ellipsoid = .wgs84) -> (distance: Double, bearing: Double) {
        let p1 = a.latitude * .pi / 180, p2 = b.latitude * .pi / 180
        let dl = Navigation.wrap180(b.longitude - a.longitude) * .pi / 180
        let dpsi = isometricLatitude(p2, e) - isometricLatitude(p1, e)
        let bearing = atan2(dl, dpsi)
        let dm = meridianArc(p2, e) - meridianArc(p1, e)
        let distance: Double
        if abs(p2 - p1) < 1e-12 {
            // Along a parallel: arc of the parallel's circle, radius N cos φ.
            let n = e.semiMajorAxis / (1 - e.eccentricitySquared * sin(p1) * sin(p1)).squareRoot()
            distance = abs(dl) * n * cos(p1)
        } else {
            distance = abs(dm / cos(bearing))
        }
        return (distance, Navigation.wrap360(bearing * 180 / .pi))
    }

    /// Destination after `distance` metres on constant bearing `bearing`.
    public static func destination(from a: GeoCoordinate, bearing: Double, distance: Double,
                                   ellipsoid e: Ellipsoid = .wgs84) -> GeoCoordinate {
        let t = bearing * .pi / 180
        let p1 = a.latitude * .pi / 180
        let dm = distance * cos(t)
        let p2 = latitude(fromMeridianArc: meridianArc(p1, e) + dm, e)
        let dl: Double
        if abs(dm) < 1e-9 {
            let n = e.semiMajorAxis / (1 - e.eccentricitySquared * sin(p1) * sin(p1)).squareRoot()
            dl = distance * sin(t) / (n * cos(p1))
        } else {
            dl = tan(t) * (isometricLatitude(p2, e) - isometricLatitude(p1, e))
        }
        return GeoCoordinate(latitude: p2 * 180 / .pi, longitude: Navigation.wrap180(a.longitude + dl * 180 / .pi))
    }
}
