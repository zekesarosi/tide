import Foundation
import Observation
import TideKit

/// User preferences, persisted in the App Group's UserDefaults so the
/// widget extension sees the same units, datum and favorites.
@MainActor
@Observable
final class AppSettings {
    private let defaults: UserDefaults

    var unit: LengthUnit { didSet { defaults.set(unit.rawValue, forKey: Keys.unit); WidgetBridge.settingsChanged() } }
    var datum: TidalDatum { didSet { defaults.set(datum.rawValue, forKey: Keys.datum); WidgetBridge.settingsChanged() } }
    var horizonHours: Int { didSet { defaults.set(horizonHours, forKey: Keys.horizon) } }
    var blendOfficialGuidance: Bool { didSet { defaults.set(blendOfficialGuidance, forKey: Keys.blend) } }
    var favoriteIDs: [String] { didSet { defaults.set(favoriteIDs, forKey: Keys.favorites); WidgetBridge.settingsChanged() } }
    /// Morning summary notification (off by default).
    var morningEnabled: Bool { didSet { defaults.set(morningEnabled, forKey: Keys.morningEnabled) } }
    /// Local time of the summary, minutes after midnight (default 7:00).
    var morningMinutes: Int { didSet { defaults.set(morningMinutes, forKey: Keys.morningMinutes) } }
    /// Station to summarize; nil means the first favorite.
    var morningStationID: String? { didSet { defaults.set(morningStationID, forKey: Keys.morningStation) } }

    /// Datums offered for NOAA stations.
    static let selectableDatums: [TidalDatum] = [.mllw, .mlw, .msl, .mhw, .mhhw, .navd88]
    static let horizons = [48, 120, 168, 720, 2_160]
    /// Three months: the tide outlook runs well past the ~16-day weather forecast.
    static let defaultHorizon = 2_160

    private typealias Keys = SharedSettingsKeys

    init(defaults: UserDefaults = AppGroup.defaults) {
        self.defaults = defaults
        let defaultUnit: LengthUnit = Locale.current.measurementSystem == .us ? .feet : .meters
        unit = defaults.string(forKey: Keys.unit).flatMap(LengthUnit.init(rawValue:)) ?? defaultUnit
        datum = defaults.string(forKey: Keys.datum).flatMap(TidalDatum.init(rawValue:)) ?? .mllw
        let h = defaults.integer(forKey: Keys.horizon)
        horizonHours = Self.horizons.contains(h) ? h : Self.defaultHorizon
        blendOfficialGuidance = defaults.object(forKey: Keys.blend) as? Bool ?? true
        favoriteIDs = defaults.stringArray(forKey: Keys.favorites) ?? []
        morningEnabled = defaults.bool(forKey: Keys.morningEnabled)
        morningMinutes = defaults.object(forKey: Keys.morningMinutes) as? Int ?? 7 * 60
        morningStationID = defaults.string(forKey: Keys.morningStation)
    }

    var forecastOptions: ForecastOptions {
        ForecastOptions(datum: datum, horizonHours: horizonHours, blendOfficialGuidance: blendOfficialGuidance)
    }

    /// The station the morning summary covers: the chosen one while it is
    /// still a favorite, else the first favorite.
    var morningStationOrFirstFavorite: String? {
        if let id = morningStationID, favoriteIDs.contains(id) { return id }
        return favoriteIDs.first
    }

    /// Everything that changes what the morning notifications say.
    var morningSignature: String {
        "\(morningEnabled)|\(morningMinutes)|\(morningStationOrFirstFavorite ?? "-")|\(unit.rawValue)|\(datum.rawValue)|\(horizonHours)|\(blendOfficialGuidance)"
    }

    func isFavorite(_ station: Station) -> Bool { favoriteIDs.contains(station.id) }

    func toggleFavorite(_ station: Station) {
        if let i = favoriteIDs.firstIndex(of: station.id) { favoriteIDs.remove(at: i) } else { favoriteIDs.append(station.id) }
    }
}
