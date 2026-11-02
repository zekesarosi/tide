import Foundation

// MARK: - Data sources

/// Every upstream agency/service the app talks to.
public enum DataSourceID: String, Sendable, Codable, CaseIterable, Hashable {
    case noaaCoops = "noaa-coops"
    case nwsAlerts = "nws-api"
    case nwps = "nws-nwps"
    case nhc = "nws-nhc"
    case openMeteo = "open-meteo"
    case dfoIWLS = "dfo-iwls"
    case ukAdmiralty = "uk-admiralty"
}

/// How a source authenticates requests.
public enum AuthRequirement: Sendable, Hashable {
    /// Public, unauthenticated.
    case none
    /// No key, but the provider requires an identifying `User-Agent` with a
    /// contact (api.weather.gov terms of service).
    case identifyingUserAgent
    /// API key passed as a header (e.g. `Ocp-Apim-Subscription-Key`).
    case apiKeyHeader(name: String, required: Bool)
    /// API key passed as a query parameter (e.g. Open-Meteo `apikey`).
    case apiKeyQuery(name: String, required: Bool)
}

public struct DataSourceInfo: Sendable, Hashable, Identifiable {
    public let id: DataSourceID
    public let name: String
    public let agency: String
    public let homepage: URL
    public let termsURL: URL
    public let attribution: String
    public let auth: AuthRequirement
    public let notes: String

    public static let all: [DataSourceInfo] = [
        .init(id: .noaaCoops, name: "Tides & Currents (CO-OPS)", agency: "NOAA National Ocean Service",
              homepage: URL(string: "https://tidesandcurrents.noaa.gov")!,
              termsURL: URL(string: "https://tidesandcurrents.noaa.gov/disclaimers.html")!,
              attribution: "Water levels, predictions, datums and harmonic constants: NOAA/NOS/CO-OPS.",
              auth: .none,
              notes: "No key. Requests carry an `application` parameter identifying the app, as NOAA requests."),
        .init(id: .nwsAlerts, name: "api.weather.gov", agency: "NOAA National Weather Service",
              homepage: URL(string: "https://www.weather.gov/documentation/services-web-api")!,
              termsURL: URL(string: "https://www.weather.gov/disclaimer")!,
              attribution: "Watches, warnings and advisories: NOAA/NWS.",
              auth: .identifyingUserAgent,
              notes: "No key, but a User-Agent identifying the app and a contact is mandatory."),
        .init(id: .nwps, name: "National Water Prediction Service", agency: "NOAA National Weather Service",
              homepage: URL(string: "https://water.noaa.gov")!,
              termsURL: URL(string: "https://www.weather.gov/disclaimer")!,
              attribution: "Official coastal water level forecasts: NOAA/NWS NWPS.",
              auth: .none,
              notes: "Official NWS total water level guidance (tide + surge) for coastal gauges."),
        .init(id: .nhc, name: "National Hurricane Center", agency: "NOAA National Weather Service",
              homepage: URL(string: "https://www.nhc.noaa.gov")!,
              termsURL: URL(string: "https://www.weather.gov/disclaimer")!,
              attribution: "Tropical cyclone information: NOAA/NWS/NHC.",
              auth: .none,
              notes: "Active storm list. Tropical surge must defer to official NHC/NWS products."),
        .init(id: .openMeteo, name: "Open-Meteo", agency: "Open-Meteo.com (ECMWF, NOAA GFS/HRRR, DWD and others)",
              homepage: URL(string: "https://open-meteo.com")!,
              termsURL: URL(string: "https://open-meteo.com/en/terms")!,
              attribution: "Weather data by Open-Meteo.com (CC BY 4.0).",
              auth: .apiKeyQuery(name: "apikey", required: false),
              notes: "Free for non-commercial use without a key. Commercial use requires a key and the customer-api host."),
        .init(id: .dfoIWLS, name: "Integrated Water Level System", agency: "Fisheries and Oceans Canada / CHS",
              homepage: URL(string: "https://www.tides.gc.ca")!,
              termsURL: URL(string: "https://www.tides.gc.ca/en/disclaimer")!,
              attribution: "Contains information licensed under the Open Government Licence – Canada (DFO/CHS).",
              auth: .none,
              notes: "No key. Rate limited; keep request ranges short."),
        .init(id: .ukAdmiralty, name: "UK Tidal API", agency: "UK Hydrographic Office (Admiralty)",
              homepage: URL(string: "https://admiraltyapi.portal.azure-api.net")!,
              termsURL: URL(string: "https://admiraltyapi.portal.azure-api.net/terms")!,
              attribution: "Tidal predictions © Crown Copyright, UK Hydrographic Office.",
              auth: .apiKeyHeader(name: "Ocp-Apim-Subscription-Key", required: true),
              notes: "Requires a subscription key from the Admiralty developer portal."),
    ]

