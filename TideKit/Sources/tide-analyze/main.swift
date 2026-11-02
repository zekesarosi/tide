import Foundation
import TideKit

// Retrospective analysis of a past window at one or more NOAA stations.
//
// Usage: tide-analyze <start ISO8601> <end ISO8601> <out.json> <station id>...
// Env:   TIDE_CONTACT
//
// For each station:
//  * local harmonic prediction vs NOAA's official prediction (sanity check)
//  * observed vs predicted high/low waters (height and timing)
//  * non-tidal residual statistics
//  * surge attribution: model trained on the 30 days *before* the window,
//    applied out-of-sample to the window (pressure / wind / tide interaction)
//  * rolling hindcasts: the app's forecaster replayed every 6 h through the
//    window with data available at that time (weather forcing is analysed,
//    so skill is an optimistic bound on real forecasts)

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 4, let start = ISO8601DateFormatter().date(from: args[0]),
      let end = ISO8601DateFormatter().date(from: args[1]) else {
    print("usage: tide-analyze <start> <end> <out.json> <station>..."); exit(1)
}
let outPath = args[2]
let stationIDs = Array(args.dropFirst(3))
let identity = AppIdentity(appName: "TideForecastAnalysis", version: "0.1",
                           contact: ProcessInfo.processInfo.environment["TIDE_CONTACT"] ?? "contact-not-configured")
let api = APIClient(identity: identity, credentials: InMemoryCredentialStore())
let coops = NOAACoopsClient(api: api)
let meteo = OpenMeteoClient(api: api)
let trainStart = start - 32 * 86_400

func rnd(_ v: Double, _ d: Double = 1000) -> Double { (v * d).rounded() / d }
func pts(_ s: TimeSeries) -> [[Double]] { s.points.map { [$0.date.timeIntervalSince1970, rnd($0.value)] } }

/// Running mean over ±k samples (suppresses seiche noise before peak picking).
func smoothed(_ s: TimeSeries, k: Int = 2) -> TimeSeries {
    let p = s.points
    return TimeSeries(points: p.indices.map { i in
        let w = p[max(0, i - k)...min(p.count - 1, i + k)]
        return TimeSeriesPoint(date: p[i].date, value: w.reduce(0) { $0 + $1.value } / Double(w.count))
    })
}

var stationsOut: [[String: Any]] = []
let allStations = try await coops.waterLevelStations()

