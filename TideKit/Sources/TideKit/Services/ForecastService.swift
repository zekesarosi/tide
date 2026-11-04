import Foundation

/// User-selectable forecast options.
public struct ForecastOptions: Sendable, Hashable, Codable {
    public var datum: TidalDatum
    public var horizonHours: Int
    public var blendOfficialGuidance: Bool

    public init(datum: TidalDatum = .mllw, horizonHours: Int = 2_160, blendOfficialGuidance: Bool = true) {
        self.datum = datum
        self.horizonHours = horizonHours
        self.blendOfficialGuidance = blendOfficialGuidance
    }
}

/// Status of each upstream fetch, surfaced in the UI so users can see what a
/// forecast is (and isn't) built from.
public struct SourceStatus: Sendable, Hashable, Identifiable, Codable {
    public var id: String { "\(source.rawValue):\(component)" }
    public var source: DataSourceID
    public var component: String
    public var ok: Bool
    public var message: String?
    /// Wall-clock fetch time, seconds.
    public var duration: TimeInterval = 0
}

public struct ForecastResult: Sendable, Hashable, Codable {
    public var forecast: WaterLevelForecast
    public var sources: [SourceStatus]
    /// Datum actually used (may differ from the request, e.g. Great Lakes use IGLD).
    public var datum: TidalDatum
    public var datums: DatumSet?
    /// The options it was built with (nil in results cached by older versions).
    public var options: ForecastOptions? = nil
}

/// Fetches everything a forecast needs, in parallel, tolerating failures of
/// optional sources, and runs `TotalWaterLevelForecaster`.
public final class ForecastService: Sendable {
    public let api: APIClient
    public let coops: NOAACoopsClient
    public let nws: NWSAlertsClient
    public let nwps: NWPSClient
    public let nhc: NHCClient
    public let openMeteo: OpenMeteoClient
    public let dfo: DFOIWLSClient
    public let admiralty: AdmiraltyClient
    /// Recent gauge records, so refreshes fetch only new readings (nil: fetch the whole window each time).
    public let observations: ObservationArchive?

    public init(api: APIClient, observations: ObservationArchive? = nil) {
        self.api = api
        self.observations = observations
        coops = NOAACoopsClient(api: api)
        nws = NWSAlertsClient(api: api)
        nwps = NWPSClient(api: api)
        nhc = NHCClient(api: api)
        openMeteo = OpenMeteoClient(api: api)
        dfo = DFOIWLSClient(api: api)
        admiralty = AdmiraltyClient(api: api)
    }

    // MARK: Stations

    /// All supported stations. NOAA is primary; DFO is always included; UK
    /// stations only when a subscription key is configured.
    public func allStations() async -> (stations: [Station], sources: [SourceStatus]) {
        async let noaa = Self.capture(.noaaCoops, "stations") { try await self.coops.waterLevelStations() }
        async let canada = Self.capture(.dfoIWLS, "stations") { try await self.dfo.stations().filter { $0.capabilities.contains(.predictions) } }
        let ukEnabled = api.credentials.hasSecret(for: .ukAdmiraltySubscriptionKey)
        async let uk = ukEnabled ? Self.capture(.ukAdmiralty, "stations") { try await self.admiralty.stations() } : (nil, nil)

        var stations: [Station] = []
        var sources: [SourceStatus] = []
        for (value, status) in [await noaa, await canada, await uk] {
            stations += value ?? []
            if let status { sources.append(status) }
        }
        return (stations, sources)
    }

    // MARK: Forecast

    public func forecast(for station: Station, options: ForecastOptions = .init(), now: Date = Date()) async throws -> ForecastResult {
        var result: ForecastResult
        switch station.source {
        case .noaaCoops: result = try await noaaForecast(station, options, now)
        case .dfoIWLS: result = try await dfoForecast(station, options, now)
        case .ukAdmiralty: result = try await ukForecast(station, options, now)
        default: throw APIError.misconfigured("Unsupported station source \(station.source.rawValue)")
        }
        result.options = options
        return result
    }

