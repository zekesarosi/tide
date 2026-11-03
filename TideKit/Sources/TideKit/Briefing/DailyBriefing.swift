import Foundation

/// What a morning summary says about one station day: its highs and lows, and
/// (when the water is running noticeably off the tide table) what is pushing
/// it there, at the day's highest high tide. Pure data; the app formats it.
public struct DailyBriefing: Sendable, Hashable {
    /// One contributor to the surge, in the order the station screen uses.
    public struct Driver: Sendable, Hashable {
        public enum Kind: String, Sendable, Hashable, CaseIterable {
            case background, trend, tideInteraction, wind, pressure, officialAdjustment
        }
        public var kind: Kind
        /// Metres; positive raises the water.
        public var value: Double
    }

    public var day: DateInterval
    public var highs: [ForecastEvent]
    public var lows: [ForecastEvent]
    /// The day's highest high water.
    public var peak: ForecastEvent?
    /// Water above (+) or below (−) the tide table at the peak, metres.
    public var surge: Double?
    /// Contributors at the peak, largest first; empty when the surge is
    /// below `minimumSurge` or the day is in the long-range outlook.
    public var drivers: [Driver]
    /// The day lies past the weather forecast (tide table + typical surge).
    public var isOutlook: Bool

    /// Surge below this (0.2 ft) isn't worth explaining.
    public static let minimumSurge = 0.2 * 0.3048
    /// Contributors smaller than this (0.05 ft) are left out.
    public static let minimumDriver = 0.05 * 0.3048

    /// The briefing for `day` (a station-local calendar day), or nil when
    /// the forecast has no tides that day.
    public static func make(forecast f: WaterLevelForecast, day: DateInterval) -> DailyBriefing? {
        let events = f.events.filter { day.contains($0.date) }
        guard !events.isEmpty else { return nil }
        let highs = events.filter { $0.kind == .high }
        let lows = events.filter { $0.kind == .low }
        let peak = highs.max { $0.total < $1.total }
        let isOutlook = f.weatherHorizon.map { day.start > $0 } ?? false

        var drivers: [Driver] = []
        if let peak, !isOutlook, abs(peak.surge) >= minimumSurge,
           let point = f.surge.min(by: { abs($0.date.timeIntervalSince(peak.date)) < abs($1.date.timeIntervalSince(peak.date)) }),
           abs(point.date.timeIntervalSince(peak.date)) <= 2 * 3_600 {
            drivers = Self.drivers(at: point)
        }
        return DailyBriefing(day: day, highs: highs, lows: lows, peak: peak, surge: peak?.surge,
                             drivers: drivers, isOutlook: isOutlook)
    }

    /// The surge split the way the station screen shows it, largest first.
    public static func drivers(at p: SurgeForecastPoint) -> [Driver] {
        var out: [Driver] = [
            Driver(kind: .background, value: p.offsetComponent),
            Driver(kind: .trend, value: p.persistenceComponent),
            Driver(kind: .tideInteraction, value: p.tideInteractionComponent),
            Driver(kind: .wind, value: p.windComponent),
            Driver(kind: .pressure, value: p.pressureComponent),
        ]
        if p.officialWeight > 0.05 {
            let model = out.reduce(0) { $0 + $1.value }
            out.append(Driver(kind: .officialAdjustment, value: p.surge - model))
        }
        return out.filter { abs($0.value) >= minimumDriver }.sorted { abs($0.value) > abs($1.value) }
    }
}
