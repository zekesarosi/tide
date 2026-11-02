import Foundation

/// NOAA CO-OPS Data API and Metadata API.
///
/// * Data:     https://api.tidesandcurrents.noaa.gov/api/prod/
/// * Metadata: https://api.tidesandcurrents.noaa.gov/mdapi/prod/
///
/// No key is required. Every request carries `application=<app name>` as
/// NOAA requests. 6-minute water level requests are limited to 31 days, so
/// longer ranges are split.
public struct NOAACoopsClient: Sendable {
    public let api: APIClient
    public static let dataBase = "https://api.tidesandcurrents.noaa.gov/api/prod/datagetter"
    public static let metaBase = "https://api.tidesandcurrents.noaa.gov/mdapi/prod/webapi"

    public init(api: APIClient) { self.api = api }

    // MARK: Metadata

    /// All stations with real-time water level sensors (~300 tidal + Great Lakes).
    public func waterLevelStations() async throws -> [Station] {
        let ep = try Endpoint.build(.noaaCoops, "\(Self.metaBase)/stations.json", ["type": "waterlevels"], cacheTTL: 7 * 86_400)
        return try NOAACoopsDecoding.stations(from: await api.data(for: ep))
    }

    public func harmonicConstituents(station: String) async throws -> [HarmonicConstituent] {
        let ep = try Endpoint.build(.noaaCoops, "\(Self.metaBase)/stations/\(station)/harcon.json", ["units": "metric"], cacheTTL: 30 * 86_400)
        return try NOAACoopsDecoding.harmonicConstituents(from: await api.data(for: ep))
    }

    public func datums(station: String) async throws -> DatumSet {
        let ep = try Endpoint.build(.noaaCoops, "\(Self.metaBase)/stations/\(station)/datums.json", ["units": "metric"], cacheTTL: 30 * 86_400)
        return try NOAACoopsDecoding.datums(from: await api.data(for: ep))
    }

    /// Flood thresholds relative to station datum (STND).
    public func floodThresholds(station: String) async throws -> FloodThresholds? {
        let ep = try Endpoint.build(.noaaCoops, "\(Self.metaBase)/stations/\(station)/floodlevels.json", ["units": "metric"], cacheTTL: 7 * 86_400)
        return try NOAACoopsDecoding.floodThresholds(from: await api.data(for: ep))
    }

    // MARK: Data

    /// Observed (preliminary + verified) 6-minute water levels.
    public func observedWaterLevels(station: String, from: Date, to: Date, datum: TidalDatum) async throws -> TimeSeries {
        let chunk: TimeInterval = 30 * 86_400
        var points: [TimeSeriesPoint] = []
        var start = from
        while start < to {
            let end = min(start + chunk, to)
            let ep = try dataEndpoint(product: "water_level", station: station, from: start, to: end, datum: datum, extra: [:], ttl: 300)
            do {
                points += try NOAACoopsDecoding.waterLevels(from: await api.data(for: ep)).points
            } catch APIError.provider(_, let message) where message.localizedCaseInsensitiveContains("no data") {
                // Gaps (sensor outages) are reported as errors; tolerate them per chunk.
            }
            start = end
        }
        return TimeSeries(points: points)
    }

    /// NOAA's official astronomical predictions (used to cross-check the
    /// local engine and for subordinate stations without harmonics).
    public func predictions(station: String, from: Date, to: Date, datum: TidalDatum, intervalMinutes: Int = 6) async throws -> TimeSeries {
        let ep = try dataEndpoint(product: "predictions", station: station, from: from, to: to, datum: datum,
                                  extra: ["interval": String(intervalMinutes)], ttl: 86_400)
        return try NOAACoopsDecoding.predictions(from: await api.data(for: ep))
    }

    public func highLowPredictions(station: String, from: Date, to: Date, datum: TidalDatum) async throws -> [TideExtreme] {
        let ep = try dataEndpoint(product: "predictions", station: station, from: from, to: to, datum: datum,
                                  extra: ["interval": "hilo"], ttl: 86_400)
        return try NOAACoopsDecoding.extremes(from: await api.data(for: ep))
    }

    func dataEndpoint(product: String, station: String, from: Date, to: Date, datum: TidalDatum,
                      extra: [String: String], ttl: TimeInterval) throws -> Endpoint {
        guard let d = datum.coopsQueryValue else {
            throw APIError.misconfigured("Datum \(datum.rawValue) is not supported by NOAA CO-OPS")
        }
        var q: [String: String?] = [
            "product": product, "station": station,
            "begin_date": NOAACoopsDecoding.queryDate(from), "end_date": NOAACoopsDecoding.queryDate(to),
            "datum": d, "units": "metric", "time_zone": "gmt", "format": "json",
            "application": api.identity.coopsApplication,
        ]
        for (k, v) in extra { q[k] = v }
        return try Endpoint.build(.noaaCoops, Self.dataBase, q, cacheTTL: ttl)
    }
}