    private func sharedContext(_ station: Station, _ options: ForecastOptions, _ now: Date) async
        -> (forcing: [MetSample]?, alerts: [WeatherAlert]?, storms: [TropicalCyclone]?, sources: [SourceStatus]) {
        // Always the full weather-model range: the same request whatever the
        // horizon, so the app and widget share one cached copy per model run.
        // (Beyond 16 days the forecast is the outlook, which needs no weather.)
        async let forcing = Self.capture(.openMeteo, "pressure & wind") {
            try await self.openMeteo.forcing(latitude: station.latitude, longitude: station.longitude,
                                             pastDays: TotalWaterLevelForecaster.trainingDays + 3, forecastDays: 16)
        }
        // NWS alerts cover US locations only.
        let isUS = station.source == .noaaCoops
        async let alerts = isUS ? Self.capture(.nwsAlerts, "alerts") {
            try await self.nws.activeAlerts(latitude: station.latitude, longitude: station.longitude)
        } : ([], nil)
        async let storms = Self.capture(.nhc, "active storms") { try await self.nhc.activeStorms() }
        let f = await forcing, a = await alerts, s = await storms
        return (f.0, a.0, s.0, [f.1, a.1, s.1].compactMap { $0 })
    }

    private func noaaForecast(_ station: Station, _ options: ForecastOptions, _ now: Date) async throws -> ForecastResult {
        let code = station.code
        let datum: TidalDatum = station.isTidal ? options.datum : .igld
        let obsStart = now - Double(TotalWaterLevelForecaster.trainingDays + 2) * 86_400

        async let harcon = station.isTidal ? Self.capture(.noaaCoops, "harmonic constants") { try await self.coops.harmonicConstituents(station: code) } : ([], nil)
        async let datums = Self.capture(.noaaCoops, "datums") { try await self.coops.datums(station: code) }
        async let flood = Self.capture(.noaaCoops, "flood thresholds") { try await self.coops.floodThresholds(station: code) }
        async let obs = Self.capture(.noaaCoops, "observations") {
            try await self.observed(key: "\(station.id)|\(datum.rawValue)", from: obsStart, to: now) { a, b in
                try await self.coops.observedWaterLevels(station: code, from: a, to: b, datum: datum)
            }
        }
        async let official = (options.blendOfficialGuidance && station.nwsLID != nil)
            ? Self.capture(.nwps, "official forecast") { try await self.nwps.forecast(lid: station.nwsLID!) }
            : (nil, nil)
        async let ctx = sharedContext(station, options, now)

        let (constituents, harconStatus) = await harcon
        let (datumSet, datumStatus) = await datums
        let (floodLevels, floodStatus) = await flood
        let (observations, obsStatus) = await obs
        let (off, offStatus) = await official
        let context = await ctx

        var sources = [harconStatus, datumStatus, floodStatus, obsStatus, offStatus].compactMap { $0 } + context.sources

        let astronomical: AstronomicalSource
        if station.isTidal {
            guard let constituents, !constituents.isEmpty else {
                throw APIError.provider(source: .noaaCoops, message: "No harmonic constants available for \(station.name).")
            }
            guard let msl = datumSet?.offset(of: .msl, relativeTo: datum) else {
                throw APIError.provider(source: .noaaCoops, message: "Datum \(datum.rawValue) is not published for \(station.name).")
            }
            let predictor = HarmonicPredictor(constituents: constituents, meanLevel: msl)
            if !predictor.unresolvedConstituents.isEmpty {
                sources.append(SourceStatus(source: .noaaCoops, component: "harmonic constants", ok: true,
                                            message: "Ignored unrecognised constituents: \(predictor.unresolvedConstituents.joined(separator: ", "))"))
            }
            astronomical = .harmonic(predictor)
        } else {
            astronomical = .none
        }

        var thresholds: FloodThresholds?
        if let f = floodLevels ?? nil, let d = datumSet { thresholds = f.converted(to: datum, using: d) }

        let input = ForecastInputs(station: station, datum: datum, issueTime: now, horizonHours: options.horizonHours,
                                   astronomical: astronomical, observations: observations ?? .empty,
                                   forcing: context.forcing ?? [], official: off ?? nil, thresholds: thresholds,
                                   alerts: context.alerts ?? [], storms: context.storms ?? [])
        return ForecastResult(forecast: TotalWaterLevelForecaster.forecast(input), sources: sources, datum: datum, datums: datumSet)
    }

