import Foundation

/// Summary of a set of time differences (seconds; positive = the station
/// is later than the reference).
public struct LagStatistics: Sendable, Hashable, Codable {
    public var mean: TimeInterval
    public var median: TimeInterval
    /// Sample standard deviation.
    public var standardDeviation: TimeInterval
    public var minimum: TimeInterval
    public var maximum: TimeInterval
    public var count: Int

    public init?(samples: [TimeInterval]) {
        guard !samples.isEmpty else { return nil }
        let n = Double(samples.count)
        let m = samples.reduce(0, +) / n
        let variance = samples.count > 1 ? samples.reduce(0) { $0 + ($1 - m) * ($1 - m) } / (n - 1) : 0
        let sorted = samples.sorted()
        mean = m
        median = sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        standardDeviation = variance.squareRoot()
        minimum = sorted.first!
        maximum = sorted.last!
        count = samples.count
    }
}

/// A reference extreme and the same-kind extreme at the other station that
/// it became.
public struct ExtremaPair: Sendable, Hashable {
    public var reference: TideExtreme
    public var station: TideExtreme
    /// Station time minus reference time.
    public var lag: TimeInterval { station.date.timeIntervalSince(reference.date) }

    public init(reference: TideExtreme, station: TideExtreme) {
        self.reference = reference
        self.station = station
    }
}

/// High- and low-water time differences and height ratios of a station
/// relative to a reference, in the spirit of NOAA's subordinate-station
/// tables but with the spread NOAA's single numbers hide.
public struct TidalOffsets: Sendable, Hashable, Codable {
    public var high: LagStatistics?
    public var low: LagStatistics?
    /// Mean range at the station over mean range at the reference.
    public var rangeRatio: Double?
    /// Mean high-water height ratio (heights above the prediction datum,
    /// normally MLLW, as NOAA's "R" height adjustments use).
    public var highHeightRatio: Double?
    public var lowHeightRatio: Double?
    /// Mean range at the station and at the reference, metres.
    public var meanRange: Double?
    public var referenceMeanRange: Double?
}

/// Result of a cross-correlation lag search.
public struct LagEstimate: Sendable, Hashable, Codable {
    /// Positive: the station's curve is later than the reference's.
    public var lag: TimeInterval
    /// Peak Pearson correlation.
    public var correlation: Double
    /// Overlapping samples at the peak.
    public var samples: Int
}

public enum OffsetAnalysis {
    /// Pairs each reference extreme with the station extreme of the same
    /// kind that it propagates to. A first pass takes the nearest same-kind
    /// extreme within `maxLag`; the second re-centres on the median lag
    /// (so lags beyond a quarter period still pair correctly) and keeps each
    /// station extreme at most once.
    public static func pairs(reference: [TideExtreme], station: [TideExtreme], kind: TideExtremeKind,
                             maxLag: TimeInterval = 6 * 3_600) -> [ExtremaPair] {
        let ref = reference.filter { $0.kind == kind }.sorted { $0.date < $1.date }
        let st = station.filter { $0.kind == kind }.sorted { $0.date < $1.date }
        guard !ref.isEmpty, !st.isEmpty else { return [] }

        func nearest(_ target: Date, within window: TimeInterval) -> Int? {
            // Binary search for the insertion point, then check neighbours.
            var lo = 0, hi = st.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if st[mid].date < target { lo = mid + 1 } else { hi = mid }
            }
            let candidates = [lo - 1, lo].filter { st.indices.contains($0) }
            guard let best = candidates.min(by: { abs(st[$0].date.timeIntervalSince(target)) < abs(st[$1].date.timeIntervalSince(target)) }),
                  abs(st[best].date.timeIntervalSince(target)) <= window else { return nil }
            return best
        }

        let first = ref.compactMap { r in nearest(r.date, within: maxLag).map { st[$0].date.timeIntervalSince(r.date) } }
        guard let centre = LagStatistics(samples: first)?.median else { return [] }

