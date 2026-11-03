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
        let requests = MorningSchedule.requests(forecast: result.forecast, station: station,
                                                minutes: settings.morningMinutes, unit: settings.unit, now: Date())
        await removePending()
        for r in requests { try? await center.add(r) }
        lastScheduled = Date()
        scheduleBackgroundRefresh()
    }

    private func removePending() async {
        let ids = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(MorningSchedule.requestPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    private func station(id: String) -> Station? {
        stations.station(id: id) ?? AppGroup.stationCatalog.load()?.stations.first { $0.id == id }
    }

    /// Ask iOS for a background refresh about two hours before the next summary.
    private func scheduleBackgroundRefresh() {
        guard settings.morningEnabled, let next = MorningSchedule.fireDates(minutes: settings.morningMinutes, now: Date(), count: 1).first else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.taskID)
        request.earliestBeginDate = max(next - 2 * 3_600, Date() + 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
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
