import Foundation

/// Where the astronomical tide comes from.
public enum AstronomicalSource: Sendable {
    /// Local harmonic prediction (NOAA harmonic constants).
    case harmonic(HarmonicPredictor)
    /// Provider-supplied prediction series (DFO, subordinate stations, UK events).
    case series(TimeSeries)
    /// Non-tidal water body (e.g. Great Lakes). The forecaster substitutes
    /// the recent mean observed level as the baseline.
    case none
    /// A constant baseline level (used for non-tidal water bodies).
    case constant(Double)

    var isTidal: Bool {
        switch self {
        case .harmonic, .series: return true
        case .none, .constant: return false
        }
    }

    func height(at date: Date) -> Double? {
        switch self {
        case .harmonic(let p): return p.height(at: date)
        case .series(let s): return s.value(at: date, maxGap: 8 * 3_600)
        case .none: return 0
        case .constant(let c): return c
        }
    }

    /// Level and rate of change (m/h) for tide–surge interaction features.
    func covariates(at date: Date) -> (level: Double, rate: Double)? {
        guard isTidal, let h = height(at: date),
              let a = height(at: date - 300), let b = height(at: date + 300) else { return nil }
        return (h, (b - a) / (600.0 / 3_600))
    }

    func curve(from: Date, to: Date, step: TimeInterval) -> TimeSeries {
        switch self {
        case .harmonic(let p): return p.heights(from: from, to: to, interval: step)
        case .series(let s): return s.resampled(step: step, from: from, to: to, maxGap: 8 * 3_600)
        case .none, .constant:
            let v = height(at: from) ?? 0
            var pts: [TimeSeriesPoint] = []
            var t = from
            while t <= to { pts.append(.init(date: t, value: v)); t += step }
            return TimeSeries(points: pts)
        }
    }

    func extrema(from: Date, to: Date) -> [TideExtreme] {
        switch self {
        case .harmonic(let p): return p.extrema(from: from, to: to)
        case .series(let s): return s.resampled(step: 300, from: from, to: to, maxGap: 8 * 3_600).extrema()
        case .none, .constant: return []
        }
    }
}

public struct ForecastInputs: Sendable {
    public var station: Station
    public var datum: TidalDatum
    public var issueTime: Date
    public var horizonHours: Int
    public var astronomical: AstronomicalSource
    /// Observed water level relative to `datum` (any sampling, typically 6-min).
    public var observations: TimeSeries
    public var forcing: [MetSample]
    public var official: OfficialForecast?
    /// Flood thresholds already converted to `datum`.
    public var thresholds: FloodThresholds?
    public var alerts: [WeatherAlert]
    public var storms: [TropicalCyclone]

    public init(station: Station, datum: TidalDatum, issueTime: Date, horizonHours: Int, astronomical: AstronomicalSource,
                observations: TimeSeries, forcing: [MetSample], official: OfficialForecast? = nil,
                thresholds: FloodThresholds? = nil, alerts: [WeatherAlert] = [], storms: [TropicalCyclone] = []) {
        self.station = station
        self.datum = datum
        self.issueTime = issueTime
        self.horizonHours = horizonHours
        self.astronomical = astronomical
        self.observations = observations
        self.forcing = forcing
        self.official = official
        self.thresholds = thresholds
        self.alerts = alerts
        self.storms = storms
    }
}

public struct SurgeForecastPoint: Sendable, Hashable, Identifiable {
    public var id: Date { date }
    public var date: Date
    /// Blended non-tidal residual (m).
    public var surge: Double
    public var sigma: Double
    public var pressureComponent: Double
    public var windComponent: Double
    /// Tide–surge interaction / prediction drift correction.
    public var tideInteractionComponent: Double
    public var offsetComponent: Double
    public var persistenceComponent: Double
    /// Official guidance surge (aligned & bias corrected), if available.
    public var officialSurge: Double?
    /// Weight given to the official guidance in the blend (0…1).
    public var officialWeight: Double
}

public struct ForecastEvent: Sendable, Hashable, Identifiable {
    public var id: Date { date }
    public var date: Date
    public var kind: TideExtremeKind
    public var astronomical: Double
    public var surge: Double
    public var total: Double
    public var sigma: Double
    public var category: FloodCategory
    /// Probability that the total water level reaches each category.
    public var exceedance: [FloodCategory: Double]

    public var lower80: Double { total - 1.2816 * sigma }
    public var upper80: Double { total + 1.2816 * sigma }
}

public struct WaterLevelForecast: Sendable, Hashable {
    public var station: Station
    public var datum: TidalDatum
    public var issued: Date
    public var horizon: Date

