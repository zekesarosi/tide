import Foundation

/// Harmonic constants of a tidal current, resolved on the principal (major) axis and
/// the minor axis at right angles to it, as NOAA CO-OPS publishes them.
public struct CurrentConstituent: Sendable, Hashable, Codable {
    public var name: String
    /// Major-axis amplitude, knots.
    public var majorAmplitude: Double
    /// Major-axis Greenwich phase lag κ, degrees.
    public var majorPhaseGMT: Double
    /// Minor-axis amplitude, knots.
    public var minorAmplitude: Double
    /// Minor-axis Greenwich phase lag κ, degrees.
    public var minorPhaseGMT: Double

    public init(name: String, majorAmplitude: Double, majorPhaseGMT: Double, minorAmplitude: Double = 0, minorPhaseGMT: Double = 0) {
        self.name = name
        self.majorAmplitude = majorAmplitude
        self.majorPhaseGMT = majorPhaseGMT
        self.minorAmplitude = minorAmplitude
        self.minorPhaseGMT = minorPhaseGMT
    }
}

public enum CurrentEventKind: String, Sendable, Hashable, Codable {
    case maxFlood, maxEbb, slack
}

/// Maximum flood, maximum ebb or slack water.
public struct CurrentEvent: Sendable, Hashable, Codable {
    public var date: Date
    public var kind: CurrentEventKind
    /// Major-axis velocity, knots (flood positive, ebb negative; ~0 at slack).
    public var velocity: Double
}

/// Tidal current prediction at a NOAA harmonic current station (one depth bin), using
/// the same harmonic method as the water-level engine (`HarmonicPredictor`): node
/// factors, equilibrium arguments and compound tides are shared.
///
/// v(t) = v₀ + Σ fᵢ Aᵢ cos(Vᵢ(t) + uᵢ − κᵢ) along the major axis (flood positive),
/// and likewise for the minor axis, 90° clockwise of it (the convention NOAA's
/// speed-and-direction predictions use).
public struct TidalCurrentPredictor: Sendable {
    /// Flood direction of the major axis, degrees true.
    public let floodDirection: Double
    /// Mean current along the major axis, knots (river outflow, residual circulation).
    public let meanVelocity: Double
    /// Mean current along the minor axis, knots.
    public let meanMinorVelocity: Double
    let major: HarmonicPredictor
    let minor: HarmonicPredictor
    public var unresolvedConstituents: [String] { major.unresolvedConstituents }

    public init(constituents: [CurrentConstituent], floodDirection: Double, meanVelocity: Double = 0, meanMinorVelocity: Double = 0) {
        func harmonic(_ c: CurrentConstituent, minor: Bool) -> HarmonicConstituent {
            // Speeds aren't in NOAA's current files; the catalog knows every name.
            let speed = ConstituentCatalog.definition(named: c.name)?.speed ?? 0
            return HarmonicConstituent(name: c.name, amplitude: minor ? c.minorAmplitude : c.majorAmplitude,
                                       phaseGMT: minor ? c.minorPhaseGMT : c.majorPhaseGMT, speed: speed)
        }
        self.floodDirection = floodDirection
        self.meanVelocity = meanVelocity
        self.meanMinorVelocity = meanMinorVelocity
        major = HarmonicPredictor(constituents: constituents.map { harmonic($0, minor: false) }, meanLevel: meanVelocity)
        minor = HarmonicPredictor(constituents: constituents.map { harmonic($0, minor: true) }, meanLevel: meanMinorVelocity)
    }

    /// Major-axis velocity, knots: positive flood, negative ebb.
    public func velocity(at date: Date) -> Double { major.height(at: date) }

    /// Direction of the positive minor axis relative to the major (flood) axis, degrees.
    static let minorAxisOffset = 90.0

    /// Velocity along an arbitrary direction (e.g. a route leg), knots, from both axes.
    public func component(along bearing: Double, at date: Date) -> Double {
        vector(at: date).dot(ENUVector(direction: bearing, magnitude: 1))
    }

    /// Current vector, knots east/north (major and minor axes combined).
    public func vector(at date: Date) -> ENUVector {
        ENUVector(direction: floodDirection, magnitude: velocity(at: date))
            + ENUVector(direction: floodDirection + Self.minorAxisOffset, magnitude: minor.height(at: date))
    }

    /// Set (direction towards, degrees true) and drift (knots).
    public func setAndDrift(at date: Date) -> (set: Double, drift: Double) {
        let v = vector(at: date)
        return (v.direction, v.magnitude)
    }

    /// Major-axis velocities on a regular grid, knots.
    public func velocities(from start: Date, to end: Date, interval: TimeInterval = 600) -> TimeSeries {
        major.heights(from: start, to: end, interval: interval)
    }

