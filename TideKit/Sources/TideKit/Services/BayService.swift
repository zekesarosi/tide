import Foundation

/// One bay station, analysed against the reference gauge.
public struct BayStationAnalysis: Sendable, Identifiable {
    public var id: String { station.code }
    public let station: BayStation
    /// Astronomical tide, heights above `datum`.
    public let predictor: HarmonicPredictor
    /// MLLW when the station publishes it, otherwise MSL.
    public let datum: TidalDatum
    /// Predicted highs and lows over the analysis window.
    public let extremes: [TideExtreme]
    /// Relative to the reference, from on-device predictions. Zero lags for
    /// the reference itself.
    public var offsets: TidalOffsets?
    /// Whole-curve lag of the tide table over the observation window.
    public var predictedCurveLag: LagEstimate?
    /// Whole-curve lag of the observed water levels over the same window.
    public var observedCurveLag: LagEstimate?
    /// High and low lags between matched observed extremes.
    public var observedHigh: LagStatistics?
    public var observedLow: LagStatistics?
    /// Recent observed water levels (6-minute, same datum), empty if none.
    public let observed: TimeSeries
}

/// Everything the Bay view shows: each station's tide and its timing
/// relative to San Francisco.
public struct BayAnalysis: Sendable {
    public let generated: Date
    /// Period the predicted offsets average over.
    public let window: DateInterval
    /// Period of the observed comparison.
    public let observationWindow: DateInterval
    public let referenceCode: String
    /// In `SFBay.stations` order; stations that failed to load are absent.
    public let stations: [BayStationAnalysis]
    /// One entry per failed fetch (missing stations, missing observations).
    public let problems: [SourceStatus]

    public var reference: BayStationAnalysis? { stations.first { $0.station.code == referenceCode } }
    public func station(code: String) -> BayStationAnalysis? { stations.first { $0.station.code == code } }
}

/// Fetches harmonic constants, datums and recent observations for the bay
/// stations in parallel, tolerating individual failures (only the reference
/// is required), and computes tidal offsets relative to the reference.
public final class BayService: Sendable {
    public let coops: NOAACoopsClient
    public let stations: [BayStation]
    public let referenceCode: String

    public init(coops: NOAACoopsClient, stations: [BayStation] = SFBay.stations, referenceCode: String = SFBay.referenceCode) {
        self.coops = coops
        self.stations = stations
        self.referenceCode = referenceCode
    }

    /// Two lunar months: averages over two spring–neap cycles and the
    /// diurnal inequality's swing with the Moon's declination.
    public static let defaultPredictionDays = 59.0
    public static let defaultObservationDays = 14.0

    struct Loaded: Sendable {
        let station: BayStation
        let predictor: HarmonicPredictor?
        let datum: TidalDatum
        let extremes: [TideExtreme]
        let observed: TimeSeries
        let problems: [SourceStatus]
    }

