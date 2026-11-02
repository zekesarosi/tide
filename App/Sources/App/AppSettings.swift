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

    /// Datums offered for NOAA stations.
    static let selectableDatums: [TidalDatum] = [.mllw, .mlw, .msl, .mhw, .mhhw, .navd88]
    static let horizons = [48, 72, 120, 168]

    private typealias Keys = SharedSettingsKeys

    init(defaults: UserDefaults = AppGroup.defaults) {
        self.defaults = defaults
        let defaultUnit: LengthUnit = Locale.current.measurementSystem == .us ? .feet : .meters
        unit = defaults.string(forKey: Keys.unit).flatMap(LengthUnit.init(rawValue:)) ?? defaultUnit
        datum = defaults.string(forKey: Keys.datum).flatMap(TidalDatum.init(rawValue:)) ?? .mllw
        let h = defaults.integer(forKey: Keys.horizon)
        horizonHours = Self.horizons.contains(h) ? h : 120
        blendOfficialGuidance = defaults.object(forKey: Keys.blend) as? Bool ?? true
        favoriteIDs = defaults.stringArray(forKey: Keys.favorites) ?? []
    }

    var forecastOptions: ForecastOptions {
        ForecastOptions(datum: datum, horizonHours: horizonHours, blendOfficialGuidance: blendOfficialGuidance)
    }

    func isFavorite(_ station: Station) -> Bool { favoriteIDs.contains(station.id) }

    func toggleFavorite(_ station: Station) {
        if let i = favoriteIDs.firstIndex(of: station.id) { favoriteIDs.remove(at: i) } else { favoriteIDs.append(station.id) }
    }
}
