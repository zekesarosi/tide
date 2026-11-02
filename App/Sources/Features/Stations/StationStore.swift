import Foundation
import Observation
import TideKit

/// Station catalogue with an on-disk cache (in the App Group, so the widget
/// station picker can list stations) so launch is instant offline.
@MainActor
@Observable
final class StationStore {
    private(set) var stations: [Station] = []
    private(set) var isLoading = false
    private(set) var sourceProblems: [SourceStatus] = []
    private(set) var lastRefresh: Date?

    private static let maxAge: TimeInterval = 7 * 86_400

    private let cache = AppGroup.stationCatalog

    init() {
        if let cached = cache.load() {
            stations = cached.stations
            lastRefresh = cached.saved
        }
    }

    func load(service: ForecastService, force: Bool = false) async {
        if !force, let last = lastRefresh, Date().timeIntervalSince(last) < Self.maxAge, !stations.isEmpty { return }
        isLoading = true
        defer { isLoading = false }
        let (fresh, statuses) = await service.allStations()
        sourceProblems = statuses.filter { !$0.ok }
        guard !fresh.isEmpty else { return }
        stations = fresh.sorted { ($0.region ?? "", $0.name) < ($1.region ?? "", $1.name) }
        lastRefresh = Date()
        try? cache.save(stations)
    }

    func station(id: String) -> Station? { stations.first { $0.id == id } }

    func search(_ text: String) -> [Station] {
        let q = text.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return stations }
        return stations.filter {
            $0.name.localizedCaseInsensitiveContains(q) || $0.code.hasPrefix(q) ||
                ($0.region?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    func nearest(latitude: Double, longitude: Double, limit: Int = 5) -> [(Station, Double)] {
        stations.map { ($0, $0.distance(toLatitude: latitude, longitude: longitude)) }
            .sorted { $0.1 < $1.1 }
            .prefix(limit)
            .map { $0 }
    }

    /// Stations grouped by state/province for the browse list.
    var grouped: [(region: String, stations: [Station])] {
        Dictionary(grouping: stations) { s -> String in
            let r = s.region ?? ""
            return r.isEmpty ? DataSourceInfo.info(s.source).agency : r
        }
        .map { (region: $0.key, stations: $0.value.sorted { $0.name < $1.name }) }
        .sorted { $0.region < $1.region }
    }
}