for id in stationIDs {
    guard let station = allStations.first(where: { $0.code == id }) else { print("unknown \(id)"); continue }
    print("== \(station.name) (\(id))")
    async let harconA = coops.harmonicConstituents(station: id)
    async let datumsA = coops.datums(station: id)
    async let floodA = try? coops.floodThresholds(station: id)
    async let obsA = coops.observedWaterLevels(station: id, from: trainStart, to: end, datum: .mllw)
    async let noaaPredA = coops.predictions(station: id, from: start, to: end, datum: .mllw, intervalMinutes: 6)
    async let forcingA = meteo.forcing(latitude: station.latitude, longitude: station.longitude, pastDays: 40, forecastDays: 1)
    let (harcon, datums, flood, obs, noaaPred, forcing) = try await (harconA, datumsA, floodA, obsA, noaaPredA, forcingA)

    let msl = datums.offset(of: .msl, relativeTo: .mllw) ?? 0
    let predictor = HarmonicPredictor(constituents: harcon, meanLevel: msl)
    let thresholds = (flood ?? nil).flatMap { $0.converted(to: .mllw, using: datums) }

    // 1. Engine vs NOAA official predictions over the window.
    let diffs = noaaPred.points.map { predictor.height(at: $0.date) - $0.value }
    let engineRMS = Stats.rms(diffs)

    // 2. Observed vs predicted extremes.
    let weekObs = obs.sliced(from: start, to: end)
    let smooth = smoothed(weekObs)
    let predEx = predictor.extrema(from: start, to: end)
    var events: [[String: Any]] = []
    for e in predEx {
        let win = smooth.sliced(from: e.date - 2.5 * 3_600, to: e.date + 2.5 * 3_600)
        guard win.count > 20, let o = (e.kind == .high ? win.maximum : win.minimum) else { continue }
        events.append(["t": e.date.timeIntervalSince1970, "kind": e.kind.rawValue, "pred": rnd(e.height),
                       "obsT": o.date.timeIntervalSince1970, "obs": rnd(o.value),
                       "dtMin": rnd(o.date.timeIntervalSince(e.date) / 60, 1), "dh": rnd(o.value - e.height)])
    }

    // 3. Residuals.
    let hourlyObs = obs.hourlyMeans()
    let residual = TimeSeries(points: hourlyObs.points.map { TimeSeriesPoint(date: $0.date, value: $0.value - predictor.height(at: $0.date)) })
    let weekRes = residual.sliced(from: start, to: end)

    // 4. Out-of-sample attribution: train before the window only.
    let tide: TideCovariates = { d in
        (predictor.height(at: d), (predictor.height(at: d + 300) - predictor.height(at: d - 300)) / (600.0 / 3_600))
    }
    let trainRes = residual.sliced(from: trainStart, to: start)
    let model = try SurgeModel.fit(residuals: trainRes, forcing: forcing.filter { $0.date < start },
                                   features: SurgeModel.meteorologicalFeatures + SurgeModel.tideFeatures, tide: tide)
    let attribution = model.forecast(forcing: forcing, recentResiduals: trainRes, issueTime: start - 3_600,
                                     horizonHours: Int(end.timeIntervalSince(start) / 3_600) + 1, tide: tide)
        .filter { $0.date >= start && $0.date <= end }
    var explainedNoPersist: [Double] = [], actual: [Double] = []
    for a in attribution {
        if let r = weekRes.value(at: a.date, maxGap: 3_600) {
            actual.append(r)
            explainedNoPersist.append(a.pressureComponent + a.windComponent + a.tideInteractionComponent + a.offsetComponent)
        }
    }
    let errs = zip(actual, explainedNoPersist).map { $0 - $1 }
    let r2 = 1 - Stats.variance(errs) / Stats.variance(actual)

    // 5. Rolling hindcasts with the app's forecaster.
    var leadErr: [Int: (model: [Double], persist: [Double], table: [Double])] = [:]
    var hiErr: (model: [Double], table: [Double]) = ([], [])
    var issue = start
    var nRuns = 0
    while issue + 24 * 3_600 <= end {
        let f = TotalWaterLevelForecaster.forecast(ForecastInputs(
            station: station, datum: .mllw, issueTime: issue, horizonHours: 24, astronomical: .harmonic(predictor),
            observations: obs.sliced(from: issue - 32 * 86_400, to: issue), forcing: forcing, thresholds: thresholds))
        nRuns += 1
        let r0 = residual.value(at: issue, maxGap: 3_600) ?? 0
        for lead in [1, 3, 6, 12, 18, 24] {
            let t = issue + Double(lead) * 3_600
            guard let o = hourlyObs.value(at: t, maxGap: 3_600), let m = f.total.value(at: t, maxGap: 1_200) else { continue }
            let a = predictor.height(at: t)
            var e = leadErr[lead] ?? ([], [], [])
            e.model.append(o - m); e.persist.append(o - (a + r0)); e.table.append(o - a)
            leadErr[lead] = e
        }
        for ev in f.events where ev.kind == .high && ev.date > issue + 6 * 3_600 {
            let win = smooth.sliced(from: ev.date - 2 * 3_600, to: ev.date + 2 * 3_600)
            if let o = win.maximum { hiErr.model.append(o.value - ev.total); hiErr.table.append(o.value - ev.astronomical) }
        }
        issue += 6 * 3_600
    }

    let leadOut = leadErr.keys.sorted().map { k -> [String: Any] in
        let e = leadErr[k]!
        return ["lead": k, "model": rnd(Stats.rms(e.model)), "persistence": rnd(Stats.rms(e.persist)), "table": rnd(Stats.rms(e.table)), "n": e.model.count]
    }
    let resVals = weekRes.values
    let maxRes = weekRes.maximum, minRes = weekRes.minimum
    let obsMax = weekObs.maximum, obsMin = weekObs.minimum
    let d = model.diagnostics
    print(String(format: "  engine vs NOAA rms %.4f m | residual mean %.3f sd %.3f max %.3f min %.3f | OOS R² %.2f",
                 engineRMS, Stats.mean(resVals), Stats.variance(resVals).squareRoot(), maxRes?.value ?? .nan, minRes?.value ?? .nan, r2))
    for l in leadOut { print("  lead \(l["lead"]!)h: model \(l["model"]!) persistence \(l["persistence"]!) table \(l["table"]!)") }
    print(String(format: "  high tides (6-24h ahead): model rms %.3f bias %.3f | table rms %.3f bias %.3f (n=%d)",
                 Stats.rms(hiErr.model), Stats.mean(hiErr.model), Stats.rms(hiErr.table), Stats.mean(hiErr.table), hiErr.model.count))

    let thin = TimeSeries(points: weekObs.points.enumerated().filter { $0.offset % 2 == 0 }.map(\.element))
    var th: [String: Any] = [:]
    th["minor"] = thresholds?.minor.map { rnd($0) }
    th["moderate"] = thresholds?.moderate.map { rnd($0) }
    th["major"] = thresholds?.major.map { rnd($0) }
    th["action"] = thresholds?.action.map { rnd($0) }
    th["authority"] = thresholds?.authority
    var stats: [String: Double] = [:]
    stats["resMean"] = rnd(Stats.mean(resVals))
    stats["resSD"] = rnd(Stats.variance(resVals).squareRoot())
    stats["resMax"] = rnd(maxRes?.value ?? .nan)
    stats["resMaxT"] = maxRes?.date.timeIntervalSince1970 ?? 0
    stats["resMin"] = rnd(minRes?.value ?? .nan)
    stats["resMinT"] = minRes?.date.timeIntervalSince1970 ?? 0
    stats["obsMax"] = rnd(obsMax?.value ?? .nan)
    stats["obsMaxT"] = obsMax?.date.timeIntervalSince1970 ?? 0
    stats["obsMin"] = rnd(obsMin?.value ?? .nan)
    stats["obsMinT"] = obsMin?.date.timeIntervalSince1970 ?? 0
    stats["predMax"] = rnd(predEx.filter { $0.kind == .high }.map(\.height).max() ?? .nan)
    stats["predMin"] = rnd(predEx.filter { $0.kind == .low }.map(\.height).min() ?? .nan)
    var modelOut: [String: Double] = [:]
    modelOut["trainR2"] = rnd(d.rSquared ?? .nan)
    modelOut["ib"] = rnd(d.inverseBarometerCmPerHPa ?? .nan)
    modelOut["windFrom"] = rnd(d.dominantWindDirection ?? .nan, 1)
    modelOut["eFold"] = rnd(d.persistenceEFoldingHours, 10)
    modelOut["offset"] = rnd(model.coefficients[0])
    var hind: [String: Any] = ["runs": nRuns, "leads": leadOut, "nHigh": hiErr.model.count]
    hind["highModelRms"] = rnd(Stats.rms(hiErr.model))
    hind["highModelBias"] = rnd(Stats.mean(hiErr.model))
    hind["highTableRms"] = rnd(Stats.rms(hiErr.table))
    hind["highTableBias"] = rnd(Stats.mean(hiErr.table))
    let attr: [[Double]] = attribution.map { a in
        [a.date.timeIntervalSince1970, rnd(a.pressureComponent), rnd(a.windComponent), rnd(a.tideInteractionComponent), rnd(a.offsetComponent)]
    }
    let forc: [[Double]] = forcing.filter { $0.date >= start && $0.date <= end }.map { m in
        [m.date.timeIntervalSince1970, rnd(m.pressure, 10), rnd(m.windSpeed, 10), rnd(m.windDirection, 1)]
    }
    var st: [String: Any] = ["id": id, "name": station.name, "lat": station.latitude, "lon": station.longitude]
    st["mslAboveMllw"] = rnd(msl)
    st["navdAboveMllw"] = rnd(datums.offset(of: .navd88, relativeTo: .mllw) ?? .nan)
    st["mhhw"] = rnd(datums.offset(of: .mhhw, relativeTo: .mllw) ?? .nan)
    st["thresholds"] = th
    st["engineVsNoaaRms"] = rnd(engineRMS, 100_000)
    st["constituents"] = predictor.constituentCount
    st["astro"] = pts(predictor.heights(from: start, to: end, interval: 1_200))
    st["observed"] = pts(thin)
    st["residual"] = pts(weekRes)
    st["attribution"] = attr
    st["attributionR2"] = rnd(r2)
    st["events"] = events
    st["stats"] = stats
    st["model"] = modelOut
    st["hindcast"] = hind
    st["forcing"] = forc
    stationsOut.append(st)
}

let out: [String: Any] = ["start": start.timeIntervalSince1970, "end": end.timeIntervalSince1970,
                          "generated": Date().timeIntervalSince1970, "stations": stationsOut]
try JSONSerialization.data(withJSONObject: out).write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
