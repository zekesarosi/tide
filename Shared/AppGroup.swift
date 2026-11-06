import Foundation
import notify
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

    /// The forecast service both processes use, on the shared caches: one
    /// download of reference data and weather serves the app and the widget,
    /// and refreshes fetch only new gauge readings.
    static func makeService(identity: AppIdentity = .fromBundle(), credentials: CredentialStore = credentials()) -> ForecastService {
        let api = APIClient(identity: identity, credentials: credentials,
                            diskCache: DiskResponseCache(directory: containerURL.appendingPathComponent("HTTP", isDirectory: true)))
        return ForecastService(api: api, observations: ObservationArchive(directory: containerURL.appendingPathComponent("Observations", isDirectory: true)))
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

    /// `tideforecast://globe` opens the Tide Globe.
    static func isGlobeURL(_ url: URL) -> Bool {
        url.scheme == urlScheme && url.host == "globe"
    }

    /// `tideforecast://bay3d` opens San Francisco Bay in 3D.
    static func isBaySceneURL(_ url: URL) -> Bool {
        url.scheme == urlScheme && url.host == "bay3d"
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
    var blendOfficialGuidance = true
    var favoriteIDs: [String]
    var morningEnabled = false
    var morningMinutes = 7 * 60
    var morningStationID: String?

    static func load(_ d: UserDefaults = AppGroup.defaults) -> SharedSettings {
        let defaultUnit: LengthUnit = Locale.current.measurementSystem == .us ? .feet : .meters
        return SharedSettings(
            unit: d.string(forKey: SharedSettingsKeys.unit).flatMap(LengthUnit.init(rawValue:)) ?? defaultUnit,
            datum: d.string(forKey: SharedSettingsKeys.datum).flatMap(TidalDatum.init(rawValue:)) ?? .mllw,
            blendOfficialGuidance: d.object(forKey: SharedSettingsKeys.blend) as? Bool ?? true,
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

    /// Options for a forecast covering `horizonHours`, under these settings.
    func forecastOptions(horizonHours: Int) -> ForecastOptions {
        ForecastOptions(datum: datum, horizonHours: horizonHours, blendOfficialGuidance: blendOfficialGuidance)
    }

    /// Whether `snapshot` was built with these settings (datum and blending),
    /// so it can be shown as is.
    func accepts(_ snapshot: ForecastSnapshot, for station: Station) -> Bool {
        snapshot.datum == datum(for: station) && snapshot.blendOfficialGuidance == blendOfficialGuidance
    }

    /// The datum a forecast for `station` uses under these settings.
    func datum(for station: Station) -> TidalDatum {
        switch station.source {
        case .noaaCoops: return station.isTidal ? datum : .igld
        default: return .chartDatum
        }
    }
}

/// The one way a forecast reaches the shared store, from the app or the
/// widget extension: newest wins, and every process is told it changed.
enum ForecastPublisher {
    /// Darwin notification posted after a snapshot is saved. Darwin
    /// notifications cross process boundaries but carry no payload.
    static var changedNotification: String { (AppGroup.identifier ?? "tideforecast") + ".snapshots-changed" }

    /// Save `snapshot` if it's the newest for its station and signal
    /// everyone. Returns whether it was saved.
    @discardableResult
    static func publish(_ snapshot: ForecastSnapshot) -> Bool {
        guard (try? AppGroup.snapshots.save(snapshot)) == true else { return false }
        notify_post(changedNotification)
        return true
    }

    /// Calls `handler` on the main queue whenever any process publishes.
    /// Keep the returned token; pass it to `stopObserving` when done.
    static func observe(_ handler: @escaping @MainActor () -> Void) -> Int32 {
        var token: Int32 = NOTIFY_TOKEN_INVALID
        notify_register_dispatch(changedNotification, &token, .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
        return token
    }

    static func stopObserving(_ token: Int32) {
        if token != NOTIFY_TOKEN_INVALID { notify_cancel(token) }
    }
}
