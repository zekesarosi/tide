import Foundation

/// A harmonic constituent as published by a tidal agency.
public struct HarmonicConstituent: Sendable, Hashable, Codable {
    public var name: String
    /// Amplitude in metres.
    public var amplitude: Double
    /// Greenwich phase lag κ (degrees, referenced to UTC).
    public var phaseGMT: Double
    /// Angular speed in degrees per hour.
    public var speed: Double

    public init(name: String, amplitude: Double, phaseGMT: Double, speed: Double) {
        self.name = name
        self.amplitude = amplitude
        self.phaseGMT = phaseGMT
        self.speed = speed
    }
}

/// Astronomical tide prediction from harmonic constants using the same method
/// as NOAA CO-OPS: h(t) = Z0 + Σ fᵢHᵢ cos(Vᵢ(t) + uᵢ − κᵢ).
///
/// Nodal factors (f, u) are evaluated at the midpoint of each 30-day segment
/// and the equilibrium argument advanced linearly at the constituent speed.
public struct HarmonicPredictor: Sendable {
    struct Term: Sendable {
        let definition: ConstituentDefinition
        let amplitude: Double
        let kappa: Double
        let speed: Double
    }

    let terms: [Term]
    /// Constituents that could not be resolved (ignored in predictions).
    public let unresolvedConstituents: [String]
    /// Height of mean sea level above the output datum (Z0), metres.
    public let meanLevel: Double

    static let segmentLength: TimeInterval = 30 * 86_400

    public init(constituents: [HarmonicConstituent], meanLevel: Double = 0) {
        var terms: [Term] = []
        var unresolved: [String] = []
        for c in constituents where c.amplitude != 0 {
            if let def = ConstituentCatalog.definition(named: c.name, speed: c.speed) {
                terms.append(Term(definition: def, amplitude: c.amplitude, kappa: c.phaseGMT, speed: c.speed))
            } else {
                unresolved.append(c.name)
            }
        }
        self.terms = terms
        self.unresolvedConstituents = unresolved
        self.meanLevel = meanLevel
    }

    public var constituentCount: Int { terms.count }

    /// Precomputed per-segment state.
    struct Segment {
        let center: Date
        let amplitudes: [Double] // f·H
        let phases: [Double]     // radians at `center`
        let speeds: [Double]     // radians per second
    }

    /// Segments are aligned to UTC calendar years so that every instant in a
    /// year shares that year's node factors, as in NOAA's prediction system.
    static func segmentKey(for date: Date) -> (key: Double, center: Date, year: Int) {
        let year = utcCalendar.component(.year, from: date)
        let yearStart = utcCalendar.date(from: DateComponents(year: year, month: 1, day: 1))!
        let index = (date.timeIntervalSince(yearStart) / segmentLength).rounded(.down)
        let start = yearStart + index * segmentLength
        return (start.timeIntervalSince1970, start + segmentLength / 2, year)
    }

    func segment(containing date: Date) -> Segment {
        let (_, center, year) = Self.segmentKey(for: date)
        let astro = AstronomicalArguments(date: center)
        // NOAA evaluates node factors once per calendar year, at mid-year.
        let nodalAstro = AstronomicalArguments(date: Self.midYear(of: year))
        var amps: [Double] = [], phases: [Double] = [], speeds: [Double] = []
        amps.reserveCapacity(terms.count)
        for t in terms {
            let (f, u) = t.definition.nodalFactors(nodalAstro)
            let v = t.definition.equilibriumArgument(astro)
            amps.append(f * t.amplitude)
            phases.append((v + u - t.kappa).radians)
            speeds.append(t.speed.radians / 3_600)
        }
        return Segment(center: center, amplitudes: amps, phases: phases, speeds: speeds)
    }

    static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    static func midYear(of year: Int) -> Date {
        let start = utcCalendar.date(from: DateComponents(year: year, month: 1, day: 1))!
        let end = utcCalendar.date(from: DateComponents(year: year + 1, month: 1, day: 1))!
        return start + end.timeIntervalSince(start) / 2
    }

    private func evaluate(_ s: Segment, _ date: Date) -> (h: Double, dh: Double) {
        let dt = date.timeIntervalSince(s.center)
        var h = meanLevel, dh = 0.0
        for i in s.amplitudes.indices {
            let arg = s.phases[i] + s.speeds[i] * dt
            h += s.amplitudes[i] * cos(arg)
            dh -= s.amplitudes[i] * s.speeds[i] * sin(arg)
        }
        return (h, dh)
    }

    /// Predicted height at a single instant (metres above the output datum).
    public func height(at date: Date) -> Double {
        evaluate(segment(containing: date), date).h
    }

    /// Predicted heights on a regular grid.
    public func heights(from start: Date, to end: Date, interval: TimeInterval = 600) -> TimeSeries {
        guard end >= start, interval > 0 else { return .empty }
        var out: [TimeSeriesPoint] = []
        out.reserveCapacity(Int(end.timeIntervalSince(start) / interval) + 1)
        var cache: (key: Double, seg: Segment)?
        var t = start
        while t <= end {
            let key = Self.segmentKey(for: t).key
            let seg: Segment
            if let c = cache, c.key == key { seg = c.seg } else { seg = segment(containing: t); cache = (key, seg) }
            out.append(.init(date: t, value: evaluate(seg, t).h))
            t += interval
        }
        return TimeSeries(points: out)
    }

    /// High and low waters, located to within ~1 second by bisection on the
    /// analytic derivative.
    public func extrema(from start: Date, to end: Date) -> [TideExtreme] {
        let step: TimeInterval = 1_200
        var out: [TideExtreme] = []
        var cache: (key: Double, seg: Segment)?
        func seg(_ t: Date) -> Segment {
            let key = Self.segmentKey(for: t).key
            if let c = cache, c.key == key { return c.seg }
            let s = segment(containing: t); cache = (key, s); return s
        }
        var t0 = start
        var d0 = evaluate(seg(t0), t0).dh
        while t0 < end {
            let t1 = min(t0 + step, end)
            let d1 = evaluate(seg(t1), t1).dh
            if d0 == 0 || (d0 > 0) != (d1 > 0) {
                var a = t0, b = t1, da = d0
                for _ in 0..<12 {
                    let m = a + b.timeIntervalSince(a) / 2
                    let dm = evaluate(seg(m), m).dh
                    if (dm > 0) == (da > 0) { a = m; da = dm } else { b = m }
                }
                let tm = a + b.timeIntervalSince(a) / 2
                let kind: TideExtremeKind = d0 > 0 ? .high : .low
                out.append(TideExtreme(date: tm, height: evaluate(seg(tm), tm).h, kind: kind))
            }
            t0 = t1
            d0 = d1
        }
        return Self.filterInsignificant(out)
    }

    /// Drops tiny "wiggles" (e.g. double low waters with < 1 cm relief) so
    /// event lists alternate high/low the way published tables do.
    static func filterInsignificant(_ events: [TideExtreme], minimumRange: Double = 0.01) -> [TideExtreme] {
        var out: [TideExtreme] = []
        for e in events {
            if let last = out.last {
                if last.kind == e.kind {
                    let better = e.kind == .high ? e.height > last.height : e.height < last.height
                    if better { out[out.count - 1] = e }
                    continue
                }
                if abs(last.height - e.height) < minimumRange {
                    out.removeLast()
                    continue
                }
            }
            out.append(e)
        }
        return out
    }
}