    /// 10-minute astronomical tide over the display window.
    public var astronomical: TimeSeries
    /// Raw observations (display window).
    public var observed: TimeSeries
    /// Hourly observed residual (observed − astronomical) over the display window.
    public var observedResidual: TimeSeries
    /// Hourly surge forecast with components.
    public var surge: [SurgeForecastPoint]
    /// 10-minute total water level forecast and 80 % band.
    public var total: TimeSeries
    public var totalLower: TimeSeries
    public var totalUpper: TimeSeries
    /// Official guidance aligned to `datum` (total water level).
    public var officialTotal: TimeSeries?

    public var events: [ForecastEvent]
    public var thresholds: FloodThresholds?
    public var model: SurgeModelDiagnostics
    public var alerts: [WeatherAlert]
    public var nearbyStorms: [TropicalCyclone]
    public var notes: [String]
    public var method: Method

    public enum Method: String, Sendable, Hashable {
        /// Calibrated regression + AR(1) persistence (+ official blend).
        case calibrated
        /// No usable observations: inverse barometer only.
        case uncalibrated
        /// No forcing available: persistence of recent residual only.
        case persistenceOnly
    }

    public var latestObservation: TimeSeriesPoint? { observed.last }
    public var currentResidual: TimeSeriesPoint? { observedResidual.last }

    /// Highest flood category forecast (by mean) and the largest probability
    /// of reaching minor flooding over the horizon.
    public var peakCategory: FloodCategory { events.map(\.category).max() ?? .none }
    public var maxMinorFloodProbability: Double { events.compactMap { $0.exceedance[.minor] }.max() ?? 0 }
}

/// Combines astronomical tide, the calibrated surge model and official
/// guidance into a probabilistic total water level forecast. Pure and
/// deterministic: all I/O happens in `ForecastService`.
public enum TotalWaterLevelForecaster {
    public static let trainingDays = 30
    public static let displayPastHours = 48
    public static let stormInfluenceRadius = 1_000_000.0 // metres

