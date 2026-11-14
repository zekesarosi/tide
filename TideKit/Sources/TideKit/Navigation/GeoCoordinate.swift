import Foundation

/// A position on the WGS 84 ellipsoid, in decimal degrees (north and east positive).
public struct GeoCoordinate: Sendable, Hashable, Codable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Longitude wrapped to [−180, 180).
    public var normalized: GeoCoordinate {
        GeoCoordinate(latitude: latitude, longitude: Navigation.wrap180(longitude))
    }

    public var isValid: Bool {
        latitude.isFinite && longitude.isFinite && abs(latitude) <= 90 && abs(longitude) <= 540
    }
}

/// Units and angle helpers shared by the navigation modules.
public enum Navigation {
    /// The international nautical mile, metres.
    public static let metersPerNauticalMile = 1_852.0
    /// One knot, metres per second.
    public static let metersPerSecondPerKnot = 1_852.0 / 3_600

    public static func knots(fromMetersPerSecond v: Double) -> Double { v / metersPerSecondPerKnot }
    public static func metersPerSecond(fromKnots v: Double) -> Double { v * metersPerSecondPerKnot }
    public static func nauticalMiles(fromMeters m: Double) -> Double { m / metersPerNauticalMile }
    public static func meters(fromNauticalMiles nm: Double) -> Double { nm * metersPerNauticalMile }

    /// Degrees wrapped to [0, 360).
    public static func wrap360(_ degrees: Double) -> Double {
        let r = degrees.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }

    /// Degrees wrapped to [−180, 180).
    public static func wrap180(_ degrees: Double) -> Double {
        let r = wrap360(degrees + 180) - 180
        return r
    }

    /// Signed smallest rotation from `a` to `b`, degrees in [−180, 180). Positive is clockwise.
    public static func angleDifference(from a: Double, to b: Double) -> Double {
        wrap180(b - a)
    }
}

/// A 2-D vector in a local east/north frame (metres, or metres per second).
public struct ENUVector: Sendable, Hashable, Codable {
    public var east: Double
    public var north: Double

    public init(east: Double, north: Double) {
        self.east = east
        self.north = north
    }

    /// From a direction (degrees true, the way the vector points) and a magnitude.
    public init(direction: Double, magnitude: Double) {
        let r = direction * .pi / 180
        self.init(east: magnitude * sin(r), north: magnitude * cos(r))
    }

    public static let zero = ENUVector(east: 0, north: 0)

    public var magnitude: Double { hypot(east, north) }
    /// Direction the vector points, degrees true in [0, 360). Zero for the zero vector.
    public var direction: Double { magnitude == 0 ? 0 : Navigation.wrap360(atan2(east, north) * 180 / .pi) }

    public static func + (a: ENUVector, b: ENUVector) -> ENUVector { .init(east: a.east + b.east, north: a.north + b.north) }
    public static func - (a: ENUVector, b: ENUVector) -> ENUVector { .init(east: a.east - b.east, north: a.north - b.north) }
    public static func * (a: ENUVector, k: Double) -> ENUVector { .init(east: a.east * k, north: a.north * k) }
    public func dot(_ b: ENUVector) -> Double { east * b.east + north * b.north }
}

/// A local tangent plane (equirectangular on the ellipsoid's local radii) centred on
/// `origin`. Accurate to centimetres within a few kilometres; used for anchoring and
/// collision geometry where distances are short and speed matters.
public struct LocalTangentPlane: Sendable, Hashable {
    public let origin: GeoCoordinate
    let metersPerDegreeLatitude: Double
    let metersPerDegreeLongitude: Double

    public init(origin: GeoCoordinate) {
        self.origin = origin
        let e2 = Ellipsoid.wgs84.eccentricitySquared, a = Ellipsoid.wgs84.semiMajorAxis
        let phi = origin.latitude * .pi / 180
        let w = (1 - e2 * sin(phi) * sin(phi)).squareRoot()
        let m = a * (1 - e2) / (w * w * w) // meridional radius of curvature
        let n = a / w                       // prime vertical radius of curvature
        metersPerDegreeLatitude = m * .pi / 180
        metersPerDegreeLongitude = n * cos(phi) * .pi / 180
    }

    public func project(_ p: GeoCoordinate) -> ENUVector {
        ENUVector(east: Navigation.wrap180(p.longitude - origin.longitude) * metersPerDegreeLongitude,
                  north: (p.latitude - origin.latitude) * metersPerDegreeLatitude)
    }

    public func unproject(_ v: ENUVector) -> GeoCoordinate {
        GeoCoordinate(latitude: origin.latitude + v.north / metersPerDegreeLatitude,
                      longitude: Navigation.wrap180(origin.longitude + v.east / metersPerDegreeLongitude))
    }
}
