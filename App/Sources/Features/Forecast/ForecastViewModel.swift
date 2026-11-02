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

    /// Forecasts older than this are refreshed when the view appears.
    static let staleAfter: TimeInterval = 15 * 60

    init(station: Station) { self.station = station }

    var forecast: WaterLevelForecast? { result?.forecast }

    func loadIfNeeded(service: ForecastService, options: ForecastOptions) async {
        if let r = result, lastOptions == options, Date().timeIntervalSince(r.forecast.issued) < Self.staleAfter { return }
        await load(service: service, options: options)
    }

    func load(service: ForecastService, options: ForecastOptions) async {
        if phase == .loading { return }
        phase = .loading
        do {
            let r = try await service.forecast(for: station, options: options)
            result = r
            WidgetBridge.publish(r.forecast)
            lastOptions = options
            phase = .loaded
        } catch is CancellationError {
            phase = result == nil ? .idle : .loaded
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
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

    /// Event with the greatest chance of reaching minor flooding.
    var riskiestEvent: ForecastEvent? {
        forecast?.events.filter { $0.kind == .high }.max { ($0.exceedance[.minor] ?? 0) < ($1.exceedance[.minor] ?? 0) }
    }
}