    private func dfoForecast(_ station: Station, _ options: ForecastOptions, _ now: Date) async throws -> ForecastResult {
        let id = station.code
        let horizon = now + Double(options.horizonHours + 12) * 3_600
        let start = now - Double(TotalWaterLevelForecaster.trainingDays + 2) * 86_400
        // The tide table doesn't change: request whole UTC days so the same
        // request (and its day-long cache entry) serves every refresh that day.
        let predFrom = Self.utcDay(start), predTo = Self.utcDay(horizon) + 86_400
        // The official forecast is reissued a few times a day: hour-aligned requests.
        let hourNow = (now.timeIntervalSince1970 / 3_600).rounded(.down) * 3_600
        let fcFrom = Date(timeIntervalSince1970: hourNow - 86_400), fcTo = Date(timeIntervalSince1970: (horizon.timeIntervalSince1970 / 3_600).rounded(.up) * 3_600)
        async let pred = Self.capture(.dfoIWLS, "predictions") { try await self.dfo.series(.predicted, stationID: id, from: predFrom, to: predTo) }
        async let obs = station.capabilities.contains(.observations)
            ? Self.capture(.dfoIWLS, "observations") {
                try await self.observed(key: station.id, from: start, to: now) { a, b in
                    try await self.dfo.series(.observed, stationID: id, from: a, to: b)
                }
            } : (nil, nil)
        async let fc = (options.blendOfficialGuidance && station.capabilities.contains(.officialForecast))
            ? Self.capture(.dfoIWLS, "official forecast") { try await self.dfo.series(.forecast, stationID: id, from: fcFrom, to: fcTo) } : (nil, nil)
        async let ctx = sharedContext(station, options, now)

        let (p, ps) = await pred, (o, os) = await obs, (f, fs) = await fc
        let context = await ctx
        guard let p, !p.isEmpty else {
            throw APIError.provider(source: .dfoIWLS, message: "No predictions available for \(station.name).")
        }
        var official: OfficialForecast?
        if let f, !f.isEmpty, let o {
            // Same chart datum on both sides, so alignment is ~0 but still verified.
            official = OfficialForecast(source: .dfoIWLS, issued: nil, observed: o.sliced(from: now - 3 * 86_400, to: now), forecast: f, datumHint: "CD")
        }
        let input = ForecastInputs(station: station, datum: .chartDatum, issueTime: now, horizonHours: options.horizonHours,
                                   astronomical: .series(p), observations: o ?? .empty, forcing: context.forcing ?? [],
                                   official: official, thresholds: nil, alerts: [], storms: context.storms ?? [])
        let sources = [ps, os, fs].compactMap { $0 } + context.sources
        return ForecastResult(forecast: TotalWaterLevelForecaster.forecast(input), sources: sources, datum: .chartDatum, datums: nil)
    }

    private func ukForecast(_ station: Station, _ options: ForecastOptions, _ now: Date) async throws -> ForecastResult {
        let events = try await admiralty.tidalEvents(stationID: station.code, days: 7)
        let context = await sharedContext(station, options, now)
        let curve = TimeSeries.interpolating(extremes: events)
        let input = ForecastInputs(station: station, datum: .chartDatum, issueTime: now,
                                   horizonHours: min(options.horizonHours, 24 * 6), astronomical: .series(curve),
                                   observations: .empty, forcing: context.forcing ?? [], storms: context.storms ?? [])
        let sources = [SourceStatus(source: .ukAdmiralty, component: "tidal events", ok: true, message: nil)] + context.sources
        return ForecastResult(forecast: TotalWaterLevelForecaster.forecast(input), sources: sources, datum: .chartDatum, datums: nil)
    }

    /// Observations over `from...to`, incrementally when an archive is configured.
    private func observed(key: String, from: Date, to: Date,
                          fetch: @escaping @Sendable (Date, Date) async throws -> TimeSeries) async throws -> TimeSeries {
        guard let observations else { return try await fetch(from, to) }
        return try await observations.series(key: key, from: from, to: to, fetch: fetch)
    }

    static func utcDay(_ d: Date) -> Date {
        Date(timeIntervalSince1970: (d.timeIntervalSince1970 / 86_400).rounded(.down) * 86_400)
    }

    /// Run an optional fetch, converting failure into a status entry.
    static func capture<T: Sendable>(_ source: DataSourceID, _ component: String,
                                     _ body: @Sendable () async throws -> T) async -> (T?, SourceStatus?) {
        let start = Date()
        do {
            let v = try await body()
            return (v, SourceStatus(source: source, component: component, ok: true, message: nil, duration: Date().timeIntervalSince(start)))
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return (nil, SourceStatus(source: source, component: component, ok: false, message: message, duration: Date().timeIntervalSince(start)))
        }
    }
}