    public static func forecast(_ input: ForecastInputs) -> WaterLevelForecast {
        let now = input.issueTime
        let horizon = now + Double(input.horizonHours) * 3_600
        let displayStart = now - Double(displayPastHours) * 3_600
        var notes: [String] = []

        // Hourly residuals over the training window.
        let obsHourly = input.observations.hourlyMeans()
        var astronomical = input.astronomical
        if case .none = astronomical {
            // Non-tidal: anomalies are measured from the recent mean level.
            let recent = obsHourly.sliced(from: now - Double(trainingDays) * 86_400, to: now).values
            astronomical = .constant(recent.isEmpty ? 0 : Stats.mean(recent))
            notes.append("Non-tidal water body: surge is shown relative to the 30-day mean level (seiche and wind set-up).")
        }
        let residuals = TimeSeries(points: obsHourly.points.compactMap { p in
            astronomical.height(at: p.date).map { TimeSeriesPoint(date: p.date, value: p.value - $0) }
        })
        let tide: TideCovariates? = astronomical.isTidal ? { astronomical.covariates(at: $0) } : nil
        let features = SurgeModel.meteorologicalFeatures + (astronomical.isTidal ? SurgeModel.tideFeatures : [])

        // Storms nearby inflate model uncertainty — statistical models do not
        // capture tropical cyclone surge well.
        let nearby = input.storms.filter {
            ($0.distance(toLatitude: input.station.latitude, longitude: input.station.longitude) ?? .infinity) < stormInfluenceRadius
        }
        let inflation = nearby.isEmpty ? 1.0 : 2.0
        if !nearby.isEmpty {
            notes.append("Tropical cyclone \(nearby.map(\.name).joined(separator: ", ")) is within 1,000 km. Statistical surge guidance is unreliable in tropical cyclones; follow NHC and local NWS forecasts.")
        }

        // Forcing timeline (fallback to a neutral hourly grid if unavailable).
        var forcing = input.forcing.filter { $0.date >= now - Double(trainingDays + 3) * 86_400 && $0.date <= horizon + 3_600 }
        var method: WaterLevelForecast.Method = .calibrated
        let model: SurgeModel
        if forcing.count < 48 {
            forcing = neutralForcing(from: now - Double(trainingDays) * 86_400, to: horizon)
            method = .persistenceOnly
            model = persistenceModel(residuals: residuals)
            notes.append("Weather forcing unavailable — surge forecast is persistence of the recent observed anomaly only.")
        } else if let fitted = try? SurgeModel.fit(residuals: residuals, forcing: forcing, features: features, tide: tide) {
            model = fitted
        } else if residuals.count >= 24 {
            method = .uncalibrated
            model = blendedFallback(residuals: residuals)
            notes.append("Not enough overlapping observations to calibrate wind response; using inverse barometer with observed mean offset.")
        } else {
            method = .uncalibrated
            model = .uncalibrated()
            notes.append("No recent observations at this station — surge uses an uncalibrated inverse-barometer estimate and is less reliable.")
        }

        let modelPreds = model.forecast(forcing: forcing, recentResiduals: residuals, issueTime: now,
                                        horizonHours: input.horizonHours, tide: tide, sigmaInflation: inflation)

        // Official guidance (NWPS): align datum, convert to surge, bias-correct.
        var officialTotal: TimeSeries?
        var officialSurge: [Date: (value: Double, sigma: Double)] = [:]
        if let off = input.official {
            if let aligned = align(official: off, observations: input.observations, now: now) {
                officialTotal = aligned.total.sliced(from: displayStart, to: horizon)
                let s = aligned.total.hourlyMeans(minSamples: 1)
                var overlap: [Double] = []
                for p in s.points where p.date <= now && p.date >= (off.issued ?? now - 12 * 3_600) {
                    if let r = residuals.value(at: p.date, maxGap: 1.5 * 3_600), let a = astronomical.height(at: p.date) {
                        overlap.append(r - (p.value - a))
                    }
                }
                let bias = overlap.count >= 3 ? Stats.mean(overlap) : 0
                let sigma0 = max(0.04, overlap.count >= 3 ? Stats.rms(overlap.map { $0 - bias }) : 0.08)
                for p in s.points where p.date > now && p.date <= horizon {
                    guard let a = astronomical.height(at: p.date) else { continue }
                    let k = p.date.timeIntervalSince(now) / 3_600
                    let corrected = (p.value - a) + bias * pow(model.phi, k)
                    let sigma = (sigma0 + 0.01 * k / 6) * inflation.squareRoot()
                    officialSurge[p.date] = (corrected, sigma)
                }
                notes.append(aligned.note)
            } else {
                notes.append("Official NWS forecast found but couldn't be aligned to the station datum (no overlapping observations); not blended.")
            }
        }

        // Blend.
        let rho = 0.5
        let surge: [SurgeForecastPoint] = modelPreds.map { m in
            var point = SurgeForecastPoint(date: m.date, surge: m.mean, sigma: m.sigma, pressureComponent: m.pressureComponent,
                                           windComponent: m.windComponent, tideInteractionComponent: m.tideInteractionComponent,
                                           offsetComponent: m.offsetComponent,
                                           persistenceComponent: m.persistenceComponent, officialSurge: nil, officialWeight: 0)
            if let o = officialSurge[m.date] {
                let w1 = 1 / (m.sigma * m.sigma), w2 = 1 / (o.sigma * o.sigma)
                let a = w1 / (w1 + w2), b = w2 / (w1 + w2)
                point.surge = a * m.mean + b * o.value
                let v = a * a * m.sigma * m.sigma + b * b * o.sigma * o.sigma + 2 * rho * a * b * m.sigma * o.sigma
                point.sigma = v.squareRoot()
                point.officialSurge = o.value
                point.officialWeight = b
            }
            return point
        }

        // Display curves.
        let astro10 = astronomical.curve(from: displayStart, to: horizon, step: 600)
        let surgeMean = TimeSeries(points: surge.map { .init(date: $0.date, value: $0.surge) })
        let surgeSigma = TimeSeries(points: surge.map { .init(date: $0.date, value: $0.sigma) })
        // Start the forecast curve from the current anomaly so it joins the observations.
        var meanPts = surgeMean.points, sigPts = surgeSigma.points
        if let r = residuals.last, r.date <= now, now.timeIntervalSince(r.date) < 3 * 3_600 {
            meanPts.insert(.init(date: r.date, value: r.value), at: 0)
            sigPts.insert(.init(date: r.date, value: 0.01), at: 0)
        }
        let meanSeries = TimeSeries(points: meanPts), sigSeries = TimeSeries(points: sigPts)
        var total: [TimeSeriesPoint] = [], lower: [TimeSeriesPoint] = [], upper: [TimeSeriesPoint] = []
        let z80 = 1.2816
        for p in astro10.points where p.date >= (meanSeries.first?.date ?? now) {
            guard let s = meanSeries.value(at: p.date, maxGap: 2 * 3_600), let sd = sigSeries.value(at: p.date, maxGap: 2 * 3_600) else { continue }
            total.append(.init(date: p.date, value: p.value + s))
            lower.append(.init(date: p.date, value: p.value + s - z80 * sd))
            upper.append(.init(date: p.date, value: p.value + s + z80 * sd))
        }

        // Events at astronomical extrema.
        let extremes = astronomical.extrema(from: now, to: horizon)
        let events: [ForecastEvent] = extremes.compactMap { e in
            guard let s = meanSeries.value(at: e.date, maxGap: 2 * 3_600), let sd = sigSeries.value(at: e.date, maxGap: 2 * 3_600) else { return nil }
            let tot = e.height + s
            var exceed: [FloodCategory: Double] = [:]
            if let th = input.thresholds, e.kind == .high {
                for c in FloodCategory.allCases where c != .none {
                    if let t = th.threshold(for: c) { exceed[c] = 1 - Stats.normalCDF((t - tot) / max(sd, 1e-6)) }
                }
            }
            return ForecastEvent(date: e.date, kind: e.kind, astronomical: e.height, surge: s, total: tot, sigma: sd,
                                 category: input.thresholds?.category(for: tot) ?? .none, exceedance: exceed)
        }

        if input.thresholds == nil || input.thresholds?.isEmpty == true {
            notes.append("No official flood thresholds are published for this station.")
        }

        let displayResidual = residuals.sliced(from: displayStart, to: now)
        return WaterLevelForecast(
            station: input.station, datum: input.datum, issued: now, horizon: horizon,
            astronomical: astro10, observed: input.observations.sliced(from: displayStart, to: now),
            observedResidual: displayResidual, surge: surge,
            total: TimeSeries(points: total), totalLower: TimeSeries(points: lower), totalUpper: TimeSeries(points: upper),
            officialTotal: officialTotal, events: events, thresholds: input.thresholds, model: model.diagnostics,
            alerts: input.alerts.filter(\.isCoastal), nearbyStorms: nearby, notes: notes, method: method)
    }

