import BackgroundTasks
import Foundation
import TideKit
import UserNotifications

/// The morning summary: a local notification at a chosen time with the day's
/// highs and lows at one station, and what is driving the water off the tide
/// table when that's worth saying.
///
/// iOS doesn't let an app wake at an exact time to fetch data, so the next
/// week of notifications is scheduled ahead from the latest forecast and
/// rewritten whenever the app runs: on launch and foreground, when settings
/// change, and from a background refresh requested a couple of hours before
/// the next one is due (iOS decides when that actually runs).
@MainActor
final class MorningNotifier: NSObject, UNUserNotificationCenterDelegate {
    static var taskID: String { (Bundle.main.bundleIdentifier ?? "tideforecast") + ".morning" }
    static let requestPrefix = "morning-"
    static let daysAhead = 7
    /// Rescheduling on foreground is skipped if done more recently than this.
    static let foregroundInterval: TimeInterval = 60 * 60

    private let service: ForecastService
    private let settings: AppSettings
    private let stations: StationStore
    private let router: AppRouter
    private var lastScheduled: Date?
    private var center: UNUserNotificationCenter { .current() }

    init(service: ForecastService, settings: AppSettings, stations: StationStore, router: AppRouter) {
        self.service = service
        self.settings = settings
        self.stations = stations
        self.router = router
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    // MARK: Permission

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    /// Asks once; afterwards the answer lives in iOS Settings.
    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    // MARK: Scheduling

    func rescheduleIfStale() async {
        if let last = lastScheduled, Date().timeIntervalSince(last) < Self.foregroundInterval { return }
        await reschedule()
    }

    /// Replace the pending summaries with ones built from a fresh forecast.
    /// Leaves the existing ones in place if the forecast can't be fetched.
    func reschedule() async {
        guard settings.morningEnabled, let id = settings.morningStationOrFirstFavorite, let station = station(id: id),
              await authorizationStatus() == .authorized else {
            await removePending()
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskID)
            return
        }
        guard let result = try? await service.forecast(for: station, options: settings.forecastOptions) else {
            scheduleBackgroundRefresh()
            return
        }
        let requests = Self.requests(forecast: result.forecast, station: station, minutes: settings.morningMinutes,
                                     unit: settings.unit, now: Date())
        await removePending()
        for r in requests { try? await center.add(r) }
        lastScheduled = Date()
        scheduleBackgroundRefresh()
    }

    private func removePending() async {
        let ids = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(Self.requestPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    private func station(id: String) -> Station? {
        stations.station(id: id) ?? AppGroup.stationCatalog.load()?.stations.first { $0.id == id }
    }

    /// Ask iOS for a background refresh about two hours before the next summary.
    private func scheduleBackgroundRefresh() {
        guard settings.morningEnabled, let next = Self.fireDates(minutes: settings.morningMinutes, now: Date(), count: 1).first else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.taskID)
        request.earliestBeginDate = max(next - 2 * 3_600, Date() + 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

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

    static func requests(forecast f: WaterLevelForecast, station: Station, minutes: Int, unit: LengthUnit,
                         now: Date) -> [UNNotificationRequest] {
        var stationCalendar = Calendar(identifier: .gregorian)
        stationCalendar.timeZone = station.timeZone
        let device = Calendar.current
        return fireDates(minutes: minutes, now: now, count: daysAhead).compactMap { fire in
            // The station's calendar day that the summary goes out on.
            guard let day = stationCalendar.dateInterval(of: .day, for: fire),
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

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    /// Tapping a summary opens its station.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = response.notification.request.content.userInfo["stationID"] as? String else { return }
        await MainActor.run { router.openStationID = id }
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
