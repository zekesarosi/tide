import Foundation

/// When a forecast is worth rebuilding, for every surface (station screen,
/// favorites, widget). Between refreshes nothing is recalculated: surfaces
/// evaluate the forecast they have at the current time (`Nowcast`).
///
/// What goes stale is the inputs, not the tide: the tide table is fixed, the
/// weather model updates about hourly, and gauges report every few minutes.
/// So a forecast anchored on live readings is refreshed about as often as
/// new readings arrive (less often in the widget, which has a daily reload
/// budget), and one without them about as often as the weather changes.
public enum RefreshPolicy {
    public enum Surface: Sendable {
        /// Someone is looking at the app.
        case app
        /// Widget timelines and background work.
        case widget
    }

    /// How long a forecast stays current.
    public static func lifetime(for surface: Surface, liveObservations: Bool) -> TimeInterval {
        guard liveObservations else { return 60 * 60 }
        switch surface {
        case .app: return 6 * 60       // one gauge interval
        case .widget: return 20 * 60   // ~72 reloads a day at most
        }
    }

    public static func isCurrent(issued: Date, liveObservations: Bool, surface: Surface, now: Date = Date()) -> Bool {
        now.timeIntervalSince(issued) < lifetime(for: surface, liveObservations: liveObservations)
    }

    public static func isCurrent(_ f: WaterLevelForecast, surface: Surface, now: Date = Date()) -> Bool {
        isCurrent(issued: f.issued, liveObservations: f.latestObservation != nil, surface: surface, now: now)
    }

    public static func isCurrent(_ s: ForecastSnapshot, surface: Surface, now: Date = Date()) -> Bool {
        isCurrent(issued: s.issued, liveObservations: s.latestObservation != nil, surface: surface, now: now)
    }
}
