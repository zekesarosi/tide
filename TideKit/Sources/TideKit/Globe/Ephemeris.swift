import Foundation

/// Geocentric positions of the Sun and Moon, good to about 0.1° (Moon) and
/// 0.01° (Sun) over 1950–2050, plus Greenwich sidereal time.
///
/// Truncated series from Meeus, *Astronomical Algorithms* (1998), ch. 25 and 47.
/// Checked against JPL Horizons in `EphemerisTests`.
public enum Ephemeris {
    /// Equatorial coordinates of date, in degrees, with distance.
    public struct Position: Sendable, Equatable {
        /// Right ascension, 0..<360°.
        public var rightAscension: Double
        /// Declination, −90...90°.
        public var declination: Double
        /// Geocentric distance in kilometres.
        public var distance: Double
        /// Apparent ecliptic longitude, 0..<360°.
        public var eclipticLongitude: Double

        /// Latitude and longitude of the point on Earth directly beneath the body.
        public func subpoint(at date: Date) -> (latitude: Double, longitude: Double) {
            var lon = Angle.normalize(rightAscension - Ephemeris.greenwichSiderealTime(date))
            if lon > 180 { lon -= 360 }
            return (declination, lon)
        }
    }

    public static let astronomicalUnit = 149_597_870.7
    /// Mean Earth–Moon distance used by the tide-generating constants (km).
    public static let meanLunarDistance = 385_001.0

    static func daysSinceJ2000(_ date: Date) -> Double {
        date.timeIntervalSince1970 / 86_400 + 2_440_587.5 - 2_451_545.0
    }

    static func obliquity(_ d: Double) -> Double { 23.439_291_1 - 0.013_004_2 * d / 36_525 }

    static func equatorial(longitude lam: Double, latitude beta: Double, obliquity eps: Double) -> (ra: Double, dec: Double) {
        let l = lam.radians, b = beta.radians, e = eps.radians
        let ra = atan2(sin(l) * cos(e) - tan(b) * sin(e), cos(l))
        let dec = asin(sin(b) * cos(e) + cos(b) * sin(e) * sin(l))
        return (Angle.normalize(ra.degrees), dec.degrees)
    }

    /// Greenwich mean sidereal time in degrees.
    public static func greenwichSiderealTime(_ date: Date) -> Double {
        Angle.normalize(280.460_618_37 + 360.985_647_366_29 * daysSinceJ2000(date))
    }

    public static func sun(_ date: Date) -> Position {
        let d = daysSinceJ2000(date)
        let g = Angle.normalize(357.528 + 0.985_600_3 * d).radians
        let L = 280.460 + 0.985_647_4 * d
        let lam = Angle.normalize(L + 1.915 * sin(g) + 0.020 * sin(2 * g))
        let au = 1.000_14 - 0.016_71 * cos(g) - 0.000_14 * cos(2 * g)
        let (ra, dec) = equatorial(longitude: lam, latitude: 0, obliquity: obliquity(d))
        return Position(rightAscension: ra, declination: dec, distance: au * astronomicalUnit, eclipticLongitude: lam)
    }

    public static func moon(_ date: Date) -> Position {
        let d = daysSinceJ2000(date)
        let L = 218.316 + 13.176_396 * d
        let M = (134.963 + 13.064_993 * d).radians
        let F = (93.272 + 13.229_350 * d).radians
        let D = (297.850 + 12.190_749 * d).radians
        let Ms = (357.529 + 0.985_600_28 * d).radians
        var lam = L + 6.289 * sin(M)
        lam += 1.274 * sin(2 * D - M) + 0.658 * sin(2 * D) + 0.214 * sin(2 * M)
        lam += -0.186 * sin(Ms) - 0.114 * sin(2 * F) + 0.059 * sin(2 * D - 2 * M)
        lam += 0.057 * sin(2 * D - Ms - M) + 0.053 * sin(2 * D + M) + 0.046 * sin(2 * D - Ms)
        lam += -0.041 * sin(M - Ms) - 0.035 * sin(D) - 0.031 * sin(M + Ms)
        let beta = 5.128 * sin(F) + 0.281 * sin(M + F) + 0.278 * sin(M - F) + 0.173 * sin(2 * D - F)
        let km = 385_001 - 20_905 * cos(M) - 3_699 * cos(2 * D - M) - 2_956 * cos(2 * D) - 570 * cos(2 * M)
        let lamN = Angle.normalize(lam)
        let (ra, dec) = equatorial(longitude: lamN, latitude: beta, obliquity: obliquity(d))
        return Position(rightAscension: ra, declination: dec, distance: km, eclipticLongitude: lamN)
    }

    /// Moon's elongation from the Sun, 0..<360° (0 new, 180 full).
    public static func lunarElongation(_ date: Date) -> Double {
        Angle.normalize(moon(date).eclipticLongitude - sun(date).eclipticLongitude)
    }

    /// Fraction of the Moon's disc that is lit, 0...1.
    public static func lunarIllumination(_ date: Date) -> Double {
        (1 - cos(lunarElongation(date).radians)) / 2
    }
}
