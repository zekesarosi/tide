import AppIntents
import TideKit
import WidgetKit

/// A station as the widget configuration UI sees it.
struct StationEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Tide station"
    static var defaultQuery = StationQuery()

    let id: String
    let name: String
    let region: String?

    init(_ station: Station) {
        id = station.id
        name = station.name
        region = station.region
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: LocalizedStringResource(stringLiteral: name),
                              subtitle: region.map { LocalizedStringResource(stringLiteral: $0) })
    }
}

/// Lists stations from the catalog the app caches in the App Group.
struct StationQuery: EntityStringQuery {
    private func catalog() -> [Station] { AppGroup.stationCatalog.load()?.stations ?? [] }

    func entities(for identifiers: [StationEntity.ID]) async throws -> [StationEntity] {
        let all = catalog()
        return identifiers.compactMap { id in all.first { $0.id == id }.map(StationEntity.init) }
    }

    func entities(matching string: String) async throws -> [StationEntity] {
        let q = string.trimmingCharacters(in: .whitespaces)
        return catalog()
            .filter { $0.name.localizedCaseInsensitiveContains(q) || ($0.region ?? "").localizedCaseInsensitiveContains(q) || $0.code.hasPrefix(q) }
            .prefix(60)
            .map(StationEntity.init)
    }

    /// Favorites first, then US stations, so the picker opens on familiar names.
    func suggestedEntities() async throws -> [StationEntity] {
        let all = catalog()
        let favorites = SharedSettings.load().favoriteIDs.compactMap { id in all.first { $0.id == id } }
        let rest = all.filter { s in s.source == .noaaCoops && !favorites.contains { $0.id == s.id } }
        return (favorites + rest).map(StationEntity.init)
    }

    func defaultResult() async -> StationEntity? {
        let all = catalog()
        return SharedSettings.load().favoriteIDs.lazy.compactMap { id in all.first { $0.id == id } }.first.map(StationEntity.init)
    }
}

/// Widget configuration: which station to show.
struct SelectStationIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Tide station"
    static var description = IntentDescription("Choose the station this widget shows. Defaults to your first favorite.")

    @Parameter(title: "Station")
    var station: StationEntity?

    init() {}
    init(station: StationEntity?) { self.station = station }
}

/// The widget's refresh button: fetch a new forecast now.
struct RefreshTideIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh tide forecast"
    static var isDiscoverable = false

    @Parameter(title: "Station ID")
    var stationID: String

    init() {}
    init(stationID: String) { self.stationID = stationID }

    static let forceKey = "widget.forceRefresh"

    func perform() async throws -> some IntentResult {
        AppGroup.defaults.set(stationID, forKey: Self.forceKey)
        WidgetCenter.shared.reloadTimelines(ofKind: AppGroup.widgetKind)
        return .result()
    }
}
