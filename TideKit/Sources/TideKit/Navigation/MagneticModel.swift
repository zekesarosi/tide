import Foundation

/// The World Magnetic Model (NOAA NCEI / BGS), for magnetic variation (declination).
///
/// Evaluates the degree-12 spherical-harmonic main field with linear secular
/// variation, following "The US/UK World Magnetic Model for 2025–2030: Technical
/// Report" (Chulliat et al.). Coefficients are WMM2025 (epoch 2025.0, valid
/// 2025.0–2030.0), which are in the public domain. Results match NCEI's published
/// test values to 0.1 nT and 0.01°.
public struct MagneticModel: Sendable {
    public struct Field: Sendable, Hashable {
        /// North, east and down components, nT (geodetic frame).
        public var north: Double, east: Double, down: Double
        /// Horizontal intensity H and total intensity F, nT.
        public var horizontal: Double { hypot(north, east) }
        public var total: Double { (north * north + east * east + down * down).squareRoot() }
        /// Inclination (dip), degrees, positive down.
        public var inclination: Double { atan2(down, horizontal) * 180 / .pi }
        /// Declination (magnetic variation), degrees, positive east of true north.
        public var declination: Double { atan2(east, north) * 180 / .pi }
    }

    public let name: String
    /// Epoch, decimal year.
    public let epoch: Double
    /// Decimal years the model is valid for.
    public let validity: ClosedRange<Double>
    let maxDegree: Int
    /// g, h, ġ, ḣ indexed by n*(n+1)/2 + m.
    let g: [Double], h: [Double], gDot: [Double], hDot: [Double]

    /// Reference radius of the geomagnetic expansion, metres.
    static let referenceRadius = 6_371_200.0

    public static let wmm2025: MagneticModel = MagneticModel(name: "WMM2025", epoch: 2025.0, validity: 2025.0...2030.0,
                                                             table: wmm2025Coefficients)

    init(name: String, epoch: Double, validity: ClosedRange<Double>, table: String) {
        var rows: [(Int, Int, Double, Double, Double, Double)] = []
        for line in table.split(separator: "\n") {
            let f = line.split(separator: " ")
            guard f.count == 6, let n = Int(f[0]), let m = Int(f[1]),
                  let a = Double(f[2]), let b = Double(f[3]), let c = Double(f[4]), let d = Double(f[5]) else { continue }
            rows.append((n, m, a, b, c, d))
        }
        let nMax = rows.map(\.0).max() ?? 0
        let size = (nMax + 1) * (nMax + 2) / 2
        var g = [Double](repeating: 0, count: size), h = g, gd = g, hd = g
        for (n, m, a, b, c, d) in rows {
            let k = n * (n + 1) / 2 + m
            g[k] = a; h[k] = b; gd[k] = c; hd[k] = d
        }
        self.name = name
        self.epoch = epoch
        self.validity = validity
        self.maxDegree = nMax
        self.g = g; self.h = h; self.gDot = gd; self.hDot = hd
    }

    /// Decimal year of a date (UTC), e.g. 1 July 2026 ≈ 2026.497.
    public static func decimalYear(_ date: Date) -> Double {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let year = cal.component(.year, from: date)
        let start = cal.date(from: DateComponents(year: year, month: 1, day: 1))!
        let end = cal.date(from: DateComponents(year: year + 1, month: 1, day: 1))!
        return Double(year) + date.timeIntervalSince(start) / end.timeIntervalSince(start)
    }

    /// Whether `date` is inside the model's validity window (results outside it degrade).
    public func isValid(at date: Date) -> Bool { validity.contains(Self.decimalYear(date)) }

