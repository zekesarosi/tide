import Foundation
import TideKit
import WidgetKit

struct TideEntry: TimelineEntry {
    enum State {
        case ready(ForecastSnapshot)
        case needsStation
        case unavailable(stationName: String, message: String)
    }

    let date: Date
    let state: State
    let unit: LengthUnit
}

/// Builds widget timelines from the forecast snapshot the app (or a previous
/// widget refresh) saved. When the snapshot is missing, stale or in another
/// datum, it fetches a fresh 48-hour forecast with TideKit, the same
/// pipeline the app uses.
struct TideProvider: AppIntentTimelineProvider {
    /// Fetch a new forecast when the saved one is older than this.
    static let maxAge: TimeInterval = 45 * 60
    /// Entries step the "now" marker forward between refreshes.
    static let entrySpacing: TimeInterval = 15 * 60
    /// Cover up to 12 h so the widget keeps moving if reloads are throttled.
    static let entryHorizon: TimeInterval = 12 * 3_600
    /// After a failed fetch, don't try again (unless forced) for this long.
    static let failureBackoff: TimeInterval = 45 * 60
    static let lastFailureKey = "widget.lastFailure"

    func placeholder(in context: Context) -> TideEntry {
        TideEntry(date: Date(), state: .ready(.sample()), unit: SharedSettings.load().unit)
    }

    func snapshot(for configuration: SelectStationIntent, in context: Context) async -> TideEntry {
        let settings = SharedSettings.load()
        if context.isPreview {
            if let station = resolveStation(configuration), let snap = AppGroup.snapshots.load(stationID: station.id) {
                return TideEntry(date: Date(), state: .ready(snap), unit: settings.unit)
            }
            return TideEntry(date: Date(), state: .ready(.sample()), unit: settings.unit)
        }
        return await currentEntries(configuration, settings: settings).entries.first
            ?? TideEntry(date: Date(), state: .needsStation, unit: settings.unit)
    }

    func timeline(for configuration: SelectStationIntent, in context: Context) async -> Timeline<TideEntry> {
        let settings = SharedSettings.load()
        let (entries, fresh) = await currentEntries(configuration, settings: settings)
        let next = Date().addingTimeInterval(fresh ? 30 * 60 : 60 * 60)
        return Timeline(entries: entries, policy: .after(next))
    }

    // MARK: - Helpers

    private func resolveStation(_ configuration: SelectStationIntent) -> Station? {
        let all = AppGroup.stationCatalog.load()?.stations ?? []
        if let id = configuration.station?.id { return all.first { $0.id == id } }
        return SharedSettings.load().favoriteIDs.lazy.compactMap { id in all.first { $0.id == id } }.first
    }

    private func currentEntries(_ configuration: SelectStationIntent, settings: SharedSettings) async -> (entries: [TideEntry], fresh: Bool) {
        let now = Date()
        guard let station = resolveStation(configuration) else {
            return ([TideEntry(date: now, state: .needsStation, unit: settings.unit)], true)
        }
        var snap = AppGroup.snapshots.load(stationID: station.id)
        let forced = AppGroup.defaults.string(forKey: RefreshTideIntent.forceKey) == station.id
        let wantDatum = settings.datum(for: station)
        let wantsFetch = forced || snap == nil || snap!.datum != wantDatum || now.timeIntervalSince(snap!.issued) > Self.maxAge
        // Back off after a failure so a persistent error doesn't spend the
        // widget's refresh budget on a full forecast every reload.
        let lastFailure = AppGroup.defaults.object(forKey: Self.lastFailureKey) as? Date
        let backingOff = !forced && lastFailure.map { now.timeIntervalSince($0) < Self.failureBackoff } == true
        let needsFetch = wantsFetch && !backingOff
        var fresh = !wantsFetch
        var failure: String? = backingOff ? "Couldn't update the forecast recently; will retry soon." : nil
        if needsFetch {
            if forced { AppGroup.defaults.removeObject(forKey: RefreshTideIntent.forceKey) }
            do {
                let s = try await Self.fetch(station, datum: settings.datum)
                try? AppGroup.snapshots.save(s)
                snap = s
                fresh = true
                AppGroup.defaults.removeObject(forKey: Self.lastFailureKey)
            } catch {
                failure = (error as? LocalizedError)?.errorDescription ?? "Couldn't update the forecast."
                AppGroup.defaults.set(now, forKey: Self.lastFailureKey)
            }
        }
        guard let ready = snap, ready.datum == wantDatum else {
            return ([TideEntry(date: now, state: .unavailable(stationName: station.name, message: failure ?? "No forecast yet."), unit: settings.unit)], false)
        }
        let last = min(now + Self.entryHorizon, max(ready.end, now))
        let count = max(1, Int(last.timeIntervalSince(now) / Self.entrySpacing) + 1)
        let entries = (0..<count).map { i in
            TideEntry(date: now + Double(i) * Self.entrySpacing, state: .ready(ready), unit: settings.unit)
        }
        return (entries, fresh)
    }

    static func fetch(_ station: Station, datum: TidalDatum) async throws -> ForecastSnapshot {
        let service = ForecastService(api: APIClient(identity: AppIdentity.fromBundle(), credentials: AppGroup.credentials()))
        let options = ForecastOptions(datum: datum, horizonHours: 48, blendOfficialGuidance: true)
        let result = try await withTimeout(seconds: 25) {
            try await service.forecast(for: station, options: options)
        }
        return ForecastSnapshot(forecast: result.forecast)
    }
}

struct WidgetTimeout: Error {}

/// Widgets get limited run time; give up on slow networks and fall back to
/// the saved snapshot.
func withTimeout<T: Sendable>(seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw WidgetTimeout()
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw WidgetTimeout() }
        return first
    }
}