        // Half the shortest same-kind spacing around the expected time.
        let window = min(maxLag, 4 * 3_600)
        var chosen: [Int: ExtremaPair] = [:]
        for r in ref {
            guard let i = nearest(r.date + centre, within: window) else { continue }
            let pair = ExtremaPair(reference: r, station: st[i])
            if let existing = chosen[i], abs(existing.lag - centre) <= abs(pair.lag - centre) { continue }
            chosen[i] = pair
        }
        return chosen.values.sorted { $0.reference.date < $1.reference.date }
    }

    /// Mean of |h(i+1) − h(i)| over consecutive high/low extremes.
    public static func meanRange(_ extremes: [TideExtreme]) -> Double? {
        let e = extremes.sorted { $0.date < $1.date }
        let ranges = zip(e, e.dropFirst()).compactMap { a, b in a.kind != b.kind ? abs(b.height - a.height) : nil }
        guard !ranges.isEmpty else { return nil }
        return ranges.reduce(0, +) / Double(ranges.count)
    }

    /// Offsets of `station` relative to `reference` from two lists of
    /// extremes covering the same period. Pass `heightsAboveDatum: false`
    /// when heights are relative to MSL (height ratios are then meaningless).
    public static func offsets(reference: [TideExtreme], station: [TideExtreme],
                               heightsAboveDatum: Bool = true) -> TidalOffsets {
        let highs = pairs(reference: reference, station: station, kind: .high)
        let lows = pairs(reference: reference, station: station, kind: .low)
        let refRange = meanRange(reference), stRange = meanRange(station)
        func ratio(_ p: [ExtremaPair]) -> Double? {
            guard heightsAboveDatum, !p.isEmpty else { return nil }
            let r = p.reduce(0) { $0 + $1.reference.height }, s = p.reduce(0) { $0 + $1.station.height }
            return abs(r) > 0.05 * Double(p.count) ? s / r : nil
        }
        return TidalOffsets(high: LagStatistics(samples: highs.map(\.lag)),
                            low: LagStatistics(samples: lows.map(\.lag)),
                            rangeRatio: (refRange.flatMap { $0 > 0 ? $0 : nil }).flatMap { r in stRange.map { $0 / r } },
                            highHeightRatio: ratio(highs), lowHeightRatio: ratio(lows),
                            meanRange: stRange, referenceMeanRange: refRange)
    }

    // MARK: Cross-correlation

    /// Lag that best aligns the station's curve with the reference's, by
    /// Pearson cross-correlation on a regular grid. Both series are high-pass
    /// filtered first (a centred `detrendWindow` running mean is removed) so
    /// surge, river flow and datum offsets don't bias the result; gaps are
    /// skipped. Refined to sub-step precision with a parabola at the peak.
    public static func crossCorrelationLag(reference: TimeSeries, station: TimeSeries,
                                           maxLag: TimeInterval = 5 * 3_600, step: TimeInterval = 360,
                                           detrendWindow: TimeInterval = 25 * 3_600,
                                           minimumOverlap: TimeInterval = 2 * 86_400) -> LagEstimate? {
        guard let rr = reference.range, let sr = station.range else { return nil }
        let start = max(rr.lowerBound, sr.lowerBound) - maxLag, end = min(rr.upperBound, sr.upperBound) + maxLag
        guard end > start else { return nil }
        let a = highPassed(grid(reference, from: start, to: end, step: step), window: Int((detrendWindow / step).rounded()))
        let b = highPassed(grid(station, from: start, to: end, step: step), window: Int((detrendWindow / step).rounded()))
        let maxK = Int((maxLag / step).rounded())
        let minN = Int(minimumOverlap / step)

        var scores: [(k: Int, r: Double, n: Int)] = []
        for k in -maxK...maxK {
            var n = 0, sa = 0.0, sb = 0.0, saa = 0.0, sbb = 0.0, sab = 0.0
            for i in a.indices {
                let j = i + k
                guard j >= 0, j < b.count else { continue }
                let x = a[i], y = b[j]
                guard !x.isNaN, !y.isNaN else { continue }
                n += 1; sa += x; sb += y; saa += x * x; sbb += y * y; sab += x * y
            }
            guard n >= max(minN, 10) else { scores.append((k, -.infinity, n)); continue }
            let dn = Double(n)
            let cov = sab - sa * sb / dn
            let va = saa - sa * sa / dn, vb = sbb - sb * sb / dn
            scores.append((k, va > 0 && vb > 0 ? cov / (va * vb).squareRoot() : -.infinity, n))
        }
        guard let bestIndex = scores.indices.max(by: { scores[$0].r < scores[$1].r }), scores[bestIndex].r.isFinite else { return nil }
        var shift = 0.0
        if bestIndex > 0, bestIndex < scores.count - 1 {
            let y0 = scores[bestIndex - 1].r, y1 = scores[bestIndex].r, y2 = scores[bestIndex + 1].r
            let denom = y0 - 2 * y1 + y2
            if y0.isFinite, y2.isFinite, denom < 0 { shift = 0.5 * (y0 - y2) / denom }
        }
        let best = scores[bestIndex]
        return LagEstimate(lag: (Double(best.k) + shift) * step, correlation: best.r, samples: best.n)
    }

    /// Values on `start + i·step`, NaN where the series has no data (gaps
    /// over 30 minutes are not bridged).
    static func grid(_ s: TimeSeries, from start: Date, to end: Date, step: TimeInterval) -> [Double] {
        let count = Int(end.timeIntervalSince(start) / step) + 1
        return (0..<count).map { s.value(at: start + Double($0) * step, maxGap: 1_800) ?? .nan }
    }

    /// Removes a centred running mean of `window` samples, ignoring NaNs;
    /// samples whose window is under half full become NaN.
    static func highPassed(_ x: [Double], window: Int) -> [Double] {
        guard window > 1 else { return x }
        var sum = [0.0], cnt = [0]
        sum.reserveCapacity(x.count + 1); cnt.reserveCapacity(x.count + 1)
        for v in x {
            sum.append(sum.last! + (v.isNaN ? 0 : v))
            cnt.append(cnt.last! + (v.isNaN ? 0 : 1))
        }
        let half = window / 2
        return x.indices.map { i in
            guard !x[i].isNaN else { return .nan }
            let lo = max(0, i - half), hi = min(x.count, i + half + 1)
            let n = cnt[hi] - cnt[lo]
            guard n * 2 >= window else { return .nan }
            return x[i] - (sum[hi] - sum[lo]) / Double(n)
        }
    }

    // MARK: Observed extremes

    /// Highs and lows of a noisy observed record (6-minute gauge data):
    /// smoothed with a centred running mean to suppress seiche and wave
    /// noise, then located with parabolic refinement. Turns with less than
    /// `minimumRange` of relief are dropped.
    public static func observedExtrema(_ s: TimeSeries, smoothing: TimeInterval = 3_600, step: TimeInterval = 360,
                                       minimumRange: Double = 0.05) -> [TideExtreme] {
        guard let r = s.range else { return [] }
        let g = grid(s, from: r.lowerBound, to: r.upperBound, step: step)
        let w = max(1, Int((smoothing / step).rounded()))
        let trend = zip(g, highPassed(g, window: w)).map { $0 - $1 }
        var runs: [[TimeSeriesPoint]] = [[]]
        for (i, v) in trend.enumerated() {
            if v.isNaN {
                if !(runs.last?.isEmpty ?? true) { runs.append([]) }
            } else {
                runs[runs.count - 1].append(TimeSeriesPoint(date: r.lowerBound + Double(i) * step, value: v))
            }
        }
        let events = runs.flatMap { TimeSeries(points: $0).extrema(minimumSeparation: 2 * 3_600) }
        return HarmonicPredictor.filterInsignificant(events, minimumRange: minimumRange)
    }
}
