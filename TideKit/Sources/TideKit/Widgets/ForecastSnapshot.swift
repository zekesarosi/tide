import Foundation

/// A compact, self-contained copy of a forecast for widgets and other
/// lightweight surfaces. The app writes one per station after each forecast;
/// the widget extension reads it (and can rebuild it itself when stale).
///
/// Everything a widget renders between refreshes is derived from this value,
/// so a timeline can step the "now" marker forward without network access.
public struct ForecastSnapshot: Codable, Sendable, Hashable {
    public static let currentVersion = 1

    public struct Event: Codable, Sendable, Hashable, Identifiable {
        public var id: Date { date }
        public var date: Date
        public var kind: TideExtremeKind
        public var astronomical: Double
        public var surge: Double
        public var total: Double
        public var sigma: Double
        public var category: FloodCategory
        /// Probability of reaching minor flood level (nil without thresholds).
        public var minorFloodProbability: Double?
    }

    public var version: Int
    public var stationID: String
    public var stationName: String
    public var timeZoneIdentifier: String?
    public var datum: TidalDatum
    public var issued: Date
    public var calibrated: Bool

    /// Regular grid for the curves below: `start + i * step`.
    public var start: Date
    public var step: TimeInterval
    /// Forecast total water level (m above `datum`); NaN where unavailable.
    public var total: [Double]
    /// 1-σ uncertainty of `total` (m).
    public var sigma: [Double]
    /// Astronomical tide on the same grid (m).
    public var predicted: [Double]
    /// Recent observations, thinned (m).
    public var observed: [TimeSeriesPoint]

    public var latestObservation: TimeSeriesPoint?
    /// Latest observed water level minus the predicted tide (m).
    public var currentAnomaly: Double?
    public var events: [Event]
    public var minorFlood: Double?
    public var moderateFlood: Double?
    public var majorFlood: Double?
    public var alertTitles: [String]
    public var stormNames: [String]

    public var timeZone: TimeZone { timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .current }
    public var end: Date { start + step * Double(max(total.count - 1, 0)) }

    public init(forecast f: WaterLevelForecast, pastHours: Double = 12, futureHours: Double = 48, step: TimeInterval = 1_800) {
        version = Self.currentVersion
        stationID = f.station.id
        stationName = f.station.name
        timeZoneIdentifier = f.station.timeZoneIdentifier
        datum = f.datum
        issued = f.issued
        calibrated = f.model.calibrated
        self.step = step
        let s = Date(timeIntervalSince1970: ((f.issued.timeIntervalSince1970 - pastHours * 3_600) / step).rounded(.down) * step)
        start = s
        let n = Int(((min(f.horizon.timeIntervalSince(s), (pastHours + futureHours) * 3_600)) / step).rounded(.down)) + 1
        var tot: [Double] = [], sig: [Double] = [], pred: [Double] = []
        tot.reserveCapacity(n); sig.reserveCapacity(n); pred.reserveCapacity(n)
        for i in 0..<max(n, 0) {
            let t = s + Double(i) * step
            let p = f.astronomical.value(at: t, maxGap: 3_600)
            pred.append(p ?? .nan)
            if let m = f.total.value(at: t, maxGap: 3_600) {
                tot.append(m)
                let lo = f.totalLower.value(at: t, maxGap: 3_600), hi = f.totalUpper.value(at: t, maxGap: 3_600)
                sig.append(lo.flatMap { l in hi.map { ($0 - l) / (2 * 1.2816) } } ?? .nan)
            } else {
                tot.append(.nan)
                sig.append(.nan)
            }
        }
        total = tot
        sigma = sig
        predicted = pred
        // Thin observations to the grid step.
        var thinned: [TimeSeriesPoint] = []
        for p in f.observed.points where p.date >= s {
            if let last = thinned.last, p.date.timeIntervalSince(last.date) < step * 0.9 { continue }
            thinned.append(p)
        }
        observed = thinned
        latestObservation = f.latestObservation
        currentAnomaly = f.currentResidual?.value
        events = f.events.filter { $0.date <= s + Double(max(n - 1, 0)) * step }.map {
            Event(date: $0.date, kind: $0.kind, astronomical: $0.astronomical, surge: $0.surge, total: $0.total,
                  sigma: $0.sigma, category: $0.category, minorFloodProbability: $0.exceedance[.minor])
        }
        minorFlood = f.thresholds?.minor
        moderateFlood = f.thresholds?.moderate
        majorFlood = f.thresholds?.major
        alertTitles = f.alerts.map(\.event)
        stormNames = f.nearbyStorms.map(\.name)
    }

    // MARK: - Queries

    private func interpolate(_ values: [Double], at date: Date) -> Double? {
        guard !values.isEmpty else { return nil }
        let x = date.timeIntervalSince(start) / step
        guard x >= 0, x <= Double(values.count - 1) else { return nil }
        let i = Int(x.rounded(.down)), w = x - Double(i)
        let a = values[i]
        if w == 0 || i + 1 >= values.count { return a.isNaN ? nil : a }
        let b = values[i + 1]
        guard !a.isNaN, !b.isNaN else { return nil }
        return a + w * (b - a)
    }