    /// Slack waters (zero crossings of the major-axis velocity, to ~1 s) and the strongest
    /// flood or ebb between each pair of slacks, as in NOAA's tidal current tables.
    ///
    /// A flood or ebb that doesn't reach `minimumStrength` knots, or a phase without a slack
    /// on either side inside the window, is not reported as a maximum.
    public func events(from start: Date, to end: Date, minimumStrength: Double = 0.05) -> [CurrentEvent] {
        let step: TimeInterval = 600
        var slacks: [Date] = []
        var t0 = start, v0 = velocity(at: t0)
        while t0 < end {
            let t1 = min(t0 + step, end), v1 = velocity(at: t1)
            if (v0 > 0) != (v1 > 0) {
                var a = t0, b = t1, va = v0
                for _ in 0..<12 {
                    let m = a + b.timeIntervalSince(a) / 2, vm = velocity(at: m)
                    if (vm > 0) == (va > 0) { a = m; va = vm } else { b = m }
                }
                slacks.append(a + b.timeIntervalSince(a) / 2)
            }
            t0 = t1; v0 = v1
        }
        // Strongest current between slacks, from the analytic extrema of the major axis.
        let extrema = major.extremaUnfiltered(from: start, to: end)
        var out = slacks.map { CurrentEvent(date: $0, kind: .slack, velocity: velocity(at: $0)) }
        for (a, b) in zip(slacks, slacks.dropFirst()) {
            let inside = extrema.filter { $0.date > a && $0.date < b }
            guard let best = inside.max(by: { abs($0.height) < abs($1.height) }), abs(best.height) >= minimumStrength else { continue }
            out.append(CurrentEvent(date: best.date, kind: best.height > 0 ? .maxFlood : .maxEbb, velocity: best.height))
        }
        // Leading and trailing phases: report a maximum only if it is a true turning point.
        if let first = slacks.first, let e = extrema.filter({ $0.date < first }).max(by: { abs($0.height) < abs($1.height) }),
           abs(e.height) >= minimumStrength, e.date > start {
            out.append(CurrentEvent(date: e.date, kind: e.height > 0 ? .maxFlood : .maxEbb, velocity: e.height))
        }
        if let last = slacks.last, let e = extrema.filter({ $0.date > last }).max(by: { abs($0.height) < abs($1.height) }),
           abs(e.height) >= minimumStrength, e.date < end {
            out.append(CurrentEvent(date: e.date, kind: e.height > 0 ? .maxFlood : .maxEbb, velocity: e.height))
        }
        return out.sorted { $0.date < $1.date }
    }
}

extension HarmonicPredictor {
    /// Every turning point (no high/low alternation filter), for current maxima.
    func extremaUnfiltered(from start: Date, to end: Date) -> [TideExtreme] {
        // `extrema` merges same-kind neighbours and drops sub-centimetre wiggles; for
        // currents that would hide a weak second flood peak, so sample derivative signs
        // directly by asking for extrema on short windows.
        let step: TimeInterval = 1_200
        var out: [TideExtreme] = []
        var t = start
        var previous = height(at: t)
        var rising: Bool?
        while t < end {
            let next = min(t + step, end)
            let h = height(at: next)
            let up = h > previous
            if let r = rising, r != up {
                // A turning point between t − step and next: refine by ternary search.
                var a = t - step, b = next
                for _ in 0..<40 {
                    let m1 = a + b.timeIntervalSince(a) / 3, m2 = b - b.timeIntervalSince(a) / 3
                    let h1 = height(at: m1), h2 = height(at: m2)
                    if r ? h1 < h2 : h1 > h2 { a = m1 } else { b = m2 }
                }
                let tm = a + b.timeIntervalSince(a) / 2
                out.append(TideExtreme(date: tm, height: height(at: tm), kind: r ? .high : .low))
            }
            rising = up
            previous = h
            t = next
        }
        return out
    }
}

// MARK: - NOAA CO-OPS current harmonic constants

/// One depth bin's harmonic constants from `mdapi/.../stations/<id>/harcon.json` for a
/// current station.
public struct CurrentHarmonics: Sendable, Hashable {
    public var bin: Int
    /// Bin depth below the surface, metres.
    public var depth: Double?
    /// Major-axis (flood) azimuth, degrees true.
    public var azimuth: Double
    /// Mean current along the major axis, knots.
    public var meanMajor: Double
    /// Mean current along the minor axis, knots.
    public var meanMinor: Double
    public var constituents: [CurrentConstituent]

    public func predictor(floodDirection: Double? = nil) -> TidalCurrentPredictor {
        TidalCurrentPredictor(constituents: constituents, floodDirection: floodDirection ?? azimuth,
                              meanVelocity: meanMajor, meanMinorVelocity: meanMinor)
    }
}

extension NOAACoopsDecoding {
    static let knotsPerCentimetrePerSecond = 0.01 / Navigation.metersPerSecondPerKnot

