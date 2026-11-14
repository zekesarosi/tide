import XCTest
@testable import TideKit

/// NMEA 0183 framing and sentences. The RMC, GGA, VTG, GLL, ZDA, HDG and RMB samples are
/// the classic published examples (NMEA reference manuals, gpsd and Dale DePriest's
/// "NMEA data"), with their published checksums.
final class NMEASentenceTests: XCTestCase {
    func testFramingAndChecksum() throws {
        let s = try NMEASentence("$GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,230394,003.1,W*6A\r\n")
        XCTAssertEqual(s.talker, "GP")
        XCTAssertEqual(s.formatter, "RMC")
        XCTAssertEqual(s.fields.count, 11)
        XCTAssertFalse(s.isEncapsulated)
        XCTAssertThrowsError(try NMEASentence("$GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,230394,003.1,W*6B")) {
            XCTAssertEqual($0 as? NMEASentence.ParseError, .badChecksum(expected: 0x6B, actual: 0x6A))
        }
        XCTAssertThrowsError(try NMEASentence("GPRMC,123519")) { XCTAssertEqual($0 as? NMEASentence.ParseError, .badStart) }
        XCTAssertThrowsError(try NMEASentence("")) { XCTAssertEqual($0 as? NMEASentence.ParseError, .empty) }
        XCTAssertThrowsError(try NMEASentence("$GPHDT,274.07,T", requireChecksum: true)) {
            XCTAssertEqual($0 as? NMEASentence.ParseError, .missingChecksum)
        }
        XCTAssertNoThrow(try NMEASentence("$GPHDT,274.07,T"))
        XCTAssertEqual(NMEASentence.make("$", "HEHDT,274.07,T"), "$HEHDT,274.07,T*19")
    }

    func testProprietaryAndTagBlock() throws {
        let p = try NMEASentence("$PGRMZ,246,f,3*1B")
        XCTAssertEqual(p.talker, "P")
        XCTAssertEqual(p.formatter, "GRMZ")
        let t = try NMEASentence("\\s:2573535,c:1671620143*0B\\!AIVDM,1,1,,A,13aEOK?P00PD2wVMdLDRhgvL289?,0*26")
        XCTAssertEqual(t.tagBlock["s"], "2573535")
        XCTAssertEqual(t.tagBlock["c"], "1671620143")
        XCTAssertTrue(t.isEncapsulated)
        XCTAssertEqual(t.formatter, "VDM")
    }

    func testRMC() throws {
        guard case let .rmc(r) = try NMEAMessage.parse("$GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,230394,003.1,W*6A") else {
            return XCTFail("not RMC")
        }
        XCTAssertTrue(r.isValid)
        XCTAssertEqual(r.position!.latitude, 48 + 7.038 / 60, accuracy: 1e-12)
        XCTAssertEqual(r.position!.longitude, 11 + 31.0 / 60, accuracy: 1e-12)
        XCTAssertEqual(r.speedOverGround, 22.4)
        XCTAssertEqual(r.courseOverGround, 84.4)
        XCTAssertEqual(r.magneticVariation, -3.1)
        XCTAssertEqual(r.date, ISO8601DateFormatter().date(from: "1994-03-23T12:35:19Z"))

        // NMEA 2.3+ with mode indicator, west longitude, fractional seconds.
        guard case let .rmc(g) = try NMEAMessage.parse("$GNRMC,001031.00,A,4404.13993,N,12118.86023,W,0.146,,100117,,,A*7B") else {
            return XCTFail("not RMC")
        }
        XCTAssertEqual(g.position!.longitude, -(121 + 18.86023 / 60), accuracy: 1e-12)
        XCTAssertNil(g.courseOverGround)
        XCTAssertEqual(g.date, ISO8601DateFormatter().date(from: "2017-01-10T00:10:31Z"))
    }

    func testGGAGLLVTGZDA() throws {
        guard case let .gga(g) = try NMEAMessage.parse("$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*47") else {
            return XCTFail("not GGA")
        }
        XCTAssertTrue(g.hasFix)
        XCTAssertEqual(g.satellites, 8)
        XCTAssertEqual(g.hdop, 0.9)
        XCTAssertEqual(g.altitude, 545.4)
        XCTAssertEqual(g.timeOfDay, 12 * 3_600 + 35 * 60 + 19)

        guard case let .gll(l) = try NMEAMessage.parse("$GPGLL,4916.45,N,12311.12,W,225444,A,*1D") else { return XCTFail("not GLL") }
        XCTAssertTrue(l.isValid)
        XCTAssertEqual(l.position!.latitude, 49 + 16.45 / 60, accuracy: 1e-12)
        XCTAssertEqual(l.position!.longitude, -(123 + 11.12 / 60), accuracy: 1e-12)

        guard case let .vtg(v) = try NMEAMessage.parse("$GPVTG,054.7,T,034.4,M,005.5,N,010.2,K*48") else { return XCTFail("not VTG") }
        XCTAssertEqual(v.courseTrue, 54.7)
        XCTAssertEqual(v.courseMagnetic, 34.4)
        XCTAssertEqual(v.speedKnots, 5.5)

        guard case let .zda(d) = try NMEAMessage.parse("$GPZDA,201530.00,04,07,2002,00,00*60") else { return XCTFail("not ZDA") }
        XCTAssertEqual(d, ISO8601DateFormatter().date(from: "2002-07-04T20:15:30Z"))
    }