    /// e-folding time for the gap between the latest measurement and the
    /// forecast to close.
    public static let observationAnchorHours = 1.0

    /// Best estimate of the water level at `date`. Near the latest
    /// observation it is anchored to it, so a widget shows what the gauge
    /// measured (as the app does), easing onto the forecast over the next
    /// hour or so rather than jumping. Otherwise the forecast, or the tide
    /// table plus the current anomaly.
    public func level(at date: Date) -> Double? {
        let forecast = interpolate(total, at: date)
        if let o = latestObservation {
            let lag = date.timeIntervalSince(o.date)
            if lag > -1_800 {
                guard let forecast else { return lag < 1_800 ? o.value : nil }
                if let atObservation = interpolate(total, at: o.date) {
                    let weight = exp(-max(lag, 0) / 3_600 / Self.observationAnchorHours)
                    return forecast + (o.value - atObservation) * weight
                }
            }
        }
        if let forecast { return forecast }
        return interpolate(predicted, at: date).map { $0 + (currentAnomaly ?? 0) }
    }

    public func predictedLevel(at date: Date) -> Double? { interpolate(predicted, at: date) }
    public func uncertainty(at date: Date) -> Double? { interpolate(sigma, at: date) }

    public func isRising(at date: Date) -> Bool? {
        guard let a = level(at: date - 600), let b = level(at: date + 600) else { return nil }
        return b > a
    }

    public func nextEvents(after date: Date, limit: Int = 2) -> [Event] {
        Array(events.filter { $0.date > date }.prefix(limit))
    }

    /// Highest flood category and minor-flood probability over the rest of the snapshot.
    public func floodOutlook(after date: Date) -> (category: FloodCategory, minorProbability: Double) {
        let upcoming = events.filter { $0.date > date && $0.kind == .high }
        return (upcoming.map(\.category).max() ?? .none, upcoming.compactMap(\.minorFloodProbability).max() ?? 0)
    }

    public struct ChartPoint: Sendable, Hashable, Identifiable {
        public var id: Date { date }
        public var date: Date
        public var total: Double?
        public var lower: Double?
        public var upper: Double?
        public var predicted: Double?
    }

    /// Points for a chart window, on the snapshot grid.
    public func chartPoints(from: Date, to: Date) -> [ChartPoint] {
        var out: [ChartPoint] = []
        for i in total.indices {
            let t = start + Double(i) * step
            guard t >= from - step, t <= to + step else { continue }
            let m = total[i].isNaN ? nil : total[i]
            let s = sigma[i].isNaN ? nil : sigma[i]
            out.append(ChartPoint(date: t, total: m, lower: m.flatMap { v in s.map { v - 1.2816 * $0 } },
                                  upper: m.flatMap { v in s.map { v + 1.2816 * $0 } },
                                  predicted: predicted[i].isNaN ? nil : predicted[i]))
        }
        return out
    }

    /// Age beyond which a surface should say the forecast is out of date.
    public func isStale(at date: Date, after: TimeInterval = 3 * 3_600) -> Bool {
        date.timeIntervalSince(issued) > after
    }
}

extension ForecastSnapshot {
    /// A deterministic, clearly synthetic snapshot for widget placeholders
    /// and previews (semi-diurnal tide with a small positive surge).
    public static func sample(now: Date = Date(), name: String = "Sample Harbor") -> ForecastSnapshot {
        let station = Station(source: .noaaCoops, code: "sample", name: name, latitude: 0, longitude: 0,
                              timeZoneIdentifier: TimeZone.current.identifier)
        let tide = [HarmonicConstituent(name: "M2", amplitude: 0.8, phaseGMT: 0, speed: 28.984104),
                    HarmonicConstituent(name: "S2", amplitude: 0.2, phaseGMT: 30, speed: 30.0),
                    HarmonicConstituent(name: "K1", amplitude: 0.35, phaseGMT: 200, speed: 15.041069)]
        let predictor = HarmonicPredictor(constituents: tide, meanLevel: 1.0)
        var obs: [TimeSeriesPoint] = []
        var t = now - 3 * 86_400
        while t <= now { obs.append(.init(date: t, value: predictor.height(at: t) + 0.15)); t += 360 }
        let forcing = (0..<(24 * 6)).map { h in
            MetSample(date: now - 3 * 86_400 + Double(h) * 3_600, pressure: 1012, windSpeed: 5, windDirection: 270)
        }
        let f = TotalWaterLevelForecaster.forecast(ForecastInputs(
            station: station, datum: .mllw, issueTime: now, horizonHours: 48, astronomical: .harmonic(predictor),
            observations: TimeSeries(points: obs), forcing: forcing,
            thresholds: FloodThresholds(datum: .mllw, minor: 2.4, moderate: 2.8, major: 3.2)))
        return ForecastSnapshot(forecast: f)
    }
}
