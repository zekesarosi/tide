import Foundation
import TideKit

/// Storage and identity shared by the app and its widget extension.
///
/// Both targets carry `TideAppGroup` and `TideKeychainGroup` in their
/// Info.plist (set from Config/App.xcconfig) and the matching entitlements.
/// If the group isn't configured in Info.plist, storage falls back to the
/// current process's own defaults and caches. (With the key set but the
/// entitlement missing, e.g. unsigned simulator builds, each process gets its
/// own private copy, so the widget shows its "choose a station" state.)
enum AppGroup {
    static let widgetKind = "TideWidget"
    static let urlScheme = "tideforecast"

    private static func plistString(_ key: String) -> String? {
        guard let v = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let t = v.trimmingCharacters(in: .whitespaces)
        return t.isEmpty || t.contains("$(") ? nil : t
    }

    static var identifier: String? { plistString("TideAppGroup") }
    static var keychainGroup: String? { plistString("TideKeychainGroup") }

    static var defaults: UserDefaults {
        identifier.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    static var containerURL: URL {
        if let id = identifier, let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) {
            return url.appendingPathComponent("Library/Caches", isDirectory: true)
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    static var snapshots: ForecastSnapshotStore {
        ForecastSnapshotStore(directory: containerURL.appendingPathComponent("Snapshots", isDirectory: true))
    }

    static var stationCatalog: StationCatalogCache {
        StationCatalogCache(url: containerURL.appendingPathComponent("stations-v1.json"))
    }

    static func credentials() -> CredentialStore {
        LayeredCredentialStore(
            primary: KeychainCredentialStore(service: "tideforecast.credentials", accessGroup: keychainGroup),
            fallbacks: [BundleCredentialStore()])
    }

    /// `tideforecast://station/<station id>`
    static func deepLink(stationID: String) -> URL {
        var c = URLComponents()
        c.scheme = urlScheme
        c.host = "station"
        c.path = "/" + stationID
        return c.url ?? URL(string: "\(urlScheme)://")!
    }

    /// `tideforecast://bay` or `tideforecast://bay/<NOAA code>` opens the
    /// San Francisco Bay screen; the result is the station code to select ("" for none).
    static func bayStationCode(from url: URL) -> String? {
        guard url.scheme == urlScheme, url.host == "bay" else { return nil }
        return String(url.path.dropFirst())
    }

    static func stationID(from url: URL) -> String? {
        guard url.scheme == urlScheme, url.host == "station" else { return nil }
        let id = String(url.path.dropFirst())
        return id.isEmpty ? nil : id
    }
}

/// Display preferences both targets read (the app writes them).
enum SharedSettingsKeys {
    static let unit = "settings.unit"
    static let datum = "settings.datum"
    static let horizon = "settings.horizonHours"
    static let blend = "settings.blendOfficial"
    static let favorites = "settings.favorites"
    static let morningEnabled = "settings.morning.enabled"
    static let morningMinutes = "settings.morning.minutes"
    static let morningStation = "settings.morning.station"
}

struct SharedSettings {
    var unit: LengthUnit
    var datum: TidalDatum
    var favoriteIDs: [String]
    var morningEnabled = false
    var morningMinutes = 7 * 60
    var morningStationID: String?

    static func load(_ d: UserDefaults = AppGroup.defaults) -> SharedSettings {
        let defaultUnit: LengthUnit = Locale.current.measurementSystem == .us ? .feet : .meters
        return SharedSettings(
            unit: d.string(forKey: SharedSettingsKeys.unit).flatMap(LengthUnit.init(rawValue:)) ?? defaultUnit,
            datum: d.string(forKey: SharedSettingsKeys.datum).flatMap(TidalDatum.init(rawValue:)) ?? .mllw,
            favoriteIDs: d.stringArray(forKey: SharedSettingsKeys.favorites) ?? [],
            morningEnabled: d.bool(forKey: SharedSettingsKeys.morningEnabled),
            morningMinutes: d.object(forKey: SharedSettingsKeys.morningMinutes) as? Int ?? 7 * 60,
            morningStationID: d.string(forKey: SharedSettingsKeys.morningStation))
    }

    /// The station the morning summary covers (same rule as the app).
    var morningStation: String? {
        if let id = morningStationID, favoriteIDs.contains(id) { return id }
        return favoriteIDs.first
    }

    /// The datum a forecast for `station` uses under these settings.
    func datum(for station: Station) -> TidalDatum {
        switch station.source {
        case .noaaCoops: return station.isTidal ? datum : .igld
        default: return .chartDatum
        }
    }
}