    /// Field at a geodetic position. `height` is metres above the WGS 84 ellipsoid.
    public func field(latitude: Double, longitude: Double, height: Double = 0, decimalYear t: Double) -> Field {
        let e = Ellipsoid.wgs84
        let phi = latitude * .pi / 180, lambda = longitude * .pi / 180
        // Geodetic → geocentric spherical.
        let e2 = e.eccentricitySquared
        let rc = e.semiMajorAxis / (1 - e2 * sin(phi) * sin(phi)).squareRoot()
        let p = (rc + height) * cos(phi)
        let z = (rc * (1 - e2) + height) * sin(phi)
        let r = hypot(p, z)
        let phiC = asin(z / r)

        let x = sin(phiC), y = cos(phiC) // cos θ, sin θ of the colatitude θ
        let nMax = maxDegree
        let size = (nMax + 1) * (nMax + 2) / 2
        // Schmidt semi-normalised associated Legendre functions and dP/dθ.
        var pnm = [Double](repeating: 0, count: size), dpnm = pnm
        pnm[0] = 1
        func idx(_ n: Int, _ m: Int) -> Int { n * (n + 1) / 2 + m }
        for n in 1...nMax {
            for m in 0...n {
                let k = idx(n, m)
                if n == m {
                    let s = n == 1 ? 1.0 : (Double(2 * n - 1) / Double(2 * n)).squareRoot()
                    let prev = idx(n - 1, n - 1)
                    pnm[k] = s * y * pnm[prev]
                    dpnm[k] = s * (y * dpnm[prev] + x * pnm[prev])
                } else {
                    let a = Double(2 * n - 1)
                    let b = n >= 2 && m <= n - 2 ? (Double((n - 1 + m) * (n - 1 - m))).squareRoot() : 0
                    let c = (Double(n * n - m * m)).squareRoot()
                    let p1 = pnm[idx(n - 1, m)], d1 = dpnm[idx(n - 1, m)]
                    let p2 = b != 0 ? pnm[idx(n - 2, m)] : 0, d2 = b != 0 ? dpnm[idx(n - 2, m)] : 0
                    pnm[k] = (a * x * p1 - b * p2) / c
                    dpnm[k] = (a * (x * d1 - y * p1) - b * d2) / c
                }
            }
        }

        let dt = t - epoch
        var bx = 0.0, by = 0.0, bz = 0.0
        let ratio = Self.referenceRadius / r
        var rn = ratio * ratio // (a/r)^(n+2) starts at n = 0
        for n in 1...nMax {
            rn *= ratio
            for m in 0...n {
                let k = idx(n, m)
                let gt = g[k] + dt * gDot[k], ht = h[k] + dt * hDot[k]
                let cm = cos(Double(m) * lambda), sm = sin(Double(m) * lambda)
                let gh = gt * cm + ht * sm
                bx += rn * gh * dpnm[k]
                by += rn * Double(m) * (gt * sm - ht * cm) * pnm[k]
                bz -= rn * Double(n + 1) * gh * pnm[k]
            }
        }
        // dP/dθ = −dP/dφ′, so X′ = Σ (g cos + h sin) dP/dθ already carries the sign.
        let yC = y > 1e-12 ? by / y : by // at the poles the (zero) m-terms vanish
        let psi = phiC - phi
        return Field(north: bx * cos(psi) - bz * sin(psi), east: yC, down: bx * sin(psi) + bz * cos(psi))
    }

    /// Magnetic variation (declination), degrees east positive, at a position and date.
    public func declination(at p: GeoCoordinate, height: Double = 0, date: Date) -> Double {
        field(latitude: p.latitude, longitude: p.longitude, height: height, decimalYear: Self.decimalYear(date)).declination
    }

    /// Grid variation for polar navigation (|latitude| ≥ 55°): declination relative to
    /// grid north of the Universal Polar Stereographic projection. Nil elsewhere.
    public func gridVariation(latitude: Double, longitude: Double, declination: Double) -> Double? {
        if latitude >= 55 { return Navigation.wrap180(declination - longitude) }
        if latitude <= -55 { return Navigation.wrap180(declination + longitude) }
        return nil
    }

    /// Converts a true bearing to magnetic (subtract easterly variation).
    public static func magnetic(fromTrue bearing: Double, variation: Double) -> Double {
        Navigation.wrap360(bearing - variation)
    }

    /// Converts a magnetic bearing to true (add easterly variation).
    public static func trueBearing(fromMagnetic bearing: Double, variation: Double) -> Double {
        Navigation.wrap360(bearing + variation)
    }
}