    public static func info(_ id: DataSourceID) -> DataSourceInfo {
        all.first { $0.id == id }!
    }
}

// MARK: - Units & datums

public enum LengthUnit: String, Sendable, Codable, CaseIterable, Hashable {
    case meters, feet

    public static let metersPerFoot = 0.3048

    public func fromMeters(_ v: Double) -> Double { self == .meters ? v : v / Self.metersPerFoot }
    public func toMeters(_ v: Double) -> Double { self == .meters ? v : v * Self.metersPerFoot }
    public var symbol: String { self == .meters ? "m" : "ft" }
}

/// Vertical reference datums. Raw values match NOAA CO-OPS identifiers.
public enum TidalDatum: String, Sendable, Codable, CaseIterable, Hashable {
    case mhhw = "MHHW", mhw = "MHW", mtl = "MTL", msl = "MSL", dtl = "DTL"
    case mlw = "MLW", mllw = "MLLW", navd88 = "NAVD88", stnd = "STND"
    /// Chart datum (Canada/UK; roughly LAT).
    case chartDatum = "CD"
    case lat = "LAT"
    /// International Great Lakes Datum 1985 and Low Water Datum (Great Lakes).
    case igld = "IGLD"
    case lwd = "LWD"

    /// Value used for the NOAA data API `datum` parameter.
    public var coopsQueryValue: String? {
        switch self {
        case .navd88: return "NAVD"
        case .chartDatum, .lat, .dtl: return nil
        default: return rawValue
        }
    }

    public var displayName: String {
        switch self {
        case .mhhw: return "Mean Higher High Water"
        case .mhw: return "Mean High Water"
        case .mtl: return "Mean Tide Level"
        case .msl: return "Mean Sea Level"
        case .dtl: return "Diurnal Tide Level"
        case .mlw: return "Mean Low Water"
        case .mllw: return "Mean Lower Low Water"
        case .navd88: return "NAVD88"
        case .stnd: return "Station Datum"
        case .chartDatum: return "Chart Datum"
        case .lat: return "Lowest Astronomical Tide"
        case .igld: return "IGLD 1985"
        case .lwd: return "Low Water Datum"
        }
    }
}

/// Datum elevations for a station, all relative to a common reference
/// (station datum for NOAA).
public struct DatumSet: Sendable, Codable, Hashable {
    public var values: [TidalDatum: Double]

    public init(values: [TidalDatum: Double]) { self.values = values }

    /// Height of `datum` above `reference` (metres), e.g. MSL above MLLW.
    public func offset(of datum: TidalDatum, relativeTo reference: TidalDatum) -> Double? {
        guard let a = values[datum], let b = values[reference] else { return nil }
        return a - b
    }

    /// Convert a level expressed relative to `from` into one relative to `to`.
    public func convert(_ level: Double, from: TidalDatum, to: TidalDatum) -> Double? {
        if from == to { return level }
        return offset(of: from, relativeTo: to).map { level + $0 }
    }
}

