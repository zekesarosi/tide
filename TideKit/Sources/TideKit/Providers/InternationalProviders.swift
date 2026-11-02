import Foundation

// MARK: - Fisheries and Oceans Canada (CHS) — Integrated Water Level System

/// DFO IWLS API: https://api-iwls.dfo-mpo.gc.ca/swagger-ui/index.html
///
/// No key. Heights are relative to chart datum. Time-series codes:
/// `wlo` observed, `wlp` predicted, `wlf` forecast (incl. surge, where CHS
/// runs one), `wlp-hilo` high/low predictions.
public struct DFOIWLSClient: Sendable {
    public let api: APIClient
    public static let base = "https://api-iwls.dfo-mpo.gc.ca/api/v1"

    public init(api: APIClient) { self.api = api }

    public func stations() async throws -> [Station] {
        let ep = try Endpoint.build(.dfoIWLS, "\(Self.base)/stations", cacheTTL: 7 * 86_400)
        return try DFODecoding.stations(from: await api.data(for: ep))
    }

    public enum SeriesCode: String, Sendable { case observed = "wlo", predicted = "wlp", forecast = "wlf" }

    /// `stationID` is the IWLS internal id (the `Station.code` we store).
    public func series(_ code: SeriesCode, stationID: String, from: Date, to: Date) async throws -> TimeSeries {
        // 1-minute data is capped at 7 days per request and is ~1 MB/week;
        // 15-minute resolution serves a month in one small response.
        let f = ISO8601DateFormatter()
        var points: [TimeSeriesPoint] = []
        var start = from
        while start < to {
            let end = min(start + 31 * 86_400, to)
            let ep = try Endpoint.build(.dfoIWLS, "\(Self.base)/stations/\(stationID)/data", [
                "time-series-code": code.rawValue, "from": f.string(from: start), "to": f.string(from: end),
                "resolution": "FIFTEEN_MINUTES",
            ], cacheTTL: code == .predicted ? 86_400 : 600)
            do {
                points += try DFODecoding.series(from: await api.data(for: ep)).points
            } catch APIError.http(_, let status, _) where status == 404 {
                return TimeSeries(points: points) // series not offered at this station
            }
            start = end
        }
        return TimeSeries(points: points)
    }
}

public enum DFODecoding {
    struct StationDTO: Decodable {
        struct TS: Decodable { let code: String }
        let id: String
        let code: String
        let officialName: String
        let latitude: Double
        let longitude: Double
        let provinceCode: String?
        let operating: Bool?
        let timeSeries: [TS]?
    }

    public static func stations(from data: Data) throws -> [Station] {
        let dto: [StationDTO]
        do { dto = try JSONDecoder().decode([StationDTO].self, from: data) } catch {
            throw APIError.decoding(source: .dfoIWLS, message: APIClient.describe(error))
        }
        return dto.filter { $0.operating ?? true }.map { s in
            let codes = Set((s.timeSeries ?? []).map(\.code))
            var caps: StationCapabilities = []
            if codes.contains("wlo") { caps.insert(.observations) }
            if codes.contains("wlp") { caps.insert(.predictions) }
            if codes.contains("wlf") || codes.contains("wlf-spine") { caps.insert(.officialForecast) }
            return Station(source: .dfoIWLS, code: s.id, name: s.officialName, region: s.provinceCode,
                           latitude: s.latitude, longitude: s.longitude, timeZoneIdentifier: nil,
                           isTidal: true, capabilities: caps)
        }
    }

    struct PointDTO: Decodable { let eventDate: String; let value: Double? }

    public static func series(from data: Data) throws -> TimeSeries {
        let dto: [PointDTO]
        do { dto = try JSONDecoder().decode([PointDTO].self, from: data) } catch {
            throw APIError.decoding(source: .dfoIWLS, message: APIClient.describe(error))
        }
        return TimeSeries(points: dto.compactMap { p in
            guard let v = p.value, let d = ISODates.parse(p.eventDate) else { return nil }
            return TimeSeriesPoint(date: d, value: v)
        })
    }
}

// MARK: - UK Hydrographic Office — Admiralty UK Tidal API

/// https://admiraltyapi.portal.azure-api.net — Discovery tier gives 7 days of
/// high/low water events for ~600 UK stations.
///
/// Auth: `Ocp-Apim-Subscription-Key` header with the user's/operator's key,
/// stored in the Keychain. Requests fail fast with `missingCredential` when
/// no key is configured rather than calling the API anonymously.
public struct AdmiraltyClient: Sendable {
    public let api: APIClient
    public static let base = "https://admiraltyapi.azure-api.net/uktidalapi/api/V1"

    public init(api: APIClient) { self.api = api }

    private func endpoint(_ path: String, _ query: [String: String?] = [:], ttl: TimeInterval) throws -> Endpoint {
        var ep = try Endpoint.build(.ukAdmiralty, Self.base + path, query, cacheTTL: ttl)
        ep.credential = .ukAdmiraltySubscriptionKey
        ep.credentialRequired = true
        return ep
    }

    public func stations() async throws -> [Station] {
        try AdmiraltyDecoding.stations(from: await api.data(for: endpoint("/Stations", ttl: 7 * 86_400)))
    }

    public func tidalEvents(stationID: String, days: Int = 7) async throws -> [TideExtreme] {
        let ep = try endpoint("/Stations/\(stationID)/TidalEvents", ["duration": String(min(max(days, 1), 7))], ttl: 3_600)
        return try AdmiraltyDecoding.events(from: await api.data(for: ep))
    }
}

public enum AdmiraltyDecoding {
    struct StationsDTO: Decodable {
        struct F: Decodable {
            struct G: Decodable { let coordinates: [Double] }
            struct P: Decodable { let Id: String; let Name: String; let Country: String? }
            let geometry: G
            let properties: P
        }
        let features: [F]
    }

    public static func stations(from data: Data) throws -> [Station] {
        let dto: StationsDTO
        do { dto = try JSONDecoder().decode(StationsDTO.self, from: data) } catch {
            throw APIError.decoding(source: .ukAdmiralty, message: APIClient.describe(error))
        }
        return dto.features.compactMap { f in
            guard f.geometry.coordinates.count >= 2 else { return nil }
            return Station(source: .ukAdmiralty, code: f.properties.Id, name: f.properties.Name, region: f.properties.Country,
                           latitude: f.geometry.coordinates[1], longitude: f.geometry.coordinates[0],
                           timeZoneIdentifier: "Europe/London", isTidal: true, capabilities: [.predictions])
        }
    }

    struct EventDTO: Decodable {
        let EventType: String
        let DateTime: String
        let Height: Double?
    }

    public static func events(from data: Data) throws -> [TideExtreme] {
        let dto: [EventDTO]
        do { dto = try JSONDecoder().decode([EventDTO].self, from: data) } catch {
            throw APIError.decoding(source: .ukAdmiralty, message: APIClient.describe(error))
        }
        // DateTime is UTC without a zone designator, e.g. "2026-11-02T04:31:00".
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return dto.compactMap { e in
            guard let h = e.Height else { return nil }
            let trimmed = String(e.DateTime.prefix(19))
            f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            guard let d = f.date(from: trimmed) ?? ISODates.parse(e.DateTime) else { return nil }
            return TideExtreme(date: d, height: h, kind: e.EventType.lowercased().hasPrefix("high") ? .high : .low)
        }
    }
}
