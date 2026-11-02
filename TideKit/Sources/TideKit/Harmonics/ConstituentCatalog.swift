import Foundation

/// How a constituent's node factor `f` and nodal angle `u` are computed
/// (Schureman 1958, Table 2 and eqs. 73-235).
public enum NodalModulation: Sendable, Hashable {
    case unity
    case mm, mf, o1, j1, oo1, m2, k1, k2, l2, m1
    /// `f = f(M2)^power`, `u = power * u(M2)` (used for M3 and similar).
    case m2Power(Double)

    func factors(_ a: AstronomicalArguments) -> (f: Double, u: Double) {
        let I = a.I.radians
        let nu = a.nu.radians
        let xi = a.xi.radians
        let sinI = sin(I), cosI = cos(I)
        let halfI = 0.5 * I

        func fM2() -> Double { pow(cos(halfI), 4) / 0.9154 }
        func uM2() -> Double { 2 * xi - 2 * nu }
        func fO1() -> Double { sinI * pow(cos(halfI), 2) / 0.3800 }

        switch self {
        case .unity:
            return (1, 0)
        case .mm:
            return ((2.0 / 3.0 - sinI * sinI) / 0.5021, 0)
        case .mf:
            return (sinI * sinI / 0.1578, (-2 * xi).degrees)
        case .o1:
            return (fO1(), (2 * xi - nu).degrees)
        case .j1:
            return (sin(2 * I) / 0.7214, (-nu).degrees)
        case .oo1:
            return (sinI * pow(sin(halfI), 2) / 0.016_40, (-2 * xi - nu).degrees)
        case .m2:
            return (fM2(), uM2().degrees)
        case .k1:
            let s2I = sin(2 * I)
            let f = sqrt(0.8965 * s2I * s2I + 0.6001 * s2I * cos(nu) + 0.1006)
            return (f, -a.nuPrime)
        case .k2:
            let f = sqrt(19.0444 * pow(sinI, 4) + 2.7702 * sinI * sinI * cos(2 * nu) + 0.0981)
            return (f, -2 * a.nuDoublePrime)
        case .l2:
            // Schureman eqs. 213-215.
            let P = (a.p - a.xi).radians
            let t2 = pow(tan(halfI), 2)
            let invRa = sqrt(1 - 12 * t2 * cos(2 * P) + 36 * t2 * t2)
            let R = atan2(sin(2 * P), (1.0 / 6.0) / t2 - cos(2 * P))
            return (fM2() * invRa, (uM2() - R).degrees)
        case .m1:
            // Schureman eqs. 203-207.
            let P = (a.p - a.xi).radians
            let sec2 = 1 / pow(cos(halfI), 2)
            let invQa = sqrt(0.25 + 1.5 * cosI * sec2 * cos(2 * P) + 2.25 * cosI * cosI * sec2 * sec2)
            let Q = atan2((5 * cosI - 1) * sin(P), (7 * cosI + 1) * cos(P))
            // NOAA's equilibrium argument for M1 omits the perigee term at the
            // start of the prediction year (V₀ is computed on 1 January and
            // advanced at 14.4966939°/h). Expressed against our V, which
            // carries +p, that is a −p(1 Jan) correction. `a` is evaluated at
            // mid-year, so step p back half a year. Verified against NOAA
            // predictions for Seattle 2026-2043 (fitted u within ~0.5°).
            let pYearStart = a.p - AstronomicalArguments.Speed.p * 4_383
            return (fO1() * invQa, (xi - nu + Q).degrees - pYearStart)
        case .m2Power(let k):
            return (pow(fM2(), k), k * uM2().degrees)
        }
    }
}

/// An elementary constituent described by its extended Doodson numbers.
public struct BaseConstituent: Sendable, Hashable {
    public let name: String
    /// Coefficients of (T, s, h, p, N, p1).
    public let doodson: [Int]
    /// Constant phase offset in degrees (multiples of 90°).
    public let offset: Double
    public let nodal: NodalModulation

    public var species: Int { doodson[0] }

