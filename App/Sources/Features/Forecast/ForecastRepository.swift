import Foundation
import TideKit

/// The app's one way to get a forecast. Every caller (station screen,
/// favorites, morning summary) asks here, so:
/// - a forecast that's still current (`RefreshPolicy`) is reused, not refetched;
/// - concurrent requests for the same station share one fetch;
/// - every fresh forecast lands in the cache and the shared store (widgets).
@MainActor
final class ForecastRepository {
    let service: ForecastService
    let cache: ForecastCache

    private struct Key: Hashable { let station: String; let options: ForecastOptions }
    private var inFlight: [Key: Task<ForecastResult, Error>] = [:]

    init(service: ForecastService, cache: ForecastCache? = nil) {
        self.service = service
        self.cache = cache ?? .shared
    }

    /// The forecast for `station` with `options`: the cached one if it's
    /// current for `surface`, otherwise a fresh one. `force` skips the cache.
    func forecast(for station: Station, options: ForecastOptions, surface: RefreshPolicy.Surface = .app,
                  force: Bool = false) async throws -> ForecastResult {
        if !force, let r = await cache.load(station), r.options == options,
           RefreshPolicy.isCurrent(r.forecast, surface: surface) {
            return r
        }
        let key = Key(station: station.id, options: options)
        if let task = inFlight[key] { return try await task.value }
        let service = service
        let task = Task { try await service.forecast(for: station, options: options) }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let r = try await task.value
        cache.store(r, for: station)
        WidgetBridge.publish(r)
        return r
    }
}
