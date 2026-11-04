import Foundation

/// The one rule for "the water level at time t", shared by every surface
/// (app screens, favorites cards, widgets), so they agree whenever they
/// show the same moment from the same forecast.
///
/// A forecast is computed once and then evaluated at whatever time a view
/// needs: nothing here depends on when the forecast was fetched beyond the
/// data it carries.
public enum Nowcast {
    /// e-folding time for the gap between the latest measurement and the
    /// forecast to close.
    public static let observationAnchorHours = 1.0

    /// An observation at most this old counts as a live reading.
    public static let liveObservationAge: TimeInterval = 3 * 3_600

    /// Best estimate of the water level at `date`. Near the latest
    /// observation it is anchored to it, so a surface shows what the gauge
    /// measured, easing onto the forecast over the next hour or so rather
    /// than jumping. Otherwise the forecast, or `fallback` (the tide table
    /// plus the current anomaly).
    public static func level(at date: Date, forecast: (Date) -> Double?, latest: TimeSeriesPoint?,
                             fallback: (Date) -> Double?) -> Double? {
        let f = forecast(date)
        if let o = latest {
            let lag = date.timeIntervalSince(o.date)
            if lag > -1_800 {
                guard let f else { return lag < 1_800 ? o.value : nil }
                if let atObservation = forecast(o.date) {
                    let weight = exp(-max(lag, 0) / 3_600 / observationAnchorHours)
                    return f + (o.value - atObservation) * weight
                }
            }
        }
        return f ?? fallback(date)
    }
}

/// Anything that can say what the water does at a given time.
public protocol WaterLevelTimeline {
    func level(at date: Date) -> Double?
}

extension WaterLevelTimeline {
    /// Rising or falling over the 20 minutes around `date`.
    public func isRising(at date: Date) -> Bool? {
        guard let a = level(at: date - 600), let b = level(at: date + 600) else { return nil }
        return b > a
    }
}

extension WaterLevelForecast: WaterLevelTimeline {
    public func level(at date: Date) -> Double? {
        Nowcast.level(at: date,
                      forecast: { total.value(at: $0, maxGap: 3_600) },
                      latest: latestObservation,
                      fallback: { t in astronomical.value(at: t).map { $0 + (currentResidual?.value ?? 0) } })
    }

    /// Whether `date` is close enough to a gauge reading to call the level observed.
    public func isObserved(at date: Date) -> Bool {
        guard let o = latestObservation else { return false }
        return date.timeIntervalSince(o.date) < Nowcast.liveObservationAge
    }

    public func nextEvents(after date: Date, limit: Int = 2) -> [ForecastEvent] {
        Array(events.lazy.filter { $0.date > date }.prefix(limit))
    }

    /// The hourly surge point in effect at `date`.
    public func surgePoint(at date: Date) -> SurgeForecastPoint? {
        surge.last { $0.date <= date } ?? surge.first
    }
}