    public var speed: Double {
        typealias S = AstronomicalArguments.Speed
        let rates = [S.T, S.s, S.h, S.p, S.N, S.p1]
        return zip(doodson, rates).reduce(0) { $0 + Double($1.0) * $1.1 }
    }

    func equilibriumArgument(_ a: AstronomicalArguments) -> Double {
        let args = [a.T, a.s, a.h, a.p, a.N, a.p1]
        return zip(doodson, args).reduce(offset) { $0 + Double($1.0) * $1.1 }
    }
}

/// A constituent expressed as an integer linear combination of base
/// constituents. Elementary constituents are a single term with coefficient 1.
public struct ConstituentDefinition: Sendable, Hashable {
    public struct Term: Sendable, Hashable {
        public let base: BaseConstituent
        public let coefficient: Int
    }

    public let name: String
    public let terms: [Term]

    public var speed: Double {
        terms.reduce(0) { $0 + Double($1.coefficient) * $1.base.speed }
    }

    /// Equilibrium argument V (degrees) at the instant `a` describes.
    public func equilibriumArgument(_ a: AstronomicalArguments) -> Double {
        Angle.normalize(terms.reduce(0) { $0 + Double($1.coefficient) * $1.base.equilibriumArgument(a) })
    }

    /// Node factor f and nodal angle u (degrees).
    public func nodalFactors(_ a: AstronomicalArguments) -> (f: Double, u: Double) {
        var f = 1.0, u = 0.0
        for term in terms {
            let (tf, tu) = term.base.nodal.factors(a)
            f *= pow(tf, Double(abs(term.coefficient)))
            u += Double(term.coefficient) * tu
        }
        return (f, u)
    }
}

/// Catalog of constituents used by NOAA CO-OPS, including resolution of the
/// compound shallow-water constituents published for stations such as
/// Anchorage (which list 120+ constituents).
public enum ConstituentCatalog {
    private static func b(_ name: String, _ d: [Int], _ offset: Double, _ nodal: NodalModulation) -> BaseConstituent {
        BaseConstituent(name: name, doodson: d, offset: offset, nodal: nodal)
    }

    //                    T   s   h   p  N  p1
    static let SA     = b("SA",     [0, 0, 1, 0, 0, 0], 0, .unity)
    static let SSA    = b("SSA",    [0, 0, 2, 0, 0, 0], 0, .unity)
    static let MM     = b("MM",     [0, 1, 0, -1, 0, 0], 0, .mm)
    static let MF     = b("MF",     [0, 2, 0, 0, 0, 0], 0, .mf)

    static let Q2_1   = b("2Q1",    [1, -4, 1, 2, 0, 0], 90, .o1)
    static let SIGMA1 = b("SIGMA1", [1, -4, 3, 0, 0, 0], 90, .o1)
    static let Q1     = b("Q1",     [1, -3, 1, 1, 0, 0], 90, .o1)
    static let RHO1   = b("RHO",    [1, -3, 3, -1, 0, 0], 90, .o1)
    static let O1     = b("O1",     [1, -2, 1, 0, 0, 0], 90, .o1)
    static let M1     = b("M1",     [1, -1, 1, 1, 0, 0], -90, .m1)
    static let CHI1   = b("CHI1",   [1, -1, 3, -1, 0, 0], -90, .j1)
    static let PI1    = b("PI1",    [1, 0, -2, 0, 0, 1], 90, .unity)
    static let P1     = b("P1",     [1, 0, -1, 0, 0, 0], 90, .unity)
    static let S1     = b("S1",     [1, 0, 0, 0, 0, 0], 0, .unity)
    static let K1     = b("K1",     [1, 0, 1, 0, 0, 0], -90, .k1)
    static let PSI1   = b("PSI1",   [1, 0, 2, 0, 0, -1], -90, .unity)
    static let PHI1   = b("PHI1",   [1, 0, 3, 0, 0, 0], -90, .unity)
    static let THETA1 = b("THETA1", [1, 1, -1, 1, 0, 0], -90, .j1)
    static let J1     = b("J1",     [1, 1, 1, -1, 0, 0], -90, .j1)
    static let OO1    = b("OO1",    [1, 2, 1, 0, 0, 0], -90, .oo1)

