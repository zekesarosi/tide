import Foundation

/// Astronomical tide covariates at an instant: level (m) and rate (m/h).
public typealias TideCovariates = (Date) -> (level: Double, rate: Double)?

/// A station-calibrated statistical storm-surge model.
///
/// The non-tidal residual (observed − astronomical tide) is regressed on
/// meteorological forcing and tide state:
///
///     r(t) = β₀ + β_P·ΔP̃(t) + Σ_k [β_xk·τ̃x,k(t) + β_yk·τ̃y,k(t)] + β_h·η(t) + β_ḣ·η̇(t) + e(t)
///
/// * ΔP̃ — sea-level pressure anomaly (hPa) with a short exponential memory;
///   the inverse-barometer effect (≈ −1 cm/hPa in theory).
/// * τ̃x,k, τ̃y,k — quadratic wind-stress proxies |U|·u and |U|·v filtered
///   with fast and slow exponential memories (local set-up vs. shelf/basin
///   response). Fitting both components lets each station learn its own
///   coastline orientation and Ekman response.
/// * η, η̇ — astronomical tide level and rate. These absorb tide–surge
///   interaction and systematic amplitude/phase drift of the predicted tide
///   (large in shallow estuaries such as Cook Inlet), which otherwise
///   appears as tidal-band "noise" in the residual.
/// * β₀ — current mean-sea-level anomaly vs. the datum epoch.
///
/// Remaining error is handled by *learned persistence*: the mean error over
/// the last `anchorHours` is carried forward and decays as φᵏ, with (φ,
/// window) chosen to minimise multi-lead forecast error on the training
/// data. Forecast σ at each lead comes from the empirical error at that lead,
/// plus growth for imperfect forcing forecasts.
public struct SurgeModel: Sendable, Hashable, Codable {
    public struct Feature: Sendable, Hashable, Codable {
        public enum Kind: String, Sendable, Codable { case pressure, windX, windY, tideLevel, tideRate }
        public var kind: Kind
        /// e-folding memory in hours (0 = instantaneous).
        public var memoryHours: Double
    }

    public static let meteorologicalFeatures: [Feature] = [
        .init(kind: .pressure, memoryHours: 3),
        .init(kind: .windX, memoryHours: 3), .init(kind: .windY, memoryHours: 3),
        .init(kind: .windX, memoryHours: 18), .init(kind: .windY, memoryHours: 18),
    ]
    public static let tideFeatures: [Feature] = [.init(kind: .tideLevel, memoryHours: 0), .init(kind: .tideRate, memoryHours: 0)]
    public static let defaultFeatures = meteorologicalFeatures

    public var features: [Feature]
    /// Coefficients: [intercept] + one per feature.
    public var coefficients: [Double]
    /// Hourly persistence decay of the latest model error.
    public var phi: Double
    /// Hours averaged to estimate the latest model error.
    public var anchorHours: Int
    /// Empirical RMS error by lead hour (sorted by lead).
    public var leadErrors: [LeadError]
    /// Standard deviation of the meteorologically explained signal (m).
    public var signalSigma: Double
    /// Weight (0…1) given to the regression vs. naive persistence of the
    /// current residual, chosen from out-of-sample hindcasts. Semi-enclosed
    /// basins with slowly varying anomalies favour persistence.
    public var modelWeight: Double = 1
    public var diagnostics: SurgeModelDiagnostics

    public struct LeadError: Sendable, Hashable, Codable {
        public var lead: Int
        public var rms: Double
    }

    public static let referencePressure = 1013.25
    static let evaluationLeads = [1, 3, 6, 12, 24, 48, 72, 96, 120]

    // MARK: - Feature construction