/// Pure decoding functions (unit-testable without the network).
public enum NOAACoopsDecoding {
    static let responseFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    static let queryFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd HH:mm"
        return f
    }()

    public static func queryDate(_ d: Date) -> String { queryFormatter.string(from: d) }

    struct ErrorEnvelope: Decodable {
        struct E: Decodable { let message: String }
        let error: E
    }

    static func checkError(_ data: Data) throws {
        if let e = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) {
            throw APIError.provider(source: .noaaCoops, message: e.error.message.trimmingCharacters(in: .whitespaces))
        }
    }

    static func decode<T: Decodable>(_ t: T.Type, _ data: Data) throws -> T {
        try checkError(data)
        do { return try JSONDecoder().decode(T.self, from: data) } catch {
            throw APIError.decoding(source: .noaaCoops, message: APIClient.describe(error))
        }
    }

    // MARK: Stations

    struct StationsDTO: Decodable {
        struct S: Decodable {
            let id: String
            let name: String
            let state: String?
            let lat: Double
            let lng: Double
            let tidal: Bool?
            let greatlakes: Bool?
            let shefcode: String?
            let timezone: String?
            let timezonecorr: Int?
            let observedst: Bool?
            let forecast: Bool?
        }
        let stations: [S]
    }

    public static func stations(from data: Data) throws -> [Station] {
        try decode(StationsDTO.self, data).stations.map { s in
            var caps: StationCapabilities = [.observations, .predictions]
            let tidal = s.tidal ?? true
            if tidal { caps.insert(.harmonics) }
            if s.shefcode?.isEmpty == false { caps.insert(.officialForecast) }
            return Station(source: .noaaCoops, code: s.id, name: s.name, region: s.state, latitude: s.lat, longitude: s.lng,
                           timeZoneIdentifier: timeZoneIdentifier(abbreviation: s.timezone, offsetHours: s.timezonecorr, observesDST: s.observedst ?? false),
                           nwsLID: (s.shefcode?.isEmpty == false) ? s.shefcode : nil,
                           isTidal: tidal, capabilities: caps)
        }
    }

    /// Map NOAA's zone abbreviations to IANA identifiers so DST is handled.
    static func timeZoneIdentifier(abbreviation: String?, offsetHours: Int?, observesDST: Bool) -> String? {
        let map: [String: String] = [
            "EST": "America/New_York", "CST": "America/Chicago", "MST": "America/Denver",
            "PST": "America/Los_Angeles", "AKST": "America/Anchorage", "HAST": "Pacific/Honolulu",
            "HST": "Pacific/Honolulu", "AST": "America/Puerto_Rico", "SST": "Pacific/Pago_Pago",
            "ChST": "Pacific/Guam", "CHST": "Pacific/Guam",
        ]
        if let a = abbreviation, let id = map[a] {
            if a == "MST" && !observesDST { return "America/Phoenix" }
            return id
        }
        if let h = offsetHours { return TimeZone(secondsFromGMT: h * 3_600)?.identifier }
        return nil
    }

    // MARK: Harmonics / datums / flood levels

    struct HarconDTO: Decodable {
        struct C: Decodable {
            let name: String
            let amplitude: Double
            let phase_GMT: Double
            let speed: Double
        }
        let units: String?
        let HarmonicConstituents: [C]
    }

    public static func harmonicConstituents(from data: Data) throws -> [HarmonicConstituent] {
        let dto = try decode(HarconDTO.self, data)
        let scale = (dto.units?.lowercased().hasPrefix("f") == true) ? LengthUnit.metersPerFoot : 1
        return dto.HarmonicConstituents.map {
            HarmonicConstituent(name: $0.name, amplitude: $0.amplitude * scale, phaseGMT: $0.phase_GMT, speed: $0.speed)
        }
    }

    struct DatumsDTO: Decodable {
        struct D: Decodable { let name: String; let value: Double? }
        let datums: [D]?
        let LAT: Double?
    }

    public static func datums(from data: Data) throws -> DatumSet {
        let dto = try decode(DatumsDTO.self, data)
        var values: [TidalDatum: Double] = [:]
        for d in dto.datums ?? [] {
            guard let v = d.value else { continue }
            let name = d.name == "NAVD" ? "NAVD88" : d.name
            if let datum = TidalDatum(rawValue: name) { values[datum] = v }
        }
        if let lat = dto.LAT { values[.lat] = lat }
        return DatumSet(values: values)
    }

    struct FloodDTO: Decodable {
        let nos_minor: Double?
        let nos_moderate: Double?
        let nos_major: Double?
        let nws_minor: Double?
        let nws_moderate: Double?
        let nws_major: Double?
        let action: Double?
    }

    /// Prefers NWS thresholds (used in NWS warnings); falls back to NOS.
    public static func floodThresholds(from data: Data) throws -> FloodThresholds? {
        let f = try decode(FloodDTO.self, data)
        if f.nws_minor != nil || f.nws_moderate != nil || f.nws_major != nil {
            return FloodThresholds(datum: .stnd, action: f.action, minor: f.nws_minor, moderate: f.nws_moderate, major: f.nws_major, authority: "NWS")
        }
        if f.nos_minor != nil || f.nos_moderate != nil || f.nos_major != nil {
            return FloodThresholds(datum: .stnd, action: f.action, minor: f.nos_minor, moderate: f.nos_moderate, major: f.nos_major, authority: "NOS")
        }
        return nil
    }

    // MARK: Time series

    struct SeriesDTO: Decodable {
        struct P: Decodable { let t: String; let v: String; let type: String? }
        let data: [P]?
        let predictions: [P]?
    }

    static func series(_ data: Data) throws -> [SeriesDTO.P] {
        let dto = try decode(SeriesDTO.self, data)
        return dto.data ?? dto.predictions ?? []
    }

    public static func waterLevels(from data: Data) throws -> TimeSeries {
        TimeSeries(points: try series(data).compactMap { p in
            guard let d = responseFormatter.date(from: p.t), let v = Double(p.v) else { return nil }
            return TimeSeriesPoint(date: d, value: v)
        })
    }

    public static func predictions(from data: Data) throws -> TimeSeries { try waterLevels(from: data) }

    public static func extremes(from data: Data) throws -> [TideExtreme] {
        try series(data).compactMap { p in
            guard let d = responseFormatter.date(from: p.t), let v = Double(p.v), let t = p.type else { return nil }
            return TideExtreme(date: d, height: v, kind: t.hasPrefix("H") ? .high : .low)
        }
    }
}