    func testHeadingWindDepthSpeed() throws {
        guard case let .heading(h) = try NMEAMessage.parse("$HCHDG,98.3,0.0,E,12.6,W*57") else { return XCTFail("not HDG") }
        XCTAssertEqual(h.reference, .magnetic)
        XCTAssertEqual(h.variation, -12.6)
        XCTAssertEqual(h.trueHeading!, 85.7, accuracy: 1e-9)
        guard case let .heading(t) = try NMEAMessage.parse("$HEHDT,274.07,T*19") else { return XCTFail("not HDT") }
        XCTAssertEqual(t.trueHeading, 274.07)

        guard case let .wind(w) = try NMEAMessage.parse("$IIMWV,045.0,R,12.5,N,A*0A") else { return XCTFail("not MWV") }
        XCTAssertTrue(w.isRelative)
        XCTAssertEqual(w.angle, 45)
        XCTAssertEqual(w.speedKnots, 12.5)
        guard case let .wind(tw) = try NMEAMessage.parse("$WIMWV,214.8,T,10.1,M,A*19") else { return XCTFail("not MWV") }
        XCTAssertFalse(tw.isRelative)
        XCTAssertEqual(tw.speedKnots, 10.1 * 3_600 / 1_852, accuracy: 1e-9)

        guard case let .depth(dbt) = try NMEAMessage.parse("$SDDBT,7.8,f,2.4,M,1.3,F*0D") else { return XCTFail("not DBT") }
        XCTAssertEqual(dbt.belowTransducer, 2.4)
        guard case let .depth(dpt) = try NMEAMessage.parse("$SDDPT,2.4,0.5*54") else { return XCTFail("not DPT") }
        XCTAssertEqual(dpt.adjusted!, 2.9, accuracy: 1e-12)

        guard case let .waterSpeed(vhw) = try NMEAMessage.parse("$VWVHW,,T,,M,5.2,N,9.6,K*5C") else { return XCTFail("not VHW") }
        XCTAssertEqual(vhw.speedKnots, 5.2)
        XCTAssertNil(vhw.headingTrue)
        guard case let .waterTemperature(c) = try NMEAMessage.parse("$YXMTW,17.75,C*26") else { return XCTFail("not MTW") }
        XCTAssertEqual(c, 17.75)
    }

    func testXTEAndRMB() throws {
        guard case let .crossTrackError(x) = try NMEAMessage.parse("$GPXTE,A,A,0.67,L,N*6F") else { return XCTFail("not XTE") }
        XCTAssertEqual(x.steerRightNauticalMiles, -0.67)
        XCTAssertTrue(x.isValid)
        guard case let .rmb(r) = try NMEAMessage.parse("$GPRMB,A,0.66,L,003,004,4917.24,N,12309.57,W,001.3,052.5,000.5,V*20") else {
            return XCTFail("not RMB")
        }
        XCTAssertTrue(r.isValid)
        XCTAssertEqual(r.crossTrack?.steerRightNauticalMiles, -0.66)
        XCTAssertEqual(r.originID, "003")
        XCTAssertEqual(r.destinationID, "004")
        XCTAssertEqual(r.destination!.latitude, 49 + 17.24 / 60, accuracy: 1e-12)
        XCTAssertEqual(r.rangeToDestination, 1.3)
        XCTAssertEqual(r.bearingToDestination, 52.5)
        XCTAssertEqual(r.closingVelocity, 0.5)
        XCTAssertFalse(r.arrived)
    }

    func testUnknownSentenceIsOther() throws {
        guard case let .other(s) = try NMEAMessage.parse("$PGRMZ,246,f,3*1B") else { return XCTFail("expected .other") }
        XCTAssertEqual(s.formatter, "GRMZ")
    }

    func testLineSplitterHandlesPartialLinesAndMixedEndings() {
        var splitter = NMEALineSplitter()
        XCTAssertEqual(splitter.append("$GPHDT,1.0,T*xx\r\n$GPHD"), ["$GPHDT,1.0,T*xx"])
        XCTAssertEqual(splitter.append("T,2.0,T\n\n$X"), ["$GPHDT,2.0,T"])
        XCTAssertEqual(splitter.append(Data("Y\r".utf8)), ["$XY"])
        XCTAssertEqual(splitter.append(""), [])
    }
}
