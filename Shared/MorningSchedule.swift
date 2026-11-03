import Foundation
import TideKit
import UserNotifications

/// Builds the morning summary notifications. Shared by the app (which
/// schedules a week ahead) and the widget extension (which rewrites the next
/// one or two from each fresh forecast it downloads, so summaries are rarely
/// more than an hour old while the widget is on the home screen).
enum MorningSchedule {
    static let requestPrefix = "morning-"
    static let daysAhead = 7

    /// The next `count` times the summary is due, in the device's time zone.
    static func fireDates(minutes: Int, now: Date, count: Int, calendar: Calendar = .current) -> [Date] {
        var out: [Date] = []
        var day = calendar.startOfDay(for: now)
        while out.count < count {
            if let t = calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day), t > now {
                out.append(t)
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return out
    }

    /// One request per upcoming morning whose station day the forecast fully
    /// covers, keyed by date so re-adding one replaces it.
    static func requests(forecast f: WaterLevelForecast, station: Station, minutes: Int, unit: LengthUnit,
                         now: Date) -> [UNNotificationRequest] {
        var stationCalendar = Calendar(identifier: .gregorian)
        stationCalendar.timeZone = station.timeZone
        let device = Calendar.current
        return fireDates(minutes: minutes, now: now, count: daysAhead).compactMap { fire in
            // The station's calendar day that the summary goes out on.
            guard let day = stationCalendar.dateInterval(of: .day, for: fire), day.end <= f.horizon,
                  let briefing = DailyBriefing.make(forecast: f, day: day) else { return nil }
            let content = UNMutableNotificationContent()
            content.title = "\(station.name) · \(fire.formatted(Date.FormatStyle(timeZone: station.timeZone).weekday(.wide)))"
            content.body = MorningText.body(briefing, unit: unit, tz: station.timeZone)
            content.sound = .default
            content.threadIdentifier = "morning"
            content.userInfo = ["stationID": station.id]
            let comps = device.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let id = requestPrefix + fire.formatted(.iso8601.year().month().day())
            return UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        }
    }

    /// From the widget: rewrite the upcoming summaries this forecast covers,
    /// if summaries are on, this is their station, and notifications are
    /// allowed. Later days scheduled by the app are left alone.
    static func refresh(from f: WaterLevelForecast, station: Station, settings: SharedSettings) async {
        guard settings.morningEnabled, settings.morningStation == station.id else { return }
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .authorized else { return }
        for r in requests(forecast: f, station: station, minutes: settings.morningMinutes, unit: settings.unit, now: Date()) {
            try? await center.add(r)
        }
    }
}

/// Notification wording.
enum MorningText {
    /// "High 7:43 AM (6.1 ft) and 8:12 PM (5.4 ft). Low 1:55 PM (0.2 ft).
    ///  0.4 ft above the tide table at high tide: wind +0.3 ft, air pressure +0.1 ft."
    static func body(_ b: DailyBriefing, unit: LengthUnit, tz: TimeZone) -> String {
        func list(_ events: [ForecastEvent]) -> String {
            let parts = events.map { "\(Fmt.time($0.date, in: tz)) (\(Fmt.length($0.total, unit)))" }
            switch parts.count {
            case 0: return ""
            case 1: return parts[0]
            default: return parts.dropLast().joined(separator: ", ") + " and " + parts.last!
            }
        }
        var lines: [String] = []
        var tides: [String] = []
        if !b.highs.isEmpty { tides.append("High \(list(b.highs)).") }
        if !b.lows.isEmpty { tides.append("Low \(list(b.lows)).") }
        lines.append(tides.joined(separator: " "))
        if let surge = b.surge, !b.drivers.isEmpty {
            let drivers = b.drivers.map { "\(label($0.kind)) \(Fmt.length($0.value, unit, signed: true))" }
            lines.append("\(Fmt.length(abs(surge), unit)) \(surge >= 0 ? "above" : "below") the tide table at high tide: \(drivers.joined(separator: ", ")).")
        }
        if b.isOutlook {
            lines.append("Long-range outlook: tide table plus typical surge.")
        }
        return lines.joined(separator: "\n")
    }

    static func label(_ kind: DailyBriefing.Driver.Kind) -> String {
        switch kind {
        case .background: return "background sea level"
        case .trend: return "recent trend"
        case .tideInteraction: return "tide–surge interaction"
        case .wind: return "wind"
        case .pressure: return "air pressure"
        case .officialAdjustment: return "NWS adjustment"
        }
    }
}
