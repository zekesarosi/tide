import Foundation

/// Arms of San Francisco Bay, in the order the tide reaches them.
public enum BayRegion: String, Sendable, Codable, CaseIterable, Hashable {
    case coast, central, south, north

    public var title: String {
        switch self {
        case .coast: return "Open coast"
        case .central: return "Golden Gate & Central Bay"
        case .south: return "South Bay"
        case .north: return "San Pablo Bay & Carquinez"
        }
    }
}

/// A NOAA CO-OPS station in the curated San Francisco Bay set. Every one has
/// published harmonic constants; `hasObservations` marks the gauges that
/// report live water levels.
public struct BayStation: Sendable, Codable, Hashable, Identifiable {
    public var id: String { code }
    public let code: String
    public let name: String
    /// Short label for maps and tables.
    public let shortName: String
    public let latitude: Double
    public let longitude: Double
    public let region: BayRegion
    public let hasObservations: Bool

    public init(code: String, name: String, shortName: String, latitude: Double, longitude: Double,
                region: BayRegion, hasObservations: Bool) {
        self.code = code
        self.name = name
        self.shortName = shortName
        self.latitude = latitude
        self.longitude = longitude
        self.region = region
        self.hasObservations = hasObservations
    }

    /// The station as the rest of the app knows it.
    public var station: Station {
        var caps: StationCapabilities = [.harmonics, .predictions]
        if hasObservations { caps.insert(.observations) }
        return Station(source: .noaaCoops, code: code, name: name, region: "CA", latitude: latitude, longitude: longitude,
                       timeZoneIdentifier: SFBay.timeZoneIdentifier, isTidal: true, capabilities: caps)
    }
}

/// The curated San Francisco Bay network, from the open coast through the
/// Golden Gate, south to Coyote Creek and north-east through San Pablo Bay
/// and Carquinez Strait to Suisun Bay. IDs and harmonic constants were
/// checked against the CO-OPS metadata API (`harcon.json`, `datums.json`).
public enum SFBay {
    /// San Francisco (Golden Gate), the bay's reference gauge: a microwave
    /// radar sensor at the Presidio, in continuous operation since 1854.
    public static let referenceCode = "9414290"
    /// Default station to compare with the reference.
    public static let defaultComparisonCode = "9414806"
    public static let timeZoneIdentifier = "America/Los_Angeles"
    public static var timeZone: TimeZone { TimeZone(identifier: timeZoneIdentifier)! }

    /// Ordered along the tide's path: coast, Gate and Central Bay, then the
    /// South Bay arm, then the North Bay arm.
    public static let stations: [BayStation] = [
        .init(code: "9415020", name: "Point Reyes", shortName: "Point Reyes",
              latitude: 37.9942, longitude: -122.9736, region: .coast, hasObservations: true),
        .init(code: "9414290", name: "San Francisco (Golden Gate)", shortName: "San Francisco",
              latitude: 37.8063, longitude: -122.4659, region: .central, hasObservations: true),
        .init(code: "9414806", name: "Sausalito", shortName: "Sausalito",
              latitude: 37.8467, longitude: -122.4770, region: .central, hasObservations: false),
        .init(code: "9414863", name: "Richmond", shortName: "Richmond",
              latitude: 37.9283, longitude: -122.4000, region: .central, hasObservations: true),
        .init(code: "9414816", name: "Berkeley", shortName: "Berkeley",
              latitude: 37.8650, longitude: -122.3070, region: .central, hasObservations: false),
        .init(code: "9414750", name: "Alameda", shortName: "Alameda",
              latitude: 37.7720, longitude: -122.3003, region: .central, hasObservations: true),
        .init(code: "9414358", name: "Hunters Point", shortName: "Hunters Pt",
              latitude: 37.7300, longitude: -122.3570, region: .south, hasObservations: false),
        .init(code: "9414688", name: "San Leandro Marina", shortName: "San Leandro",
              latitude: 37.6950, longitude: -122.1920, region: .south, hasObservations: false),
        .init(code: "9414392", name: "Oyster Point Marina", shortName: "Oyster Pt",
              latitude: 37.6650, longitude: -122.3770, region: .south, hasObservations: false),
        .init(code: "9414458", name: "San Mateo Bridge", shortName: "San Mateo Br",
              latitude: 37.5800, longitude: -122.2530, region: .south, hasObservations: false),
        .init(code: "9414523", name: "Redwood City", shortName: "Redwood City",
              latitude: 37.5068, longitude: -122.2119, region: .south, hasObservations: true),
        .init(code: "9414509", name: "Dumbarton Bridge", shortName: "Dumbarton",
              latitude: 37.5067, longitude: -122.1150, region: .south, hasObservations: false),
        .init(code: "9414575", name: "Coyote Creek (Alviso Slough)", shortName: "Coyote Creek",
              latitude: 37.4650, longitude: -122.0230, region: .south, hasObservations: false),
        .init(code: "9415056", name: "Pinole Point", shortName: "Pinole Pt",
              latitude: 38.0150, longitude: -122.3630, region: .north, hasObservations: false),
        .init(code: "9415143", name: "Crockett", shortName: "Crockett",
              latitude: 38.0583, longitude: -122.2230, region: .north, hasObservations: false),
        .init(code: "9415102", name: "Martinez-Amorco Pier", shortName: "Martinez",
              latitude: 38.0346, longitude: -122.1252, region: .north, hasObservations: true),
        .init(code: "9415144", name: "Port Chicago", shortName: "Port Chicago",
              latitude: 38.0560, longitude: -122.0395, region: .north, hasObservations: true),
    ]

    public static func station(code: String) -> BayStation? { stations.first { $0.code == code } }

    public static var reference: BayStation { station(code: referenceCode)! }

    /// Whether an app station is one of the bay stations.
    public static func contains(_ station: Station) -> Bool {
        station.source == .noaaCoops && self.station(code: station.code) != nil
    }
}