    /// Feature matrix on the forcing's hourly timeline.
    static func featureRows(forcing: [MetSample], features: [Feature], tide: TideCovariates? = nil) -> (dates: [Date], rows: [[Double]]) {
        let samples = forcing.sorted { $0.date < $1.date }
        var state = [Double](repeating: .nan, count: features.count)
        var lastDate: Date?
        var rows: [[Double]] = []
        var dates: [Date] = []
        rows.reserveCapacity(samples.count)
        for s in samples {
            let (u, v) = s.components
            let speed = s.windSpeed
            let tideState = features.contains { $0.kind == .tideLevel || $0.kind == .tideRate } ? tide?(s.date) : nil
            let raw: [Double] = features.map {
                switch $0.kind {
                case .pressure: return s.pressure - referencePressure
                case .windX: return speed * u
                case .windY: return speed * v
                case .tideLevel: return tideState?.level ?? 0
                case .tideRate: return tideState?.rate ?? 0
                }
            }
            let dt = lastDate.map { s.date.timeIntervalSince($0) / 3_600 } ?? 1
            for i in features.indices {
                let tau = features[i].memoryHours
                if state[i].isNaN || tau <= 0 || dt > 6 {
                    state[i] = raw[i]
                } else {
                    state[i] += (1 - exp(-dt / tau)) * (raw[i] - state[i])
                }
            }
            lastDate = s.date
            dates.append(s.date)
            rows.append([1] + state)
        }
        return (dates, rows)
    }

    // MARK: - Fitting

    public enum FitError: Error, Equatable {
        case insufficientData(hours: Int)
    }

    /// Fit from hourly residuals (observed − astronomical) and forcing that
    /// covers at least the training period (forcing may extend into the
    /// future; only overlapping hours are used).
    public static func fit(residuals: TimeSeries, forcing: [MetSample], features: [Feature] = defaultFeatures,
                           tide: TideCovariates? = nil, warmupHours: Int = 48) throws -> SurgeModel {
        let (dates, rows) = featureRows(forcing: forcing, features: features, tide: tide)
        var X: [[Double]] = [], y: [Double] = [], t: [Date] = []
        let warmupEnd = dates.first.map { $0 + Double(warmupHours) * 3_600 } ?? .distantPast
        for (d, row) in zip(dates, rows) where d >= warmupEnd {
            guard let r = residuals.value(at: d, maxGap: 1.5 * 3_600) else { continue }
            X.append(row); y.append(r); t.append(d)
        }
        guard X.count >= 24 * 5 else { throw FitError.insufficientData(hours: X.count) }

        let lambda = chooseLambda(X: X, y: y)
        guard let beta = LinearAlgebra.ridge(X, y, lambda: lambda) else { throw FitError.insufficientData(hours: X.count) }

        let fitted = X.map { dot($0, beta) }
        let errors = zip(y, fitted).map { $0 - $1 }
        let persistence = learnPersistence(errors: errors, dates: t)

        var meteorological = [Double](repeating: 0, count: X.count)
        for (i, f) in features.enumerated() where f.kind != .tideLevel && f.kind != .tideRate {
            for r in X.indices { meteorological[r] += beta[i + 1] * X[r][i + 1] }
        }
        let sigSD = Stats.variance(meteorological).squareRoot()
        let totalVar = Stats.variance(y)
        let r2 = totalVar > 0 ? 1 - Stats.variance(errors) / totalVar : 0

        let ib = features.firstIndex { $0.kind == .pressure }.map { beta[$0 + 1] }
        let hindcast = hindcast(X: X, y: y, dates: t, lambda: lambda)

        let diag = SurgeModelDiagnostics(
            trainingHours: X.count, trainingStart: t.first, trainingEnd: t.last,
            rSquared: r2, residualRMS: Stats.rms(y), modelErrorRMS: Stats.rms(errors),
            inverseBarometerCmPerHPa: ib.map { $0 * 100 },
            dominantWindDirection: dominantSetupDirection(beta: beta, features: features),
            persistenceEFoldingHours: persistence.phi > 0 && persistence.phi < 1 ? -1 / log(persistence.phi) : (persistence.phi >= 1 ? .infinity : 0),
            ridgeLambda: lambda,
            hindcast24hRMS: hindcast?.blended24, persistence24hRMS: hindcast?.persistence24,
            regression24hRMS: hindcast?.model24, modelWeight: hindcast?.weight ?? 1,
            usesTideInteraction: features.contains { $0.kind == .tideLevel },
            calibrated: true)

        var model = SurgeModel(features: features, coefficients: beta, phi: persistence.phi, anchorHours: persistence.window,
                               leadErrors: persistence.leadErrors, signalSigma: sigSD.isFinite ? sigSD : 0, diagnostics: diag)
        model.modelWeight = hindcast?.weight ?? 1
        if let h = hindcast, h.weight < 1 {
            // Blending with persistence changes the error structure; rescale
            // the lead errors by the hindcast improvement at 24 h.
            let ratio = h.model24 > 0 ? min(1, h.blended24 / h.model24) : 1
            model.leadErrors = model.leadErrors.map { LeadError(lead: $0.lead, rms: $0.lead >= 6 ? $0.rms * ratio : $0.rms) }
        }
        return model
    }

