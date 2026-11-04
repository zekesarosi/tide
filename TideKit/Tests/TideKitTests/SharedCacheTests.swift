import XCTest
@testable import TideKit

/// The App Group caches that let the app and widget share downloads.
final class SharedCacheTests: XCTestCase {
    let identity = AppIdentity(appName: "Tide App", version: "1.2", contact: "ops@example.com")
    var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func client(_ t: MockTransport, disk: DiskResponseCache) -> APIClient {
        APIClient(identity: identity, credentials: InMemoryCredentialStore(), transport: t, maxAttempts: 1,
                  baseBackoff: 0.01, hostSpacing: [:], diskCache: disk)
    }

    /// A second client (another process or launch) is served from disk.
    func testLongLivedResponsesAreSharedThroughDisk() async throws {
        let disk = DiskResponseCache(directory: dir)
        let ep = try Endpoint.build(.noaaCoops, "https://example.com/harcon.json", cacheTTL: 30 * 86_400)
        let t1 = MockTransport([(200, Data("harcon".utf8), [:])])
        _ = try await client(t1, disk: disk).data(for: ep)
        let t2 = MockTransport([(200, Data("other".utf8), [:])])
        let body = try await client(t2, disk: disk).data(for: ep)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "harcon")
        XCTAssertTrue(t2.requests.isEmpty)
    }

    func testShortLivedResponsesStayInMemoryOnly() async throws {
        let disk = DiskResponseCache(directory: dir)
        let ep = try Endpoint.build(.noaaCoops, "https://example.com/latest.json", cacheTTL: 300)
        _ = try await client(MockTransport([(200, Data("a".utf8), [:])]), disk: disk).data(for: ep)
        let t2 = MockTransport([(200, Data("b".utf8), [:])])
        _ = try await client(t2, disk: disk).data(for: ep)
        XCTAssertEqual(t2.requests.count, 1)
    }

    func testExpiryAndVolatilePrune() throws {
        let disk = DiskResponseCache(directory: dir)
        let now = Date()
        disk.write(Data("static".utf8), for: "s", ttl: 30 * 86_400, now: now)
        disk.write(Data("weather".utf8), for: "w", ttl: 1_800, now: now)
        XCTAssertEqual(disk.read("w", now: now + 60).map { String(decoding: $0, as: UTF8.self) }, "weather")
        XCTAssertNil(disk.read("w", now: now + 1_801))
        disk.prune(volatileOnly: true, now: now)
        XCTAssertNil(disk.read("w", now: now))
        XCTAssertNotNil(disk.read("s", now: now))
    }

    /// A refresh fetches only the tail since the stored record, and the
    /// re-fetched overlap replaces stored points.
    func testArchiveFetchesOnlyNewReadings() async throws {
        let archive = ObservationArchive(directory: dir)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func series(_ a: Date, _ b: Date, offset: Double) -> TimeSeries {
            // Readings on the gauge's fixed 6-minute grid.
            let start = (a.timeIntervalSince1970 / 360).rounded(.up) * 360
            return TimeSeries(points: stride(from: start, through: b.timeIntervalSince1970, by: 360)
                .map { TimeSeriesPoint(date: Date(timeIntervalSince1970: $0), value: offset) })
        }
        let calls = LockedCalls()
        let first = try await archive.series(key: "st", from: t0, to: t0 + 30 * 86_400) { a, b in
            calls.add(a, b); return series(a, b, offset: 1)
        }
        let later = t0 + 30 * 86_400 + 1_440
        let second = try await archive.series(key: "st", from: t0 + 1_440, to: later) { a, b in
            calls.add(a, b); return series(a, b, offset: 2)
        }
        XCTAssertEqual(calls.all.count, 2)
        // Second call asked only for the overlap plus the new 24 minutes.
        XCTAssertEqual(calls.all[1].0, t0 + 30 * 86_400 - ObservationArchive.overlap)
        XCTAssertEqual(second.first?.date, t0 + 1_440)
        XCTAssertEqual(second.last?.date, later)
        XCTAssertEqual(second.value(at: t0 + 86_400), 1)                          // kept from the archive
        XCTAssertEqual(second.value(at: t0 + 30 * 86_400 - 3_600), 2)             // overlap replaced
        XCTAssertGreaterThan(first.count, 7_000)
        // A failed tail fetch falls back to what's stored.
        let offline = try await archive.series(key: "st", from: t0 + 2_880, to: later + 1_440) { _, _ in
            throw APIError.network(source: .noaaCoops, message: "offline")
        }
        XCTAssertEqual(offline.last?.date, later)
    }
}

private final class LockedCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(Date, Date)] = []
    func add(_ a: Date, _ b: Date) { lock.withLock { calls.append((a, b)) } }
    var all: [(Date, Date)] { lock.withLock { calls } }
}
