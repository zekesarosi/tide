import Foundation

enum ISODates {
    static func parse(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        // Open-Meteo style "2026-11-02T03:00" (GMT, no seconds/zone)
        let g = DateFormatter()
        g.locale = Locale(identifier: "en_US_POSIX")
        g.timeZone = TimeZone(identifier: "UTC")
        g.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return g.date(from: s)
    }
}

/// NWS public API (api.weather.gov): watches, warnings, advisories.
///
/// Auth: no key, but the NWS terms require a `User-Agent` that identifies the
/// application and a contact. `APIClient` always sends
/// `AppIdentity.userAgent`; configure the contact in Info.plist (`TideContact`).
public struct NWSAlertsClient: Sendable {
    public let api: APIClient
    public init(api: APIClient) { self.api = api }

    public func activeAlerts(latitude: Double, longitude: Double) async throws -> [WeatherAlert] {
        let point = String(format: "%.4f,%.4f", latitude, longitude)
        var ep = try Endpoint.build(.nwsAlerts, "https://api.weather.gov/alerts/active", ["point": point], cacheTTL: 300)
        ep.headers["Accept"] = "application/geo+json"
        return try NWSDecoding.alerts(from: await api.data(for: ep))
    }
}

public enum NWSDecoding {
    struct AlertsDTO: Decodable {
        struct Feature: Decodable { let properties: Props }
        struct Props: Decodable {
            let id: String
            let event: String
            let headline: String?
            let description: String?
            let instruction: String?
            let severity: String?
            let urgency: String?
            let onset: String?
            let effective: String?
            let ends: String?
            let expires: String?
            let senderName: String?
        }
        let features: [Feature]
    }

    public static func alerts(from data: Data) throws -> [WeatherAlert] {
        let dto: AlertsDTO
        do { dto = try JSONDecoder().decode(AlertsDTO.self, from: data) } catch {
            throw APIError.decoding(source: .nwsAlerts, message: APIClient.describe(error))
        }
        return dto.features.map(\.properties).map { p in
            WeatherAlert(id: p.id, event: p.event, headline: p.headline, description: p.description,
                         instruction: p.instruction, severity: p.severity ?? "Unknown", urgency: p.urgency ?? "Unknown",
                         onset: ISODates.parse(p.onset ?? p.effective), ends: ISODates.parse(p.ends ?? p.expires),
                         senderName: p.senderName)
        }
    }
}

/// Official NWS coastal water level forecast for a gauge, from the National
/// Water Prediction Service. Values are total water level (tide + surge) in
/// the gauge's own datum, which NWPS does not state in machine-readable
/// form — `TotalWaterLevelForecaster` aligns it to the CO-OPS datum using
/// the overlap with observations.
public struct OfficialForecast: Sendable, Hashable {
    public var source: DataSourceID
    public var issued: Date?
    public var observed: TimeSeries
    public var forecast: TimeSeries
    /// Free-text datum hint from the provider (e.g. "IN MLLW").
    public var datumHint: String?
}

public struct NWPSClient: Sendable {
    public let api: APIClient
    public init(api: APIClient) { self.api = api }

    public static let base = "https://api.water.noaa.gov/nwps/v1/gauges"

    public func gaugeName(lid: String) async throws -> String? {
        let ep = try Endpoint.build(.nwps, "\(Self.base)/\(lid)", cacheTTL: 86_400)
        struct G: Decodable { let name: String? }
        return try await api.decode(G.self, from: ep).name
    }

    public func forecast(lid: String) async throws -> OfficialForecast? {
        let ep = try Endpoint.build(.nwps, "\(Self.base)/\(lid)/stageflow", cacheTTL: 900)
        let data: Data
        do { data = try await api.data(for: ep) } catch APIError.http(_, let status, _) where status == 404 {
            return nil
        }
        let name = try? await gaugeName(lid: lid)
        return try NWPSDecoding.forecast(from: data, gaugeName: name)
    }
}

public enum NWPSDecoding {
    struct DTO: Decodable {
        struct Block: Decodable {
            struct P: Decodable { let validTime: String; let primary: Double? }
            let issuedTime: String?
            let primaryName: String?
            let primaryUnits: String?
            let data: [P]?
        }
        let observed: Block?
        let forecast: Block?
    }

    public static func forecast(from data: Data, gaugeName: String?) throws -> OfficialForecast? {
        let dto: DTO
        do { dto = try JSONDecoder().decode(DTO.self, from: data) } catch {
            throw APIError.decoding(source: .nwps, message: APIClient.describe(error))
        }
        func series(_ b: DTO.Block?) -> TimeSeries {
            guard let b, let pts = b.data else { return .empty }
            // Stage forecasts only make sense as water level; skip flow-only gauges.
            let unit = (b.primaryUnits ?? "ft").lowercased()
            let scale = unit.hasPrefix("ft") ? LengthUnit.metersPerFoot : unit == "m" ? 1 : Double.nan
            guard scale.isFinite else { return .empty }
            return TimeSeries(points: pts.compactMap { p in
                guard let v = p.primary, v > -900, let d = ISODates.parse(p.validTime) else { return nil }
                return TimeSeriesPoint(date: d, value: v * scale)
            })
        }
        let fc = series(dto.forecast)
        guard !fc.isEmpty else { return nil }
        var hint: String?
        if let name = gaugeName, let open = name.lastIndex(of: "("), let close = name.lastIndex(of: ")"), open < close {
            hint = String(name[name.index(after: open)..<close])
        }
        return OfficialForecast(source: .nwps, issued: ISODates.parse(dto.forecast?.issuedTime),
                                observed: series(dto.observed), forecast: fc, datumHint: hint)
    }
}

/// Active tropical cyclones from the National Hurricane Center.
public struct NHCClient: Sendable {
    public let api: APIClient
    public init(api: APIClient) { self.api = api }

    public func activeStorms() async throws -> [TropicalCyclone] {
        let ep = try Endpoint.build(.nhc, "https://www.nhc.noaa.gov/CurrentStorms.json", cacheTTL: 900)
        return try NHCDecoding.storms(from: await api.data(for: ep))
    }
}

public enum NHCDecoding {
    struct DTO: Decodable {
        struct Link: Decodable { let url: String? }
        struct S: Decodable {
            let id: String
            let name: String
            let classification: String?
            let intensity: String?
            let pressure: String?
            let latitudeNumeric: Double?
            let longitudeNumeric: Double?
            let lastUpdate: String?
            let publicAdvisory: Link?
        }
        let activeStorms: [S]
    }

    public static func storms(from data: Data) throws -> [TropicalCyclone] {
        let dto: DTO
        do { dto = try JSONDecoder().decode(DTO.self, from: data) } catch {
            throw APIError.decoding(source: .nhc, message: APIClient.describe(error))
        }
        return dto.activeStorms.map { s in
            TropicalCyclone(id: s.id, name: s.name, classification: s.classification ?? "",
                            intensityKnots: s.intensity.flatMap(Double.init), pressureMb: s.pressure.flatMap(Double.init),
                            latitude: s.latitudeNumeric, longitude: s.longitudeNumeric,
                            lastUpdate: ISODates.parse(s.lastUpdate),
                            advisoryURL: s.publicAdvisory?.url.flatMap(URL.init(string:)))
        }
    }
}