    /// Physically based fallback when no observations are available:
    /// inverse barometer only, no calibrated wind response.
    public static func uncalibrated(meanOffset: Double = 0, sigma: Double = 0.15) -> SurgeModel {
        SurgeModel(features: [Feature(kind: .pressure, memoryHours: 3)], coefficients: [meanOffset, -0.0099], phi: 0, anchorHours: 3,
                   leadErrors: [LeadError(lead: 1, rms: sigma)], signalSigma: 0.1,
                   diagnostics: SurgeModelDiagnostics(inverseBarometerCmPerHPa: -0.99, calibrated: false))
    }

    // MARK: - Prediction

    public struct Prediction: Sendable, Hashable {
        public var date: Date
        /// Forecast residual (surge + mean-level anomaly), metres.
        public var mean: Double
        public var sigma: Double
        public var pressureComponent: Double
        public var windComponent: Double
        public var tideInteractionComponent: Double
        public var offsetComponent: Double
        public var persistenceComponent: Double
    }

    struct Evaluated {
        let date: Date
        let pressure: Double
        let wind: Double
        let tide: Double
        let offset: Double
        var total: Double { pressure + wind + tide + offset }
    }

    func evaluate(forcing: [MetSample], tide: TideCovariates?) -> [Evaluated] {
        let (dates, rows) = Self.featureRows(forcing: forcing, features: features, tide: tide)
        return zip(dates, rows).map { d, row in
            var p = 0.0, w = 0.0, h = 0.0
            for (i, f) in features.enumerated() {
                let c = coefficients[i + 1] * row[i + 1]
                switch f.kind {
                case .pressure: p += c
                case .windX, .windY: w += c
                case .tideLevel, .tideRate: h += c
                }
            }
            return Evaluated(date: d, pressure: p, wind: w, tide: h, offset: coefficients[0])
        }
    }

    /// Lead time up to which the weather forecast is taken at face value.
    public static let weatherSkillfulHours = 48.0
    /// e-folding time of weather-forecast skill after that.
    public static let weatherSkillDecayHours = 120.0

    /// How much of the forecast pressure/wind response to trust at `lead`
    /// hours: 1 for two days, then exponential decay (≈0.55 at 5 days,
    /// ≈0.28 at 8, ≈0.07 at 15).
    public static func weatherSkill(atLead lead: Double) -> Double {
        exp(-max(0, lead - weatherSkillfulHours) / weatherSkillDecayHours)
    }

    /// Empirical RMS error at `lead` hours (linear interpolation, flat beyond).
    public func errorSigma(atLead lead: Double) -> Double {
        guard let first = leadErrors.first else { return 0.1 }
        if lead <= Double(first.lead) { return first.rms }
        for (a, b) in zip(leadErrors, leadErrors.dropFirst()) where lead <= Double(b.lead) {
            let w = (lead - Double(a.lead)) / Double(b.lead - a.lead)
            return a.rms + w * (b.rms - a.rms)
        }
        return leadErrors.last!.rms
    }

