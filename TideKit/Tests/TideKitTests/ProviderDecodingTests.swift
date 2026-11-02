import XCTest
@testable import TideKit

final class ProviderDecodingTests: XCTestCase {
    func testCoopsStations() throws {
        let stations = try NOAACoopsDecoding.stations(from: Fixtures.data("stations_waterlevels"))
        let battery = try XCTUnwrap(stations.first { $0.code == "8518750" })
        XCTAssertEqual(battery.name, "The Battery")
        XCTAssertEqual(battery.nwsLID, "BATN6")
        XCTAssertEqual(battery.timeZoneIdentifier, "America/New_York")
        XCTAssertTrue(battery.capabilities.contains(.harmonics))
        let buffalo = try XCTUnwrap(stations.first { $0.code == "9063020" })
        XCTAssertFalse(buffalo.isTidal)
        XCTAssertFalse(buffalo.capabilities.contains(.harmonics))
        XCTAssertEqual(stations.first { $0.code == "9455920" }?.timeZoneIdentifier, "America/Anchorage")
    }

    func testCoopsDatumsAndFloodLevels() throws {
        let datums = try NOAACoopsDecoding.datums(from: Fixtures.data("datums_8518750"))
        XCTAssertEqual(try XCTUnwrap(datums.offset(of: .mhhw, relativeTo: .mllw)), 1.541, accuracy: 1e-9)
        XCTAssertNotNil(datums.values[.navd88])
        let flood = try XCTUnwrap(try NOAACoopsDecoding.floodThresholds(from: Fixtures.data("floodlevels_8518750")))
        XCTAssertEqual(flood.authority, "NWS")
        XCTAssertEqual(flood.datum, .stnd)
        let mllw = try XCTUnwrap(flood.converted(to: .mllw, using: datums))
        XCTAssertEqual(try XCTUnwrap(mllw.minor), 3.197 - 1.002, accuracy: 1e-9)
        XCTAssertEqual(mllw.category(for: 2.3), .minor)
        XCTAssertEqual(mllw.category(for: 1.0), .none)
        XCTAssertEqual(mllw.category(for: 3.5), .major)
    }

    func testCoopsWaterLevelsAndErrors() throws {
        let wl = try NOAACoopsDecoding.waterLevels(from: Fixtures.data("water_level_8518750"))
        XCTAssertGreaterThan(wl.count, 200)
        XCTAssertEqual(wl.points[1].date.timeIntervalSince(wl.points[0].date), 360)

        let error = Data(#"{"error": {"message":"No data was found. This product may not be offered at this station at the requested time."}}"#.utf8)
        XCTAssertThrowsError(try NOAACoopsDecoding.waterLevels(from: error)) { e in
            guard case APIError.provider(.noaaCoops, let msg) = e else { return XCTFail("\(e)") }
            XCTAssertTrue(msg.contains("No data"))
        }
        // Missing values ("") are skipped, not fatal.
        let gappy = Data(#"{"data":[{"t":"2026-11-01 00:00","v":"","s":"","f":"","q":""},{"t":"2026-11-01 00:06","v":"0.5"}]}"#.utf8)
        XCTAssertEqual(try NOAACoopsDecoding.waterLevels(from: gappy).count, 1)
    }

    func testNWPS() throws {
        let f = try XCTUnwrap(try NWPSDecoding.forecast(from: Fixtures.data("nwps_BATN6_stageflow"),
                                                        gaugeName: "New York Harbor at The Battery (IN MLLW)"))
        XCTAssertEqual(f.datumHint, "IN MLLW")
        XCTAssertGreaterThan(f.forecast.count, 24)
        XCTAssertGreaterThan(f.observed.count, 100)
        // Feet converted to metres: Battery tides stay within ~-1…3 m MLLW.
        XCTAssertLessThan(try XCTUnwrap(f.forecast.maximum?.value), 3)
    }

    func testOpenMeteo() throws {
        let samples = try OpenMeteoDecoding.forcing(from: Fixtures.data("openmeteo_forecast"))
        XCTAssertEqual(samples.count, 72)
        let s = samples[0]
        XCTAssertGreaterThan(s.pressure, 950)
        XCTAssertLessThan(s.pressure, 1060)
        let err = Data(#"{"error":true,"reason":"Invalid API key"}"#.utf8)
        XCTAssertThrowsError(try OpenMeteoDecoding.forcing(from: err))
    }

    func testWindComponents() {
        // Wind from the north blows toward the south: v < 0.
        let n = MetSample(date: Date(), pressure: 1013, windSpeed: 10, windDirection: 0).components
        XCTAssertEqual(n.u, 0, accuracy: 1e-9)
        XCTAssertEqual(n.v, -10, accuracy: 1e-9)
        let e = MetSample(date: Date(), pressure: 1013, windSpeed: 10, windDirection: 90).components
        XCTAssertEqual(e.u, -10, accuracy: 1e-9)
    }

    func testNWSAlerts() throws {
        let alerts = try NWSDecoding.alerts(from: Fixtures.data("nws_alerts"))
        XCTAssertEqual(alerts.count, 2)
        XCTAssertEqual(alerts.filter(\.isCoastal).map(\.event), ["Coastal Flood Advisory"])
        XCTAssertNotNil(alerts[0].onset)
    }

    func testNHC() throws {
        let storms = try NHCDecoding.storms(from: Fixtures.data("nhc_current_storms"))
        XCTAssertFalse(storms.isEmpty)
        XCTAssertNotNil(storms[0].latitude)
        XCTAssertEqual(storms[0].name, "Gert")
    }

    func testDFO() throws {
        let stations = try DFODecoding.stations(from: Fixtures.data("dfo_stations"))
        XCTAssertEqual(stations.first?.name, "Point Atkinson")
        XCTAssertTrue(stations.first?.capabilities.contains(.predictions) == true)
        let wlp = try DFODecoding.series(from: Fixtures.data("dfo_wlp"))
        XCTAssertGreaterThan(wlp.count, 100)
    }

    func testAdmiraltyEvents() throws {
        let json = Data(#"[{"EventType":"HighWater","DateTime":"2026-11-02T04:31:00","IsApproximateTime":false,"Height":4.71,"IsApproximateHeight":false,"Filtered":false,"Date":"2026-11-02T00:00:00"},{"EventType":"LowWater","DateTime":"2026-11-02T10:52:12.5","Height":0.9}]"#.utf8)
        let events = try AdmiraltyDecoding.events(from: json)
        XCTAssertEqual(events.map(\.kind), [.high, .low])
        XCTAssertEqual(events[0].date.timeIntervalSince1970, 1_793_593_860, accuracy: 1)
        let curve = TimeSeries.interpolating(extremes: events)
        XCTAssertEqual(try XCTUnwrap(curve.first?.value), 4.71, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(curve.last?.value), 0.9, accuracy: 1e-9)
    }
}