    public func analyze(now: Date = Date(), predictionDays: Double = BayService.defaultPredictionDays,
                        observationDays: Double = BayService.defaultObservationDays) async throws -> BayAnalysis {
        let half = predictionDays * 86_400 / 2
        let window = DateInterval(start: now - half, end: now + half)
        let obsWindow = DateInterval(start: now - observationDays * 86_400, end: now)

        let loaded = await withTaskGroup(of: Loaded.self) { group in
            for s in stations {
                group.addTask { await self.load(s, window: window, observations: obsWindow) }
            }
            var out: [String: Loaded] = [:]
            for await l in group { out[l.station.code] = l }
            return out
        }
        try Task.checkCancellation()

        var problems = stations.flatMap { loaded[$0.code]?.problems ?? [] }
        guard let ref = loaded[referenceCode], let refPredictor = ref.predictor else {
            let why = loaded[referenceCode]?.problems.first?.message ?? "no harmonic constants"
            throw APIError.provider(source: .noaaCoops, message: "San Francisco reference tide unavailable: \(why)")
        }
        // Reference extremes cover the window; station extremes extend past
        // both ends so every reference event can find its partner.
        let refExtremes = ref.extremes.filter { window.contains($0.date) }
        let refObsExtremes = OffsetAnalysis.observedExtrema(ref.observed)
        let refPredGrid = refPredictor.heights(from: obsWindow.start, to: obsWindow.end, interval: 360)

        var out: [BayStationAnalysis] = []
        for s in stations {
            guard let l = loaded[s.code], let predictor = l.predictor else { continue }
            let sameDatum = l.datum == ref.datum && l.datum != .msl
            var a = BayStationAnalysis(station: s, predictor: predictor, datum: l.datum, extremes: l.extremes,
                                       offsets: nil, predictedCurveLag: nil, observedCurveLag: nil,
                                       observedHigh: nil, observedLow: nil, observed: l.observed)
            a.offsets = OffsetAnalysis.offsets(reference: refExtremes, station: l.extremes, heightsAboveDatum: sameDatum)
            a.predictedCurveLag = OffsetAnalysis.crossCorrelationLag(
                reference: refPredGrid, station: predictor.heights(from: obsWindow.start, to: obsWindow.end, interval: 360))
            if !l.observed.isEmpty, !ref.observed.isEmpty {
                a.observedCurveLag = OffsetAnalysis.crossCorrelationLag(reference: ref.observed, station: l.observed)
                let stObs = OffsetAnalysis.observedExtrema(l.observed)
                a.observedHigh = LagStatistics(samples: OffsetAnalysis.pairs(reference: refObsExtremes, station: stObs, kind: .high).map(\.lag))
                a.observedLow = LagStatistics(samples: OffsetAnalysis.pairs(reference: refObsExtremes, station: stObs, kind: .low).map(\.lag))
            }
            out.append(a)
        }
        if ref.observed.isEmpty, stations.contains(where: \.hasObservations) {
            problems.append(SourceStatus(source: .noaaCoops, component: "San Francisco observations", ok: false,
                                         message: "Observed lags need the San Francisco gauge, which has no recent data."))
        }
        return BayAnalysis(generated: now, window: window, observationWindow: obsWindow, referenceCode: referenceCode,
                           stations: out, problems: problems)
    }

    private func load(_ s: BayStation, window: DateInterval, observations obs: DateInterval) async -> Loaded {
        let code = s.code
        async let harcon = ForecastService.capture(.noaaCoops, "\(s.shortName) harmonic constants") {
            try await self.coops.harmonicConstituents(station: code)
        }
        async let datums = ForecastService.capture(.noaaCoops, "\(s.shortName) datums") {
            try await self.coops.datums(station: code)
        }
        async let observed = s.hasObservations
            ? ForecastService.capture(.noaaCoops, "\(s.shortName) observations") {
                try await self.coops.observedWaterLevels(station: code, from: obs.start, to: obs.end, datum: .mllw)
            }
            : (nil, nil)
        let (c, cs) = await harcon, (d, ds) = await datums, (o, os) = await observed
        let problems = [cs, ds, os].compactMap { $0 }.filter { !$0.ok }
        guard let c, !c.isEmpty else {
            return Loaded(station: s, predictor: nil, datum: .msl, extremes: [], observed: .empty, problems: problems.isEmpty
                ? [SourceStatus(source: .noaaCoops, component: "\(s.shortName) harmonic constants", ok: false, message: "None published")]
                : problems)
        }
        // Heights above MLLW, like the rest of the app and NOAA's tables;
        // relative to MSL if the station has no datums.
        let msl = d?.offset(of: .msl, relativeTo: .mllw)
        let predictor = HarmonicPredictor(constituents: c, meanLevel: msl ?? 0)
        let pad: TimeInterval = 6 * 3_600
        let extremes = predictor.extrema(from: window.start - pad, to: window.end + pad)
        return Loaded(station: s, predictor: predictor, datum: msl == nil ? .msl : .mllw, extremes: extremes,
                      observed: msl == nil ? .empty : (o ?? .empty), problems: problems)
    }
}