    /// Forecast from `issueTime`, anchoring persistence on the latest observed residuals.
    ///
    /// - Parameter forcingSaturationHours: forcing-forecast error is assumed
    ///   to grow linearly to the size of the meteorological signal itself.
    ///
    /// Weather forecasts lose skill with lead time, so past
    /// `weatherSkillfulHours` the pressure and wind response is shrunk by
    /// `weatherSkill(atLead:)` and the part no longer trusted is carried as
    /// extra uncertainty instead: a big wind event forecast 9 days out widens
    /// the band rather than moving the mean by its full size.
    public func forecast(forcing: [MetSample], recentResiduals: TimeSeries, issueTime: Date, horizonHours: Int,
                         tide: TideCovariates? = nil, forcingSaturationHours: Double = 120,
                         sigmaInflation: Double = 1) -> [Prediction] {
        let met = evaluate(forcing: forcing, tide: tide)
        var recent: [(Date, Double)] = []
        for m in met where m.date <= issueTime && m.date > issueTime - Double(anchorHours) * 3_600 {
            if let r = recentResiduals.value(at: m.date, maxGap: 1.5 * 3_600) { recent.append((m.date, r - m.total)) }
        }
        let e0 = recent.isEmpty ? 0 : Stats.mean(recent.map(\.1))
        let anchor = recent.last?.0 ?? issueTime
        // Naive persistence: the current observed residual held constant.
        let recentResidual: Double? = recent.isEmpty ? nil : Stats.mean(recent.compactMap { r in
            recentResiduals.value(at: r.0, maxGap: 1.5 * 3_600)
        })
        let w = recentResidual == nil ? 1 : modelWeight
        let end = issueTime + Double(horizonHours) * 3_600

        return met.compactMap { m in
            guard m.date > issueTime, m.date <= end else { return nil }
            let k = max(m.date.timeIntervalSince(anchor) / 3_600, 0)
            let persistence = w * e0 * pow(phi, k) + (1 - w) * ((recentResidual ?? 0) - m.total)
            let modelSigma = recent.isEmpty ? (leadErrors.last?.rms ?? 0.15) : errorSigma(atLead: k)
            let leadHours = m.date.timeIntervalSince(issueTime) / 3_600
            let leadFrac = min(leadHours / forcingSaturationHours, 1)
            let skill = Self.weatherSkill(atLead: leadHours)
            let weather = m.pressure + m.wind
            let distrusted = (1 - skill) * abs(weather)
            let forcingSigma = signalSigma * leadFrac
            let sigma = (modelSigma * modelSigma + forcingSigma * forcingSigma + distrusted * distrusted).squareRoot() * sigmaInflation
            let mean = m.offset + m.tide + skill * weather + persistence
            return Prediction(date: m.date, mean: mean, sigma: max(sigma, 0.02),
                              pressureComponent: skill * m.pressure, windComponent: skill * m.wind, tideInteractionComponent: m.tide,
                              offsetComponent: m.offset, persistenceComponent: persistence)
        }
    }

    // MARK: - Persistence learning

    struct Persistence {
        var phi: Double
        var window: Int
        var leadErrors: [LeadError]
    }

    static let phiGrid: [Double] = [0, 0.7, 0.85, 0.9, 0.94, 0.97, 0.98, 0.99, 0.995, 0.998, 1.0]
    static let windowGrid = [1, 3, 6, 13, 25]

