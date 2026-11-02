import XCTest
@testable import TideKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// San Francisco Bay: the station set, the offset maths, and the service's
/// tolerance of failures. Fixtures from api.tidesandcurrents.noaa.gov.
final class BayTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_793_491_200) // 2026-11-01 00:00 UTC

    func predictor(_ code: String) throws -> HarmonicPredictor {
        let c = try NOAACoopsDecoding.harmonicConstituents(from: Fixtures.data("harcon_\(code)"))
        let d = try NOAACoopsDecoding.datums(from: Fixtures.data("datums_\(code)"))
        return HarmonicPredictor(constituents: c, meanLevel: try XCTUnwrap(d.offset(of: .msl, relativeTo: .mllw)))
    }

    // MARK: Catalogue

    func testStationSet() {
        let codes = SFBay.stations.map(\.code)
        XCTAssertEqual(Set(codes).count, codes.count, "duplicate station")
        XCTAssertEqual(SFBay.stations.first?.region, .coast)
        XCTAssertEqual(SFBay.reference.code, "9414290")
        XCTAssertNotNil(SFBay.station(code: SFBay.defaultComparisonCode))
        for r in BayRegion.allCases { XCTAssertTrue(SFBay.stations.contains { $0.region == r }, r.rawValue) }
        let s = SFBay.reference.station
        XCTAssertEqual(s.id, "noaa-coops:9414290")
        XCTAssertEqual(s.timeZone.identifier, "America/Los_Angeles")
        XCTAssertTrue(SFBay.contains(s))
        XCTAssertFalse(SFBay.contains(Station(source: .noaaCoops, code: "8518750", name: "The Battery", latitude: 40.7, longitude: -74)))
        XCTAssertFalse(SFBay.contains(Station(source: .dfoIWLS, code: "9414290", name: "x", latitude: 0, longitude: 0)))
    }

    // MARK: Synthetic

    /// Mixed semidiurnal tide shifted by `lag`, with optional noise and a slow surge.
    func synthetic(lag: TimeInterval, days: Double = 20, step: TimeInterval = 360, noise: Double = 0, surge: Double = 0) -> TimeSeries {
        var rng = SeededGenerator(seed: UInt64(lag.magnitude) + 7)
        let m2 = 2 * Double.pi / (12.4206 * 3_600), k1 = 2 * Double.pi / (23.9345 * 3_600)
        return TimeSeries(points: stride(from: 0, through: days * 86_400, by: step).map { s in
            let t = s - lag
            var v = 0.6 * cos(m2 * t) + 0.37 * cos(k1 * t + 0.4) + surge * sin(2 * .pi * s / (4 * 86_400))
            if noise > 0 { v += Double.random(in: -noise...noise, using: &rng) }
            return TimeSeriesPoint(date: t0 + s, value: v)
        })
    }

    func testCrossCorrelationRecoversLag() throws {
        let ref = synthetic(lag: 0, noise: 0.02, surge: 0.15)
        for lagMinutes in [-37.0, 12, 75, 150] {
            let st = synthetic(lag: lagMinutes * 60, noise: 0.02, surge: 0.15).mapValues { $0 * 1.3 + 0.8 }
            let est = try XCTUnwrap(OffsetAnalysis.crossCorrelationLag(reference: ref, station: st))
            XCTAssertEqual(est.lag / 60, lagMinutes, accuracy: 1.5, "lag \(lagMinutes)")
            XCTAssertGreaterThan(est.correlation, 0.98)
        }
    }

    func testCrossCorrelationToleratesGaps() throws {
        let ref = synthetic(lag: 0)
        let st = synthetic(lag: 20 * 60)
        let gappy = TimeSeries(points: st.points.filter { p in
            let h = p.date.timeIntervalSince(t0) / 3_600
            return !(h > 50 && h < 80) && !(h > 200 && h < 203)
        })
        let est = try XCTUnwrap(OffsetAnalysis.crossCorrelationLag(reference: ref, station: gappy))
        XCTAssertEqual(est.lag / 60, 20, accuracy: 1)
        XCTAssertNil(OffsetAnalysis.crossCorrelationLag(reference: ref, station: .empty))
    }

    func testPairsMatchAcrossLongLags() {
        let ref = synthetic(lag: 0, step: 300).extrema()
        // 5.5 h: beyond a quarter period, where "nearest extreme" would pair a high with the wrong high.
        for lagHours in [0.25, 2.5, 5.5] {
            let st = synthetic(lag: lagHours * 3_600, step: 300).extrema()
            for kind in [TideExtremeKind.high, .low] {
                let pairs = OffsetAnalysis.pairs(reference: ref, station: st, kind: kind)
                XCTAssertGreaterThan(pairs.count, 30, "\(lagHours) \(kind)")
                let lags = pairs.map { $0.lag / 3_600 }
                XCTAssertEqual(lags.reduce(0, +) / Double(lags.count), lagHours, accuracy: 0.02)
                XCTAssertEqual(Set(pairs.map(\.station.date)).count, pairs.count, "station extreme reused")
            }
        }
    }

    func testObservedExtremaIgnoreNoise() {
        let clean = synthetic(lag: 0, step: 360).extrema()
        let noisy = OffsetAnalysis.observedExtrema(synthetic(lag: 0, step: 360, noise: 0.04))
        // Every true extreme found once, within ~10 minutes.
        XCTAssertEqual(Double(noisy.count), Double(clean.count), accuracy: 2)
        let highs = OffsetAnalysis.pairs(reference: clean, station: noisy, kind: .high)
        XCTAssertGreaterThan(highs.count, clean.filter { $0.kind == .high }.count - 2)
        // Flat lower highs are ill-defined in time; most turns are sharp.
        let errors = highs.map { abs($0.lag) / 60 }.sorted()
        XCTAssertLessThan(errors[errors.count / 2], 7)
        XCTAssertLessThan(errors[errors.count * 9 / 10], 20)
    }

    func testLagStatistics() throws {
        let s = try XCTUnwrap(LagStatistics(samples: [60, 120, 180, 600]))
        XCTAssertEqual(s.mean, 240)
        XCTAssertEqual(s.median, 150)
        XCTAssertEqual(s.minimum, 60)
        XCTAssertEqual(s.maximum, 600)
        XCTAssertEqual(s.standardDeviation, 244.95, accuracy: 0.01)
        XCTAssertNil(LagStatistics(samples: []))
    }

    // MARK: Real harmonics

    /// Sausalito vs San Francisco from harmonics: minutes, not hours. NOAA's
    /// published subordinate differences are +10 min (high) and +14 min
    /// (low), height ratio 0.97.
    func testSausalitoOffsets() throws {
        let sf = try predictor("9414290"), sau = try predictor("9414806")
        let end = t0 + 59 * 86_400
        let o = OffsetAnalysis.offsets(reference: sf.extrema(from: t0, to: end), station: sau.extrema(from: t0 - 21_600, to: end + 21_600))
        let high = try XCTUnwrap(o.high), low = try XCTUnwrap(o.low)
        XCTAssertGreaterThan(high.count, 105)
        XCTAssertEqual(high.mean / 60, 12, accuracy: 6)
        XCTAssertEqual(low.mean / 60, 14, accuracy: 6)
        XCTAssertLessThan(high.standardDeviation / 60, 10)
        XCTAssertEqual(try XCTUnwrap(o.rangeRatio), 0.96, accuracy: 0.03)
        XCTAssertEqual(try XCTUnwrap(o.highHeightRatio), 0.97, accuracy: 0.03)
    }

    /// Port Chicago (Suisun Bay) against NOAA's official high/low tables for
    /// November 2026: the on-device lags agree with the same computation on
    /// NOAA's own predictions to within a minute.
    func testPortChicagoMatchesNOAATables() throws {
        let noaaSF = try NOAACoopsDecoding.extremes(from: Fixtures.data("hilo_9414290_202611"))
        let noaaPC = try NOAACoopsDecoding.extremes(from: Fixtures.data("hilo_9415144_202611"))
        let start = t0 + 6 * 3_600, end = t0 + 24 * 86_400
        let window = DateInterval(start: start, end: end)
        let official = OffsetAnalysis.offsets(reference: noaaSF.filter { window.contains($0.date) }, station: noaaPC)

        let sf = try predictor("9414290"), pc = try predictor("9415144")
        let local = OffsetAnalysis.offsets(reference: sf.extrema(from: start, to: end),
                                           station: pc.extrema(from: start - 21_600, to: end + 21_600))
        let oh = try XCTUnwrap(official.high), lh = try XCTUnwrap(local.high)
        let ol = try XCTUnwrap(official.low), ll = try XCTUnwrap(local.low)
        XCTAssertEqual(lh.mean, oh.mean, accuracy: 60)
        XCTAssertEqual(ll.mean, ol.mean, accuracy: 60)
        XCTAssertEqual(lh.count, oh.count)
        // Over two hours up-estuary, and a smaller range than at the Gate.
        XCTAssertGreaterThan(lh.mean / 60, 120)
        XCTAssertGreaterThan(ll.mean, lh.mean)
        XCTAssertLessThan(try XCTUnwrap(local.rangeRatio), 0.95)
    }

    // MARK: Service

    func testServiceToleratesStationFailures() async throws {
        let failing = BayStation(code: "9415144", name: "Port Chicago", shortName: "Port Chicago",
                                 latitude: 38.056, longitude: -122.04, region: .north, hasObservations: true)
        let routes: [String: Data] = [
            "9414290/harcon": try Fixtures.data("harcon_9414290"), "9414290/datums": try Fixtures.data("datums_9414290"),
            "9414806/harcon": try Fixtures.data("harcon_9414806"), "9414806/datums": try Fixtures.data("datums_9414806"),
        ]
        let api = APIClient(identity: AppIdentity(appName: "Test", version: "1", contact: "t@example.com"),
                            credentials: InMemoryCredentialStore([:]), transport: RoutingTransport(routes),
                            maxAttempts: 1, baseBackoff: 0.01, hostSpacing: [:])
        let stations = [SFBay.reference, SFBay.station(code: "9414806")!, failing]
        let service = BayService(coops: NOAACoopsClient(api: api), stations: stations)
        let a = try await service.analyze(now: t0 + 30 * 86_400, predictionDays: 30, observationDays: 3)

        XCTAssertEqual(a.stations.map(\.station.code), ["9414290", "9414806"])
        XCTAssertTrue(a.problems.contains { $0.component.contains("Port Chicago") })
        XCTAssertEqual(a.reference?.offsets?.high?.mean ?? -1, 0, accuracy: 1)
        let sau = try XCTUnwrap(a.station(code: "9414806"))
        XCTAssertEqual(sau.datum, .mllw)
        XCTAssertEqual(try XCTUnwrap(sau.offsets?.high?.mean) / 60, 12, accuracy: 6)
        XCTAssertNotNil(sau.predictedCurveLag)
        XCTAssertNil(sau.observedCurveLag) // no gauge
        XCTAssertNil(a.reference?.observedCurveLag) // gauge returned no data

        // Without the reference there is nothing to compare against.
        let noRef = BayService(coops: NOAACoopsClient(api: api), stations: [SFBay.station(code: "9414806")!])
        do {
            _ = try await noRef.analyze(now: t0, predictionDays: 10, observationDays: 1)
            XCTFail("expected failure without the reference")
        } catch {}
    }
}

/// Deterministic noise for tests (SplitMix64).
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Serves fixtures by "<station>/<resource>" path fragment; data requests
/// get NOAA's "no data" error, anything else a 404.
final class RoutingTransport: HTTPTransport, @unchecked Sendable {
    let routes: [String: Data]
    init(_ routes: [String: Data]) { self.routes = routes }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        func reply(_ status: Int, _ data: Data) -> (Data, HTTPURLResponse) {
            (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        if let hit = routes.first(where: { url.path.contains($0.key) }) { return reply(200, hit.value) }
        if url.path.contains("datagetter") { return reply(200, Data(#"{"error":{"message":"No data was found."}}"#.utf8)) }
        return reply(404, Data())
    }
}