    // MARK: - Helpers

    static func neutralForcing(from: Date, to: Date) -> [MetSample] {
        var out: [MetSample] = []
        var t = Date(timeIntervalSince1970: (from.timeIntervalSince1970 / 3_600).rounded(.down) * 3_600)
        while t <= to + 3_600 {
            out.append(MetSample(date: t, pressure: SurgeModel.referencePressure, windSpeed: 0, windDirection: 0))
            t += 3_600
        }
        return out
    }

    /// Persistence-only: mean offset + learned decay of the latest anomaly.
    static func persistenceModel(residuals: TimeSeries) -> SurgeModel {
        guard residuals.count >= 24 else { return .uncalibrated() }
        let recent = residuals.sliced(from: (residuals.last?.date ?? Date()) - 7 * 86_400, to: .distantFuture).values
        let offset = Stats.mean(recent)
        let anomalies = residuals.values.map { $0 - offset }
        let p = SurgeModel.learnPersistence(errors: anomalies, dates: residuals.dates)
        var d = SurgeModelDiagnostics(calibrated: false)
        d.trainingHours = residuals.count
        d.residualRMS = Stats.rms(residuals.values)
        d.persistenceEFoldingHours = p.phi > 0 && p.phi < 1 ? -1 / log(p.phi) : (p.phi >= 1 ? .infinity : 0)
        return SurgeModel(features: [], coefficients: [offset], phi: p.phi, anchorHours: p.window,
                          leadErrors: p.leadErrors, signalSigma: 0, diagnostics: d)
    }

    static func blendedFallback(residuals: TimeSeries) -> SurgeModel {
        var m = persistenceModel(residuals: residuals)
        m.features = [.init(kind: .pressure, memoryHours: 3)]
        m.coefficients = [m.coefficients.first ?? 0, -0.0099]
        m.signalSigma = 0.05
        m.diagnostics.inverseBarometerCmPerHPa = -0.99
        return m
    }

    struct AlignedOfficial {
        var total: TimeSeries
        var offset: Double
        var note: String
    }

    /// NWPS publishes stage in the gauge's own datum. Estimate the offset to
    /// our datum as the median difference between its observed series and
    /// CO-OPS observations over the last 3 days (both are the same physical
    /// water level, so the difference is a pure datum shift).
    static func align(official: OfficialForecast, observations: TimeSeries, now: Date) -> AlignedOfficial? {
        let start = now - 3 * 86_400
        var diffs: [Double] = []
        for p in official.observed.points where p.date >= start && p.date <= now {
            if let o = observations.value(at: p.date, maxGap: 900) { diffs.append(o - p.value) }
        }
        guard diffs.count >= 12 else { return nil }
        let offset = Stats.median(diffs)
        // Datum shifts are constant; a large spread means the series don't match.
        let spread = Stats.median(diffs.map { abs($0 - offset) })
        guard spread < 0.1 else { return nil }
        let issued = official.issued.map { DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short) } ?? "recently"
        return AlignedOfficial(total: official.forecast.mapValues { $0 + offset }, offset: offset,
                               note: "Blended with the official NWS coastal forecast issued \(issued) (datum aligned by \(String(format: "%+.2f", offset)) m).")
    }
}