    /// Choose (φ, window) minimising mean squared error at 6–48 h leads.
    static func learnPersistence(errors: [Double], dates: [Date], step: Int = 3) -> Persistence {
        let n = errors.count
        let hourIndex = dates.map { Int(($0.timeIntervalSince1970 / 3_600).rounded()) }
        var byHour: [Int: Double] = [:]
        for (h, e) in zip(hourIndex, errors) { byHour[h] = e }
        let scoringLeads = [6, 12, 24, 48]

        func score(phi: Double, window: Int, leads: [Int]) -> [Int: (sse: Double, n: Int)] {
            var acc: [Int: (sse: Double, n: Int)] = [:]
            var i = 25
            while i < n {
                let h0 = hourIndex[i]
                let anchorVals = (0..<window).compactMap { byHour[h0 - $0] }
                if anchorVals.count >= max(1, window / 2) {
                    let e0 = Stats.mean(anchorVals)
                    for L in leads {
                        guard let target = byHour[h0 + L] else { continue }
                        let err = target - e0 * pow(phi, Double(L))
                        var a = acc[L] ?? (0, 0)
                        a.sse += err * err
                        a.n += 1
                        acc[L] = a
                    }
                }
                i += step
            }
            return acc
        }

        var best = (phi: 0.9, window: 3, mse: Double.infinity)
        for phi in phiGrid {
            for w in windowGrid {
                let s = score(phi: phi, window: w, leads: scoringLeads)
                let mses = scoringLeads.compactMap { s[$0].flatMap { $0.n > 0 ? $0.sse / Double($0.n) : nil } }
                guard mses.count == scoringLeads.count else { continue }
                let m = Stats.mean(mses)
                if m < best.mse { best = (phi, w, m) }
            }
        }
        let s = score(phi: best.phi, window: best.window, leads: evaluationLeads)
        var lead = evaluationLeads.compactMap { L -> LeadError? in
            guard let a = s[L], a.n >= 5 else { return nil }
            return LeadError(lead: L, rms: (a.sse / Double(a.n)).squareRoot())
        }
        // Errors at long leads are noisy with only ~30 days; enforce monotone growth.
        for i in lead.indices.dropFirst() where lead[i].rms < lead[i - 1].rms { lead[i].rms = lead[i - 1].rms }
        if lead.isEmpty { lead = [LeadError(lead: 1, rms: Stats.rms(errors))] }
        return Persistence(phi: best.phi, window: best.window, leadErrors: lead)
    }

    // MARK: - Helpers

    static func dot(_ a: [Double], _ b: [Double]) -> Double { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }

    /// Blocked k-fold CV over a small λ grid.
    static func chooseLambda(X: [[Double]], y: [Double], folds: Int = 4) -> Double {
        let grid = [0.001, 0.01, 0.05, 0.2, 1.0]
        let n = X.count
        var best = (lambda: grid[1], mse: Double.infinity)
        for lambda in grid {
            var sse = 0.0, count = 0
            for f in 0..<folds {
                let lo = f * n / folds, hi = (f + 1) * n / folds
                var Xt: [[Double]] = [], yt: [Double] = []
                // Leave a 24 h buffer either side of the test block (autocorrelation).
                for i in 0..<n where i < lo - 24 || i >= hi + 24 { Xt.append(X[i]); yt.append(y[i]) }
                guard Xt.count > 48, let beta = LinearAlgebra.ridge(Xt, yt, lambda: lambda) else { continue }
                for i in lo..<hi {
                    let e = y[i] - dot(X[i], beta)
                    sse += e * e
                    count += 1
                }
            }
            let mse = count > 0 ? sse / Double(count) : .infinity
            if mse < best.mse { best = (lambda, mse) }
        }
        return best.lambda
    }

    struct Hindcast {
        var model24: Double
        var persistence24: Double
        var blended24: Double
        var weight: Double
    }