    static let N2_2   = b("2N2",    [2, -4, 2, 2, 0, 0], 0, .m2)
    static let MU2    = b("MU2",    [2, -4, 4, 0, 0, 0], 0, .m2)
    static let N2     = b("N2",     [2, -3, 2, 1, 0, 0], 0, .m2)
    static let NU2    = b("NU2",    [2, -3, 4, -1, 0, 0], 0, .m2)
    static let M2     = b("M2",     [2, -2, 2, 0, 0, 0], 0, .m2)
    static let LAM2   = b("LAM2",   [2, -1, 0, 1, 0, 0], 180, .m2)
    static let L2     = b("L2",     [2, -1, 2, -1, 0, 0], 180, .l2)
    static let T2     = b("T2",     [2, 0, -1, 0, 0, 1], 0, .unity)
    static let S2     = b("S2",     [2, 0, 0, 0, 0, 0], 0, .unity)
    static let R2     = b("R2",     [2, 0, 1, 0, 0, -1], 180, .unity)
    static let K2     = b("K2",     [2, 0, 2, 0, 0, 0], 0, .k2)

    static let M3     = b("M3",     [3, -3, 3, 0, 0, 0], 0, .m2Power(1.5))

    /// Elementary constituents keyed by NOAA name.
    static let elementary: [String: BaseConstituent] = {
        let all = [SA, SSA, MM, MF, Q2_1, SIGMA1, Q1, RHO1, O1, M1, CHI1, PI1, P1, S1, K1, PSI1, PHI1,
                   THETA1, J1, OO1, N2_2, MU2, N2, NU2, M2, LAM2, L2, T2, S2, R2, K2, M3]
        var map = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })
        map["RHO1"] = RHO1
        map["LAMBDA2"] = LAM2
        return map
    }()

    /// Letters that may appear in compound constituent names, mapped to the
    /// candidate parents (K is ambiguous between K1 and K2).
    static let compoundLetters: [Character: [BaseConstituent]] = [
        "M": [M2], "S": [S2], "N": [N2], "K": [K1, K2], "L": [L2], "O": [O1],
        "P": [P1], "Q": [Q1], "J": [J1], "T": [T2], "R": [R2],
    ]

    /// Known aliases where NOAA's name does not literally encode the parents.
    static let aliases: [String: String] = [
        "OO2": "OQ2", // O1 + Q1 (27.3417°/h)
    ]

    /// Constituents whose NOAA treatment differs from the literal reading of
    /// the name. Each was identified by fitting a full year of NOAA
    /// predictions for Anchorage (9455920) and comparing the complex
    /// amplitude of every line against ours.
    static let special: [String: ConstituentDefinition] = {
        func def(_ name: String, _ terms: [(BaseConstituent, Int)]) -> ConstituentDefinition {
            ConstituentDefinition(name: name, terms: terms.map { .init(base: $0.0, coefficient: $0.1) })
        }
        return [
            // Same speed as R2 − P1, but NOAA uses ψ1's argument (−90°) and f = 1.
            "RP1": def("RP1", [(PSI1, 1)]),
            // Same speed as K2 − P1; NOAA uses φ1 (f = 1).
            "KP1": def("KP1", [(PHI1, 1)]),
            // Same speed as T2 − K1; NOAA uses π1 (f = 1).
            "TK1": def("TK1", [(PI1, 1)]),
            // NOAA builds 3KM5 as K2 + K1 + M2 rather than 3·K1 + M2.
            "3KM5": def("3KM5", [(K2, 1), (K1, 1), (M2, 1)]),
            // NOAA applies O1² nodal modulation to σ1 (equivalent to 2·O1 − P1).
            "SIGMA1": def("SIGMA1", [(O1, 2), (P1, -1)]),
        ]
    }()

    /// Resolve a NOAA constituent name. `speed` (degrees/hour, as published by
    /// NOAA) disambiguates compound constituents.
    public static func definition(named rawName: String, speed: Double? = nil) -> ConstituentDefinition? {
        let name = rawName.uppercased()
        if name == "MSF" { return msf }
        if let def = special[name] { return def }
        if let base = elementary[name] {
            return ConstituentDefinition(name: name, terms: [.init(base: base, coefficient: 1)])
        }
        let resolvedName = aliases[name] ?? name
        return compound(named: resolvedName, displayName: name, speed: speed)
    }

    private static func compound(named name: String, displayName: String, speed target: Double?) -> ConstituentDefinition? {
        let targetSpeed = target
        // Split trailing species digits.
        guard let speciesRange = name.range(of: "[0-9]+$", options: .regularExpression),
              let species = Int(name[speciesRange]) else { return nil }
        let body = String(name[..<speciesRange.lowerBound])
        guard !body.isEmpty else { return nil }

        // Tokenise into (count, letter).
        var tokens: [(Int, Character)] = []
        var digits = ""
        for ch in body {
            if ch.isNumber { digits.append(ch); continue }
            guard compoundLetters[ch] != nil else { return nil }
            tokens.append((Int(digits) ?? 1, ch))
            digits = ""
        }
        guard digits.isEmpty, !tokens.isEmpty else { return nil }

        // Overtides, e.g. M4 = 2·M2, M6, M8, M10, S4, N4.
        if tokens.count == 1, tokens[0].0 == 1 {
            let candidates = compoundLetters[tokens[0].1]!
            for parent in candidates where parent.species > 0 && species % parent.species == 0 {
                let k = species / parent.species
                let def = ConstituentDefinition(name: displayName, terms: [.init(base: parent, coefficient: k)])
                if let t = targetSpeed, abs(def.speed - t) > 0.002 { continue }
                return def
            }
            return nil
        }

        // Enumerate parent choices (K1/K2) and signs; first term positive.
        // NOAA names sometimes omit a repeated multiplier (2MS8 = 2M2 + 2S2,
        // M2KS2 = M2 + 2K2 − 2S2), so if the literal counts do not reproduce
        // the published speed, retry allowing larger multipliers.
        let choices = tokens.map { compoundLetters[$0.1]! }
        func resolve(extraMultipliers: Bool) -> ConstituentDefinition? {
            var best: (def: ConstituentDefinition, err: Double, weight: Int)?
            func search(_ index: Int, _ terms: [ConstituentDefinition.Term]) {
                if index == tokens.count {
                    let sp = terms.reduce(0) { $0 + $1.coefficient * $1.base.species }
                    guard sp == species else { return }
                    let def = ConstituentDefinition(name: displayName, terms: terms)
                    let err = target.map { abs(def.speed - $0) } ?? 0
                    let weight = terms.reduce(0) { $0 + abs($1.coefficient) }
                    if let b = best {
                        if err > b.err + 1e-6 { return }
                        if abs(err - b.err) <= 1e-6 && weight >= b.weight { return }
                    }
                    best = (def, err, weight)
                    return
                }
                let counts = extraMultipliers ? Array(tokens[index].0...max(tokens[index].0, 4)) : [tokens[index].0]
                for parent in choices[index] {
                    for count in counts {
                        for sign in index == 0 ? [1] : [1, -1] {
                            search(index + 1, terms + [.init(base: parent, coefficient: sign * count)])
                        }
                    }
                }
            }
            search(0, [])
            guard let b = best else { return nil }
            if target != nil && b.err > 0.002 { return nil }
            return b.def
        }
        return resolve(extraMultipliers: false) ?? (target != nil ? resolve(extraMultipliers: true) : nil)
    }
}

extension ConstituentCatalog {
    /// MSf (lunisolar synodic fortnightly) = S2 − M2.
    static let msf = ConstituentDefinition(name: "MSF", terms: [.init(base: S2, coefficient: 1), .init(base: M2, coefficient: -1)])
}