    struct CurrentHarconDTO: Decodable {
        struct C: Decodable {
            let binNbr: Int
            let binDepth: Double?
            let constituentName: String
            let majorAmplitude: Double
            let majorPhaseGMT: Double
            let minorAmplitude: Double?
            let minorPhaseGMT: Double?
            let majorMeanSpeed: Double?
            let minorMeanSpeed: Double?
            let azi: Double?
        }
        let units: String?
        let HarmonicConstituents: [C]
    }

    /// Every bin in a current-station `harcon.json`. Amplitudes are converted to knots
    /// (the file is in cm/s with `units=metric`, knots with `units=english`).
    public static func currentHarmonics(from data: Data) throws -> [CurrentHarmonics] {
        let dto = try decode(CurrentHarconDTO.self, data)
        let factor = (dto.units ?? "").contains("knots") ? 1.0 : knotsPerCentimetrePerSecond
        let bins = Dictionary(grouping: dto.HarmonicConstituents, by: \.binNbr)
        return bins.keys.sorted().map { bin in
            let rows = bins[bin]!
            return CurrentHarmonics(
                bin: bin, depth: rows.first?.binDepth, azimuth: rows.first?.azi ?? 0,
                meanMajor: (rows.first?.majorMeanSpeed ?? 0) * factor,
                meanMinor: (rows.first?.minorMeanSpeed ?? 0) * factor,
                constituents: rows.map {
                    CurrentConstituent(name: $0.constituentName, majorAmplitude: $0.majorAmplitude * factor, majorPhaseGMT: $0.majorPhaseGMT,
                                       minorAmplitude: ($0.minorAmplitude ?? 0) * factor, minorPhaseGMT: $0.minorPhaseGMT ?? 0)
                })
        }
    }

    struct CurrentPredictionsDTO: Decodable {
        struct P: Decodable {
            let Time: String
            let Velocity_Major: Double
            let `Type`: String?
            let meanFloodDir: Double?
            let meanEbbDir: Double?
        }
        struct Body: Decodable { let units: String?; let cp: [P] }
        let current_predictions: Body
    }

    /// NOAA `currents_predictions` (any interval) as knots on the major axis.
    public static func currentPredictions(from data: Data) throws -> TimeSeries {
        let dto = try decode(CurrentPredictionsDTO.self, data)
        let factor = (dto.current_predictions.units ?? "").contains("knots") ? 1.0 : knotsPerCentimetrePerSecond
        return TimeSeries(points: dto.current_predictions.cp.compactMap { p in
            responseFormatter.date(from: p.Time).map { TimeSeriesPoint(date: $0, value: p.Velocity_Major * factor) }
        })
    }

    /// NOAA `currents_predictions` with `interval=MAX_SLACK`.
    public static func currentEvents(from data: Data) throws -> [CurrentEvent] {
        let dto = try decode(CurrentPredictionsDTO.self, data)
        let factor = (dto.current_predictions.units ?? "").contains("knots") ? 1.0 : knotsPerCentimetrePerSecond
        return dto.current_predictions.cp.compactMap { p in
            guard let d = responseFormatter.date(from: p.Time), let t = p.Type else { return nil }
            let kind: CurrentEventKind = t == "flood" ? .maxFlood : t == "ebb" ? .maxEbb : .slack
            return CurrentEvent(date: d, kind: kind, velocity: p.Velocity_Major * factor)
        }
    }
}

extension NOAACoopsClient {
    /// Harmonic constants for every bin of a current station (e.g. `SFB1203`, Golden Gate).
    public func currentHarmonics(station: String) async throws -> [CurrentHarmonics] {
        let ep = try Endpoint.build(.noaaCoops, "\(Self.metaBase)/stations/\(station)/harcon.json", ["units": "metric"], cacheTTL: 30 * 86_400)
        return try NOAACoopsDecoding.currentHarmonics(from: await api.data(for: ep))
    }
}

extension NOAACoopsDecoding {
    struct CurrentSpeedDirectionDTO: Decodable {
        struct P: Decodable { let Time: String; let Speed: String; let Direction: Double }
        struct Body: Decodable { let units: String?; let cp: [P] }
        let current_predictions: Body
    }

    /// NOAA `currents_predictions` with `vel_type=speed_dir`: speed (knots) and the
    /// direction the current sets towards (degrees true).
    public static func currentSpeedDirection(from data: Data) throws -> [(date: Date, speed: Double, direction: Double)] {
        let dto = try decode(CurrentSpeedDirectionDTO.self, data)
        let factor = (dto.current_predictions.units ?? "").contains("knots") ? 1.0 : knotsPerCentimetrePerSecond
        return dto.current_predictions.cp.compactMap { p in
            guard let d = responseFormatter.date(from: p.Time), let s = Double(p.Speed) else { return nil }
            return (d, s * factor, p.Direction)
        }
    }
}