    /// Out-of-sample skill: fit regression + persistence on the first 70 %,
    /// then issue forecasts every 3 h over the last 30 % using analysed
    /// forcing (an optimistic bound). Baseline is naive persistence of the
    /// current residual. Also picks the model/persistence blend weight that
    /// minimises pooled 12–48 h error.
    static func hindcast(X: [[Double]], y: [Double], dates: [Date], lambda: Double) -> Hindcast? {
        let leads = [12, 24, 48]
        let split = X.count * 7 / 10
        guard split > 96, X.count - split > 60,
              let beta = LinearAlgebra.ridge(Array(X[..<split]), Array(y[..<split]), lambda: lambda) else { return nil }
        let errors = X.indices.map { y[$0] - dot(X[$0], beta) }
        let p = learnPersistence(errors: Array(errors[..<split]), dates: Array(dates[..<split]))
        let hourIndex = dates.map { Int(($0.timeIntervalSince1970 / 3_600).rounded()) }
        var idx: [Int: Int] = [:]
        for (i, h) in hourIndex.enumerated() { idx[h] = i }
        var me: [Int: [Double]] = [:], pe: [Int: [Double]] = [:]
        var i = split
        while i < X.count {
            let h0 = hourIndex[i]
            let anchorIdx = (0..<p.window).compactMap { idx[h0 - $0] }
            if !anchorIdx.isEmpty {
                let e0 = Stats.mean(anchorIdx.map { errors[$0] })
                let r0 = Stats.mean(anchorIdx.map { y[$0] })
                for L in leads {
                    guard let j = idx[h0 + L] else { continue }
                    me[L, default: []].append(y[j] - (dot(X[j], beta) + e0 * pow(p.phi, Double(L))))
                    pe[L, default: []].append(y[j] - r0)
                }
            }
            i += 3
        }
        guard let m24 = me[24], m24.count >= 6, let p24 = pe[24] else { return nil }
        // Blend weight: minimise pooled squared error of w·model + (1−w)·persistence.
        var best = (w: 1.0, sse: Double.infinity)
        for w in stride(from: 0.0, through: 1.0, by: 0.1) {
            var sse = 0.0
            for L in leads {
                for (a, b) in zip(me[L] ?? [], pe[L] ?? []) { let e = w * a + (1 - w) * b; sse += e * e }
            }
            if sse < best.sse - 1e-12 { best = (w, sse) }
        }
        let blended = zip(m24, p24).map { best.w * $0 + (1 - best.w) * $1 }
        return Hindcast(model24: Stats.rms(m24), persistence24: Stats.rms(p24), blended24: Stats.rms(blended), weight: best.w)
    }

    /// Direction (degrees true, "from") of a sustained wind that produces the
    /// largest positive slow set-up.
    static func dominantSetupDirection(beta: [Double], features: [Feature]) -> Double? {
        var bx = 0.0, by = 0.0
        for (i, f) in features.enumerated() {
            if f.kind == .windX { bx += beta[i + 1] }
            if f.kind == .windY { by += beta[i + 1] }
        }
        guard bx != 0 || by != 0 else { return nil }
        // Set-up ∝ bx·u + by·v is maximised for wind blowing *towards* (bx, by).
        return Angle.normalize(atan2(bx, by).degrees + 180)
    }
}

public struct SurgeModelDiagnostics: Sendable, Hashable, Codable {
    public var trainingHours: Int = 0
    public var trainingStart: Date?
    public var trainingEnd: Date?
    public var rSquared: Double?
    /// RMS of the observed non-tidal residual (m).
    public var residualRMS: Double?
    /// RMS of the in-sample regression error (m).
    public var modelErrorRMS: Double?
    /// Fitted inverse-barometer response (theory ≈ −0.99 cm/hPa).
    public var inverseBarometerCmPerHPa: Double?
    /// Wind direction ("from", degrees true) that most raises water.
    public var dominantWindDirection: Double?
    public var persistenceEFoldingHours: Double = 0
    public var ridgeLambda: Double = 0
    /// Out-of-sample 24 h RMS error of the final (blended) forecast (m).
    public var hindcast24hRMS: Double?
    /// 24 h RMS error of naive persistence over the same period (m).
    public var persistence24hRMS: Double?
    /// 24 h RMS error of the regression + learned persistence alone (m).
    public var regression24hRMS: Double?
    /// Weight given to the regression vs. naive persistence.
    public var modelWeight: Double = 1
    public var usesTideInteraction: Bool = false
    public var calibrated: Bool

    /// 1 − (model / persistence) squared-error ratio.
    public var skillVsPersistence: Double? {
        guard let m = hindcast24hRMS, let p = persistence24hRMS, p > 0 else { return nil }
        return 1 - (m * m) / (p * p)
    }
}
