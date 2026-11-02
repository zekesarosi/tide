import Foundation

/// Atmospheric forcing (sea-level pressure and 10 m wind) for the surge model.
///
/// Uses the Open-Meteo forecast API, which blends national weather models
/// (NOAA GFS/HRRR over the US, ECMWF, DWD ICON, …) and also serves the
/// recent past (`past_days`) from the same models. Training the surge model
/// on the same source used for the forecast keeps the regression unbiased.
///
/// Auth: free for non-commercial use without a key. With a commercial key the
/// request goes to `customer-api.open-meteo.com` and carries `apikey` (added
/// by `APIClient` from the credential store — never hard-coded).
public struct OpenMeteoClient: Sendable {
    public let api: APIClient
    public init(api: APIClient) { self.api = api }

    public func forcing(latitude: Double, longitude: Double, pastDays: Int, forecastDays: Int) async throws -> [MetSample] {
        let hasKey = api.credentials.hasSecret(for: .openMeteoAPIKey)
        let host = hasKey ? "https://customer-api.open-meteo.com/v1/forecast" : "https://api.open-meteo.com/v1/forecast"
        var ep = try Endpoint.build(.openMeteo, host, [
            "latitude": String(format: "%.4f", latitude),
            "longitude": String(format: "%.4f", longitude),
            "hourly": "pressure_msl,wind_speed_10m,wind_direction_10m",
            "wind_speed_unit": "ms",
            "timezone": "GMT",
            "past_days": String(min(max(pastDays, 0), 92)),
            "forecast_days": String(min(max(forecastDays, 1), 16)),
            // Prefer the nearest sea grid cell: coastal stations otherwise pick
            // up land-cell winds that are too weak.
            "cell_selection": "sea",
        ], cacheTTL: 1_800)
        ep.credential = .openMeteoAPIKey
        ep.credentialRequired = false
        return try OpenMeteoDecoding.forcing(from: await api.data(for: ep))
    }
}

public enum OpenMeteoDecoding {
    struct DTO: Decodable {
        struct Hourly: Decodable {
            let time: [String]
            let pressure_msl: [Double?]
            let wind_speed_10m: [Double?]
            let wind_direction_10m: [Double?]
        }
        let hourly: Hourly
    }

    struct ErrorDTO: Decodable { let error: Bool; let reason: String }

    public static func forcing(from data: Data) throws -> [MetSample] {
        if let e = try? JSONDecoder().decode(ErrorDTO.self, from: data), e.error {
            throw APIError.provider(source: .openMeteo, message: e.reason)
        }
        let dto: DTO
        do { dto = try JSONDecoder().decode(DTO.self, from: data) } catch {
            throw APIError.decoding(source: .openMeteo, message: APIClient.describe(error))
        }
        let h = dto.hourly
        return h.time.indices.compactMap { i in
            guard i < h.pressure_msl.count, i < h.wind_speed_10m.count, i < h.wind_direction_10m.count,
                  let d = ISODates.parse(h.time[i]),
                  let p = h.pressure_msl[i], let s = h.wind_speed_10m[i], let dir = h.wind_direction_10m[i] else { return nil }
            return MetSample(date: d, pressure: p, windSpeed: s, windDirection: dir)
        }
    }
}