/// WMM2025 Gauss coefficients: n m g h ġ ḣ (nT, nT/yr). From NCEI's WMM.COF, 11/13/2024.
let wmm2025Coefficients = """
1 0 -29351.8 0.0 12.0 0.0
1 1 -1410.8 4545.4 9.7 -21.5
2 0 -2556.6 0.0 -11.6 0.0
2 1 2951.1 -3133.6 -5.2 -27.7
2 2 1649.3 -815.1 -8.0 -12.1
3 0 1361.0 0.0 -1.3 0.0
3 1 -2404.1 -56.6 -4.2 4.0
3 2 1243.8 237.5 0.4 -0.3
3 3 453.6 -549.5 -15.6 -4.1
4 0 895.0 0.0 -1.6 0.0
4 1 799.5 278.6 -2.4 -1.1
4 2 55.7 -133.9 -6.0 4.1
4 3 -281.1 212.0 5.6 1.6
4 4 12.1 -375.6 -7.0 -4.4
5 0 -233.2 0.0 0.6 0.0
5 1 368.9 45.4 1.4 -0.5
5 2 187.2 220.2 0.0 2.2
5 3 -138.7 -122.9 0.6 0.4
5 4 -142.0 43.0 2.2 1.7
5 5 20.9 106.1 0.9 1.9
6 0 64.4 0.0 -0.2 0.0
6 1 63.8 -18.4 -0.4 0.3
6 2 76.9 16.8 0.9 -1.6
6 3 -115.7 48.8 1.2 -0.4
6 4 -40.9 -59.8 -0.9 0.9
6 5 14.9 10.9 0.3 0.7
6 6 -60.7 72.7 0.9 0.9
7 0 79.5 0.0 -0.0 0.0
7 1 -77.0 -48.9 -0.1 0.6
7 2 -8.8 -14.4 -0.1 0.5
7 3 59.3 -1.0 0.5 -0.8
7 4 15.8 23.4 -0.1 0.0
7 5 2.5 -7.4 -0.8 -1.0
7 6 -11.1 -25.1 -0.8 0.6
7 7 14.2 -2.3 0.8 -0.2
8 0 23.2 0.0 -0.1 0.0
8 1 10.8 7.1 0.2 -0.2
8 2 -17.5 -12.6 0.0 0.5
8 3 2.0 11.4 0.5 -0.4
8 4 -21.7 -9.7 -0.1 0.4
8 5 16.9 12.7 0.3 -0.5
8 6 15.0 0.7 0.2 -0.6
8 7 -16.8 -5.2 -0.0 0.3
8 8 0.9 3.9 0.2 0.2
9 0 4.6 0.0 -0.0 0.0
9 1 7.8 -24.8 -0.1 -0.3
9 2 3.0 12.2 0.1 0.3
9 3 -0.2 8.3 0.3 -0.3
9 4 -2.5 -3.3 -0.3 0.3
9 5 -13.1 -5.2 0.0 0.2
9 6 2.4 7.2 0.3 -0.1
9 7 8.6 -0.6 -0.1 -0.2
9 8 -8.7 0.8 0.1 0.4
9 9 -12.9 10.0 -0.1 0.1
10 0 -1.3 0.0 0.1 0.0
10 1 -6.4 3.3 0.0 0.0
10 2 0.2 0.0 0.1 -0.0
10 3 2.0 2.4 0.1 -0.2
10 4 -1.0 5.3 -0.0 0.1
10 5 -0.6 -9.1 -0.3 -0.1
10 6 -0.9 0.4 0.0 0.1
10 7 1.5 -4.2 -0.1 0.0
10 8 0.9 -3.8 -0.1 -0.1
10 9 -2.7 0.9 -0.0 0.2
10 10 -3.9 -9.1 -0.0 -0.0
11 0 2.9 0.0 0.0 0.0
11 1 -1.5 0.0 -0.0 -0.0
11 2 -2.5 2.9 0.0 0.1
11 3 2.4 -0.6 0.0 -0.0
11 4 -0.6 0.2 0.0 0.1
11 5 -0.1 0.5 -0.1 -0.0
11 6 -0.6 -0.3 0.0 -0.0
11 7 -0.1 -1.2 -0.0 0.1
11 8 1.1 -1.7 -0.1 -0.0
11 9 -1.0 -2.9 -0.1 0.0
11 10 -0.2 -1.8 -0.1 0.0
11 11 2.6 -2.3 -0.1 0.0
12 0 -2.0 0.0 0.0 0.0
12 1 -0.2 -1.3 0.0 -0.0
12 2 0.3 0.7 -0.0 0.0
12 3 1.2 1.0 -0.0 -0.1
12 4 -1.3 -1.4 -0.0 0.1
12 5 0.6 -0.0 -0.0 -0.0
12 6 0.6 0.6 0.1 -0.0
12 7 0.5 -0.1 -0.0 -0.0
12 8 -0.1 0.8 0.0 0.0
12 9 -0.4 0.1 0.0 -0.0
12 10 -0.2 -1.0 -0.1 -0.0
12 11 -1.3 0.1 -0.0 0.0
12 12 -0.7 0.2 -0.1 -0.1
"""