// MARK: - Flooding

public enum FloodCategory: Int, Sendable, Codable, Comparable, CaseIterable, Hashable {
    case none = 0, action, minor, moderate, major

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .none: return "No flooding"
        case .action: return "Action stage"
        case .minor: return "Minor flooding"
        case .moderate: return "Moderate flooding"
        case .major: return "Major flooding"
        }
    }
}

/// NWS / NOS flood thresholds, expressed relative to `datum`.
public struct FloodThresholds: Sendable, Codable, Hashable {
    public var datum: TidalDatum
    public var action: Double?
    public var minor: Double?
    public var moderate: Double?
    public var major: Double?
    /// Who defined the thresholds (e.g. "NWS", "NOS").
    public var authority: String

    public init(datum: TidalDatum, action: Double? = nil, minor: Double? = nil, moderate: Double? = nil,
                major: Double? = nil, authority: String = "NWS") {
        self.datum = datum
        self.action = action
        self.minor = minor
        self.moderate = moderate
        self.major = major
        self.authority = authority
    }

    public var isEmpty: Bool { action == nil && minor == nil && moderate == nil && major == nil }

    public func threshold(for category: FloodCategory) -> Double? {
        switch category {
        case .none: return nil
        case .action: return action
        case .minor: return minor
        case .moderate: return moderate
        case .major: return major
        }
    }

    public func category(for level: Double) -> FloodCategory {
        for c in FloodCategory.allCases.reversed() where c != .none {
            if let t = threshold(for: c), level >= t { return c }
        }
        return .none
    }

    public func converted(to target: TidalDatum, using datums: DatumSet) -> FloodThresholds? {
        guard let shift = datums.offset(of: datum, relativeTo: target) else { return datum == target ? self : nil }
        func s(_ v: Double?) -> Double? { v.map { $0 + shift } }
        return FloodThresholds(datum: target, action: s(action), minor: s(minor), moderate: s(moderate),
                               major: s(major), authority: authority)
    }
}

// MARK: - Stations

public struct StationCapabilities: OptionSet, Sendable, Codable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Harmonic constants available → full local astronomical prediction.
    public static let harmonics = StationCapabilities(rawValue: 1 << 0)
    /// Real-time observed water level.
    public static let observations = StationCapabilities(rawValue: 1 << 1)
    /// Provider can supply predictions (even without harmonics).
    public static let predictions = StationCapabilities(rawValue: 1 << 2)
    /// Official external surge / total water level guidance exists.
    public static let officialForecast = StationCapabilities(rawValue: 1 << 3)
    /// Flood thresholds published.
    public static let floodThresholds = StationCapabilities(rawValue: 1 << 4)
}

public struct Station: Sendable, Codable, Hashable, Identifiable {
    public var id: String { "\(source.rawValue):\(code)" }
    public var source: DataSourceID
    /// Provider's station identifier (e.g. NOAA "8518750").
    public var code: String
    public var name: String
    public var region: String?
    public var latitude: Double
    public var longitude: Double
    public var timeZoneIdentifier: String?
    /// NWS location identifier (SHEF id), used to join NWPS forecasts.
    public var nwsLID: String?
    public var isTidal: Bool
    public var capabilities: StationCapabilities

    public init(source: DataSourceID, code: String, name: String, region: String? = nil,
                latitude: Double, longitude: Double, timeZoneIdentifier: String? = nil,
                nwsLID: String? = nil, isTidal: Bool = true, capabilities: StationCapabilities = []) {
        self.source = source
        self.code = code
        self.name = name
        self.region = region
        self.latitude = latitude
        self.longitude = longitude
        self.timeZoneIdentifier = timeZoneIdentifier
        self.nwsLID = nwsLID
        self.isTidal = isTidal
        self.capabilities = capabilities
    }

    public var timeZone: TimeZone { timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .current }

