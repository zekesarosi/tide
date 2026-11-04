import Foundation
import Observation
import TideKit

@MainActor
@Observable
final class ForecastViewModel {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    let station: Station
    private(set) var phase: Phase = .idle
    private(set) var result: ForecastResult?
    /// Set when a background refresh fails while an older forecast is shown.
    private(set) var refreshError: String?

    private let cache: ForecastCache
    @ObservationIgnored private var subscription: ForecastSubscription?
    @ObservationIgnored private var source: (repository: ForecastRepository, options: ForecastOptions)?

    /// Starts from this session's last forecast for the station, if any, so
    /// the screen draws immediately.
    init(station: Station, cache: ForecastCache? = nil) {
        self.station = station
        // Resolved here, inside the main-actor init, not as a default argument.
        let cache = cache ?? .shared
        self.cache = cache
        if let r = cache.cached(station) {
            result = r
            phase = .loaded
        }
        subscription = ForecastSubscription { [weak self] in self?.storeChanged() }
    }

    /// Another process (the widget) published a newer forecast for this
    /// station: catch up, so this screen never shows older data than the
    /// widget. Cheap: the widget's downloads are in the shared caches.
    private func storeChanged() {
        guard let source, phase != .loading,
              let snap = AppGroup.snapshots.load(stationID: station.id),
              snap.issued > (result?.forecast.issued ?? .distantPast) + 60 else { return }
        Task { await load(source.repository, options: source.options, force: true) }
    }

    var forecast: WaterLevelForecast? { result?.forecast }

    /// While the screen is up: show what's cached right away, then keep the
    /// forecast current by `RefreshPolicy`, refetching only when it goes
    /// stale. Between refreshes the screen re-evaluates it each minute
    /// without recalculating. Ends when the calling task is cancelled.
    func keepCurrent(_ repository: ForecastRepository, options: ForecastOptions) async {
        source = (repository, options)
        if let r = await cache.load(station), r.datum == expectedDatum(options), r.options == options || result == nil {
            result = r
            if phase != .loading { phase = .loaded }
        }
        while !Task.isCancelled {
            await load(repository, options: options)
            let age = result.map { Date().timeIntervalSince($0.forecast.issued) } ?? 0
            let lifetime = RefreshPolicy.lifetime(for: .app, liveObservations: result?.forecast.latestObservation != nil)
            let wait = refreshError == nil ? max(lifetime - age, 60) : 120
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
    }

    /// Pull to refresh.
    func refresh(_ repository: ForecastRepository, options: ForecastOptions) async {
        await repository.service.api.clearCache(volatileOnly: true)
        await load(repository, options: options, force: true)
    }

    private func load(_ repository: ForecastRepository, options: ForecastOptions, force: Bool = false) async {
        if phase == .loading { return }
        let current = result.map { $0.options == options && RefreshPolicy.isCurrent($0.forecast, surface: .app) } ?? false
        if current && !force { return }
        phase = .loading
        do {
            result = try await repository.forecast(for: station, options: options, force: force)
            refreshError = nil
            phase = .loaded
        } catch is CancellationError {
            phase = result == nil ? .idle : .loaded
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if result != nil {
                // Keep showing the last forecast; say it's not current.
                refreshError = message
                phase = .loaded
            } else {
                phase = .failed(message)
            }
        }
    }

    /// The datum a forecast for this station uses under `options`.
    private func expectedDatum(_ options: ForecastOptions) -> TidalDatum {
        switch station.source {
        case .noaaCoops: return station.isTidal ? options.datum : .igld
        default: return .chartDatum
        }
    }

    // MARK: Derived values for the UI
    //
    // Evaluated at the screen's clock, not at the forecast's issue time, so
    // the reading and trend keep moving between refreshes and match the
    // favorites cards and widgets (they all go through `Nowcast`).

    func trendRising(at now: Date) -> Bool? { forecast?.isRising(at: now) }

    func nextEvents(after now: Date) -> [ForecastEvent] { forecast?.nextEvents(after: now) ?? [] }

    /// The highest forecast high water from `now` to the horizon.
    func peakEvent(after now: Date) -> ForecastEvent? {
        forecast?.events.filter { $0.kind == .high && $0.date > now }.max { $0.total < $1.total }
    }

    /// The water level to headline at `now`, and whether a recent gauge reading backs it.
    func reading(at now: Date) -> (value: Double, observed: Bool)? {
        guard let f = forecast, let v = f.level(at: now) else { return nil }
        return (v, f.isObserved(at: now))
    }

    /// Water above (+) or below (−) the tide table: the latest measured
    /// anomaly, else the forecast surge at `now`.
    func anomaly(at now: Date) -> Double? { forecast?.currentResidual?.value ?? forecast?.surgePoint(at: now)?.surge }

    /// Surge components for the hour containing `now`.
    func components(at now: Date) -> SurgeForecastPoint? { forecast?.surgePoint(at: now) }

    /// One sentence on what is driving the anomaly.
    func driverSentence(at now: Date) -> String? {
        guard let c = components(at: now) else { return nil }
        let weather = c.pressureComponent + c.windComponent
        let background = c.offsetComponent
        if abs(background) >= abs(weather) {
            if abs(background) < 0.05 { return "Water is close to the tide table; weather has little effect today." }
            let level = background > 0 ? "above" : "below"
            let pull = weather > 0.02 ? " Today's weather is adding a little more." : (weather < -0.02 ? " Today's weather is pulling it down slightly." : "")
            return "Sea level here is running \(level) normal.\(pull)"
        }
        if weather > 0 {
            return c.pressureComponent > c.windComponent
                ? "Low air pressure is raising the water."
                : "Wind is pushing water toward the coast."
        }
        return c.pressureComponent < c.windComponent
            ? "High air pressure is holding the water down."
            : "Wind is pushing water away from the coast."
    }
}
