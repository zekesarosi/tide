import XCTest
@testable import TideKit

final class SnapshotTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_793_570_400)

    func testSampleSnapshotIsUsable() throws {
        let s = ForecastSnapshot.sample(now: now)
        XCTAssertEqual(s.version, ForecastSnapshot.currentVersion)
        XCTAssertGreaterThan(s.total.count, 100)
        XCTAssertEqual(s.total.count, s.sigma.count)
        XCTAssertEqual(s.total.count, s.predicted.count)
        XCTAssertNotNil(s.level(at: now + 3_600))
        XCTAssertNotNil(s.isRising(at: now + 3_600))
        XCTAssertEqual(s.nextEvents(after: now).count, 2)
        XCTAssertGreaterThan(try XCTUnwrap(s.uncertainty(at: now + 6 * 3_600)), 0)
        XCTAssertNotNil(s.minorFlood)
        XCTAssertFalse(s.isStale(at: now + 3_600))
        XCTAssertTrue(s.isStale(at: now + 4 * 3_600))
    }

    func testLevelTracksForecastTotalAndPredictedTide() throws {
        let s = ForecastSnapshot.sample(now: now)
        // Sample surge is +0.15 m, so the forecast sits above the tide.
        let t = now + 5 * 3_600
        let diff = try XCTUnwrap(s.level(at: t)) - XCTUnwrap(s.predictedLevel(at: t))
        XCTAssertEqual(diff, 0.15, accuracy: 0.08)
        // Next events alternate and are in the future.
        let ev = s.nextEvents(after: now, limit: 4)
        XCTAssertTrue(ev.allSatisfy { $0.date > now })
        XCTAssertNotEqual(ev[0].kind, ev[1].kind)
        // Chart window covers the request.
        let pts = s.chartPoints(from: now - 3 * 3_600, to: now + 21 * 3_600)
        XCTAssertGreaterThanOrEqual(pts.count, 48)
        XCTAssertTrue(pts.contains { $0.total != nil && $0.lower != nil && $0.upper != nil })
    }

    func testLevelIsAnchoredToTheLatestObservation() throws {
        var base = ForecastSnapshot.sample(now: now)
        base.latestObservation = nil   // forecast only
        var s = base
        let fcNow = try XCTUnwrap(base.level(at: now))
        // A gauge reading 0.2 m above the forecast, just taken.
        s.latestObservation = TimeSeriesPoint(date: now, value: fcNow + 0.2)
        XCTAssertEqual(try XCTUnwrap(s.level(at: now)), fcNow + 0.2, accuracy: 1e-9)
        // Fifteen minutes on: mostly still the measurement's offset…
        let t15 = now + 900
        let gap15 = try XCTUnwrap(s.level(at: t15)) - XCTUnwrap(base.level(at: t15))
        XCTAssertEqual(gap15, 0.2 * exp(-0.25), accuracy: 1e-6)
        // …and back on the forecast a few hours later.
        let t4 = now + 4 * 3_600
        let gap4 = try XCTUnwrap(s.level(at: t4)) - XCTUnwrap(base.level(at: t4))
        XCTAssertLessThan(abs(gap4), 0.01)
    }

    /// The app evaluates the full forecast and the widget its snapshot; at
    /// any moment they must show the same level, trend and next tide.
    func testFullForecastAndSnapshotAgreeAtAnyTime() throws {
        let f = ForecastSnapshot.sampleForecast(now: now)
        let s = ForecastSnapshot(forecast: f)
        for minutes in stride(from: -60, through: 24 * 60, by: 37) {
            let t = now + Double(minutes) * 60
            let a = try XCTUnwrap(f.level(at: t)), b = try XCTUnwrap(s.level(at: t))
            XCTAssertEqual(a, b, accuracy: 0.01, "level at +\(minutes) min")
            if abs(a - (f.level(at: t + 600) ?? a)) > 0.005 {
                XCTAssertEqual(f.isRising(at: t), s.isRising(at: t), "trend at +\(minutes) min")
            }
            XCTAssertEqual(f.nextEvents(after: t, limit: 1).first?.date, s.nextEvents(after: t, limit: 1).first?.date)
        }
    }

    /// App and widget both write; an older forecast finishing later must not
    /// replace a newer one.
    func testStoreKeepsTheNewestSnapshot() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ForecastSnapshotStore(directory: dir)
        let newer = ForecastSnapshot.sample(now: now)
        let older = ForecastSnapshot.sample(now: now - 1_800)
        XCTAssertTrue(try store.save(newer))
        XCTAssertFalse(try store.save(older))
        XCTAssertEqual(store.load(stationID: newer.stationID)?.issued, newer.issued)
        let newest = ForecastSnapshot.sample(now: now + 600)
        XCTAssertTrue(try store.save(newest))
        XCTAssertEqual(store.load(stationID: newer.stationID)?.issued, newest.issued)
    }

    func testStoreRoundTripsIncludingNaNGaps() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ForecastSnapshotStore(directory: dir)
        var s = ForecastSnapshot.sample(now: now)
        s.total[0] = .nan
        try store.save(s)
        let back = try XCTUnwrap(store.load(stationID: s.stationID))
        XCTAssertTrue(back.total[0].isNaN)
        let i = try XCTUnwrap(s.total.lastIndex { !$0.isNaN })
        XCTAssertEqual(back.total[i], s.total[i])
        XCTAssertEqual(back.events, s.events)
        XCTAssertEqual(back.issued, s.issued)
        store.remove(stationID: s.stationID)
        XCTAssertNil(store.load(stationID: s.stationID))
    }

    func testStationCatalogCache() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("stations.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let cache = StationCatalogCache(url: url)
        XCTAssertNil(cache.load())
        let st = [Station(source: .noaaCoops, code: "9414290", name: "San Francisco", latitude: 37.8, longitude: -122.47)]
        try cache.save(st, at: now)
        let loaded = try XCTUnwrap(cache.load())
        XCTAssertEqual(loaded.stations, st)
        XCTAssertEqual(loaded.saved, now)
    }
}