    /// Great-circle distance in metres.
    public func distance(toLatitude lat: Double, longitude lon: Double) -> Double {
        let r = 6_371_000.0
        let p1 = latitude.radians, p2 = lat.radians
        let dp = (lat - latitude).radians, dl = (lon - longitude).radians
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * atan2(a.squareRoot(), (1 - a).squareRoot())
    }
}

// MARK: - Meteorology

/// One hour of atmospheric forcing at a point.
public struct MetSample: Sendable, Codable, Hashable {
    public var date: Date
    /// Mean sea level pressure, hPa.
    public var pressure: Double
    /// 10 m wind speed, m/s.
    public var windSpeed: Double
    /// Direction the wind blows *from*, degrees true.
    public var windDirection: Double

    public init(date: Date, pressure: Double, windSpeed: Double, windDirection: Double) {
        self.date = date
        self.pressure = pressure
        self.windSpeed = windSpeed
        self.windDirection = windDirection
    }

    /// Eastward (u) and northward (v) wind components, m/s.
    public var components: (u: Double, v: Double) {
        let d = windDirection.radians
        return (-windSpeed * sin(d), -windSpeed * cos(d))
    }
}

// MARK: - Alerts & storms

public struct WeatherAlert: Sendable, Codable, Hashable, Identifiable {
    public var id: String
    public var event: String
    public var headline: String?
    public var description: String?
    public var instruction: String?
    public var severity: String
    public var urgency: String
    public var onset: Date?
    public var ends: Date?
    public var senderName: String?

    public init(id: String, event: String, headline: String? = nil, description: String? = nil,
                instruction: String? = nil, severity: String = "Unknown", urgency: String = "Unknown",
                onset: Date? = nil, ends: Date? = nil, senderName: String? = nil) {
        self.id = id
        self.event = event
        self.headline = headline
        self.description = description
        self.instruction = instruction
        self.severity = severity
        self.urgency = urgency
        self.onset = onset
        self.ends = ends
        self.senderName = senderName
    }

    /// Events relevant to coastal water levels.
    public static let coastalEvents: Set<String> = [
        "Storm Surge Warning", "Storm Surge Watch", "Coastal Flood Warning", "Coastal Flood Watch",
        "Coastal Flood Advisory", "Coastal Flood Statement", "Lakeshore Flood Warning",
        "Lakeshore Flood Watch", "Lakeshore Flood Advisory", "Lakeshore Flood Statement",
        "Hurricane Warning", "Hurricane Watch", "Tropical Storm Warning", "Tropical Storm Watch",
        "High Surf Warning", "High Surf Advisory", "Tsunami Warning", "Tsunami Watch", "Tsunami Advisory",
    ]

    public var isCoastal: Bool { Self.coastalEvents.contains(event) }
}

public struct TropicalCyclone: Sendable, Codable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// e.g. "HU", "TS", "TD", "PTC".
    public var classification: String
    public var intensityKnots: Double?
    public var pressureMb: Double?
    public var latitude: Double?
    public var longitude: Double?
    public var lastUpdate: Date?
    public var advisoryURL: URL?

    public init(id: String, name: String, classification: String, intensityKnots: Double? = nil,
                pressureMb: Double? = nil, latitude: Double? = nil, longitude: Double? = nil,
                lastUpdate: Date? = nil, advisoryURL: URL? = nil) {
        self.id = id
        self.name = name
        self.classification = classification
        self.intensityKnots = intensityKnots
        self.pressureMb = pressureMb
        self.latitude = latitude
        self.longitude = longitude
        self.lastUpdate = lastUpdate
        self.advisoryURL = advisoryURL
    }

    public func distance(toLatitude lat: Double, longitude lon: Double) -> Double? {
        guard let a = latitude, let b = longitude else { return nil }
        return Station(source: .nhc, code: "", name: "", latitude: a, longitude: b).distance(toLatitude: lat, longitude: lon)
    }
}
