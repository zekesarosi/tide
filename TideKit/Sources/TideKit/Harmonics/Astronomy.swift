import Foundation

/// Astronomical arguments used by the harmonic method of tide prediction.
///
/// Angles follow Schureman (1958), *Manual of Harmonic Analysis and Prediction
/// of Tides* (USC&GS Special Publication 98), which is the basis of NOAA's own
/// prediction system. Mean longitudes use the Meeus (1998) polynomials.
///
/// All angles are in degrees.
public struct AstronomicalArguments: Sendable, Equatable {
    /// Hour angle of the mean sun at Greenwich (Schureman's T).
    public let T: Double
    /// Mean longitude of the moon.
    public let s: Double
    /// Mean longitude of the sun.
    public let h: Double
    /// Longitude of the lunar perigee.
    public let p: Double
    /// Longitude of the moon's ascending node.
    public let N: Double
    /// Longitude of the solar perigee.
    public let p1: Double

    // Derived quantities (Schureman §§ 40-50, 196-235)
    /// Obliquity of the moon's orbit to the celestial equator.
    public let I: Double
    /// Right ascension of the lunar intersection.
    public let nu: Double
    /// Longitude in the moon's orbit of the lunar intersection.
    public let xi: Double
    /// ν′ term used by K1.
    public let nuPrime: Double
    /// ν″ term used by K2 (this is ν″, i.e. half of 2ν″).
    public let nuDoublePrime: Double

    /// Mean angular speeds in degrees per mean solar hour.
    public enum Speed {
        public static let T = 15.0
        public static let s = 0.549_016_53
        public static let h = 0.041_068_64
        public static let p = 0.004_641_83
        public static let N = -0.002_206_41
        public static let p1 = 0.000_001_96
    }

    /// Inclination of the moon's orbit to the ecliptic (degrees).
    static let lunarInclination = 5.145

    public init(date: Date) {
        let jd = date.timeIntervalSince1970 / 86_400.0 + 2_440_587.5
        let c = (jd - 2_451_545.0) / 36_525.0 // Julian centuries from J2000.0

        // Hour angle of mean sun: 180° at 00:00 UT.
        let secondsOfDay = date.timeIntervalSince1970.truncatingRemainder(dividingBy: 86_400)
        let utHours = (secondsOfDay < 0 ? secondsOfDay + 86_400 : secondsOfDay) / 3_600
        T = Angle.normalize(180.0 + 15.0 * utHours)

        s = Angle.normalize(Self.poly(c, [218.316_459_1, 481_267.881_342_36, -0.001_326_8, 1.0 / 538_841.0, -1.0 / 65_194_000.0]))
        h = Angle.normalize(Self.poly(c, [280.466_45, 36_000.769_748_9, 0.000_303_2]))
        p = Angle.normalize(Self.poly(c, [83.353_243_0, 4_069.013_711_1, -0.010_323_8, -1.0 / 80_053.0, 1.0 / 18_999_000.0]))
        N = Angle.normalize(Self.poly(c, [125.044_555_0, -1_934.136_184_9, 0.002_076_2, 1.0 / 467_410.0, -1.0 / 60_616_000.0]))
        p1 = Angle.normalize(Self.poly(c, [282.937_348, 1.719_532_9, 0.000_459_7]))

        // Obliquity of the ecliptic (Meeus 22.2), degrees.
        let omega = 23.439_291_1 - 0.013_004_2 * c
        let i = Self.lunarInclination

        let Nr = N.radians, wr = omega.radians, ir = i.radians

        // Schureman eq. 191 (I), and the ν / ξ pair from eqs. 192-193 via
        // Napier's analogies (the numerically robust form used by pytides).
        let cosI = cos(wr) * cos(ir) - sin(wr) * sin(ir) * cos(Nr)
        let Ir = acos(cosI)
        I = Ir.degrees

        let e1 = atan(cos(0.5 * (wr - ir)) / cos(0.5 * (wr + ir)) * tan(0.5 * Nr)) - 0.5 * Nr
        let e2 = atan(sin(0.5 * (wr - ir)) / sin(0.5 * (wr + ir)) * tan(0.5 * Nr)) - 0.5 * Nr
        let nuR = e1 - e2
        let xiR = -(e1 + e2)
        nu = nuR.degrees
        xi = xiR.degrees

        // Schureman eq. 224: tan ν′ = sin 2I sin ν / (sin 2I cos ν + 0.3347)
        nuPrime = atan2(sin(2 * Ir) * sin(nuR), sin(2 * Ir) * cos(nuR) + 0.3347).degrees
        // Schureman eq. 232: tan 2ν″ = sin²I sin 2ν / (sin²I cos 2ν + 0.0727)
        let sin2I = sin(Ir) * sin(Ir)
        nuDoublePrime = 0.5 * atan2(sin2I * sin(2 * nuR), sin2I * cos(2 * nuR) + 0.0727).degrees
    }

    private static func poly(_ x: Double, _ coefficients: [Double]) -> Double {
        coefficients.reversed().reduce(0.0) { $0 * x + $1 }
    }
}

enum Angle {
    static func normalize(_ degrees: Double) -> Double {
        let r = degrees.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }
}

extension Double {
    var radians: Double { self * .pi / 180 }
    var degrees: Double { self * 180 / .pi }
}
