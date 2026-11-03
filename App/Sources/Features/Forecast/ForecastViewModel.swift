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
    private(set) var lastOptions: ForecastOptions?
    /// Set when a background refresh fails while an older forecast is shown.
    private(set) var refreshError: String?

    /// Forecasts older than this are refreshed (in the background, over the
    /// cached one) when the view appears.
    static let staleAfter: TimeInterval = 2 * 60

    private let cache: ForecastCache

    /// Starts from this session's last forecast for the station, if any, so
    /// the screen draws immediately.
    init(station: Station, cache: ForecastCache? = nil) {
        self.station = station
        let cache = cache ?? .shared
        self.cache = cache
        if let r = cache.cached(station) {
            result = r
            phase = .loaded
        }
    }

    var forecast: WaterLevelForecast? { result?.forecast }

    /// Show what's cached (memory, else disk) right away, then refresh if it
    /// is stale or was built with other settings.
    func loadIfNeeded(service: ForecastService, options: ForecastOptions) async {
        if result == nil, let r = await cache.load(station), r.datum == expectedDatum(options) {
            result = r
            lastOptions = nil   // unknown options: refresh below
            if phase != .loading { phase = .loaded }
        }
        if let r = result, lastOptions == options, Date().timeIntervalSince(r.forecast.issued) < Self.staleAfter { return }
        await load(service: service, options: options)
    }

    func load(service: ForecastService, options: ForecastOptions) async {
        if phase == .loading { return }
        phase = .loading
        do {
            let r = try await service.forecast(for: station, options: options)
            result = r
            refreshError = nil
            cache.store(r, for: station)
            WidgetBridge.publish(r.forecast)
            lastOptions = options
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

    /// Rising/falling based on the forecast total over the next 30 minutes.
    var trendRising: Bool? {
        guard let f = forecast, let now = f.total.value(at: f.issued + 60, maxGap: 7_200) ?? f.astronomical.value(at: f.issued),
              let later = f.total.value(at: f.issued + 1_800, maxGap: 7_200) ?? f.astronomical.value(at: f.issued + 1_800) else { return nil }
        return later > now
    }

    var nextEvents: [ForecastEvent] { Array((forecast?.events ?? []).prefix(2)) }

    /// The highest forecast water level event over the horizon.
    var peakEvent: ForecastEvent? { forecast?.events.filter { $0.kind == .high }.max { $0.total < $1.total } }

    /// The water level to headline: a recent observation, else the forecast now.
    var reading: (value: Double, observed: Bool, date: Date)? {
        guard let f = forecast else { return nil }
        if let o = f.latestObservation, f.issued.timeIntervalSince(o.date) < 3 * 3_600 { return (o.value, true, o.date) }
        if let v = f.total.value(at: f.issued, maxGap: 7_200) ?? f.astronomical.value(at: f.issued) { return (v, false, f.issued) }
        return nil
    }

    /// Water above (+) or below (−) the tide table right now.
    var anomalyNow: Double? { forecast?.currentResidual?.value ?? forecast?.surge.first?.surge }

    /// Surge components for the hour closest to now.
    var componentsNow: SurgeForecastPoint? { forecast?.surge.first }

    /// One sentence on what is driving the anomaly.
    var driverSentence: String? {
        guard let c = componentsNow else { return nil }
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
