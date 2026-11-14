import XCTest
@testable import TideKit

/// AIS decoding against real AIVDM sentences (from gpsd's and pyais's public sample
/// logs). Expected values are pyais 2.x's decode of the same sentences.
final class AISDecoderTests: XCTestCase {
    func decode(_ lines: String...) throws -> AISMessage {
        var d = AISDecoder()
        var out: AISMessage?
        for l in lines { out = try d.decode(line: l)?.message }
        return try XCTUnwrap(out, "no message completed")
    }

    func position(_ m: AISMessage) throws -> AISMessage.PositionReport {
        guard case let .position(r, _) = m.body else { struct NotAPositionReport: Error {}; throw NotAPositionReport() }
        return r
    }

    func testType1SanFranciscoBay() throws {
        let m = try decode("!AIVDM,1,1,,B,15M67FC000G?ufbE`FepT@3n00Sa,0*5C")
        XCTAssertEqual(m.type, 1)
        XCTAssertEqual(m.mmsi, 366053209)
        let r = try position(m)
        XCTAssertEqual(r.navigationStatus, .restrictedManoeuverability)
        XCTAssertEqual(r.rateOfTurn, .degreesPerMinute(0))
        XCTAssertEqual(r.speedOverGround, 0)
        XCTAssertFalse(r.positionAccuracyHigh)
        XCTAssertEqual(r.position!.longitude, -122.341618, accuracy: 1e-6)
        XCTAssertEqual(r.position!.latitude, 37.802118, accuracy: 1e-6)
        XCTAssertEqual(r.courseOverGround, 219.3)
        XCTAssertEqual(r.trueHeading, 1)
        XCTAssertEqual(r.timestampSecond, 59)
    }

    func testType1Rotterdam() throws {
        let m = try decode("!AIVDM,1,1,,A,13aEOK?P00PD2wVMdLDRhgvL289?,0*26")
        XCTAssertEqual(m.mmsi, 244670316)
        let r = try position(m)
        XCTAssertNil(r.navigationStatus) // 15: undefined
        XCTAssertNil(r.rateOfTurn)       // −128: not available
        XCTAssertTrue(r.positionAccuracyHigh)
        XCTAssertEqual(r.position!.longitude, 4.379285, accuracy: 1e-6)
        XCTAssertEqual(r.position!.latitude, 51.89475, accuracy: 1e-6)
        XCTAssertEqual(r.courseOverGround, 70.6)
        XCTAssertNil(r.trueHeading) // 511
        XCTAssertTrue(r.raim)
    }

    func testType1And3Moored() throws {
        let seattle = try position(decode("!AIVDM,1,1,,B,177KQJ5000G?tO`K>RA1wUbN0TKH,0*5C"))
        XCTAssertEqual(seattle.navigationStatus, .moored)
        XCTAssertEqual(seattle.position!.latitude, 47.582833, accuracy: 1e-6)
        XCTAssertEqual(seattle.position!.longitude, -122.345833, accuracy: 1e-6)
        XCTAssertEqual(seattle.trueHeading, 181)

        let m3 = try decode("!AIVDM,1,1,,A,35NSH95001G?wopE`beasVk@0E5:,0*6F")
        XCTAssertEqual(m3.type, 3)
        XCTAssertEqual(m3.mmsi, 367581220)
        let r3 = try position(m3)
        XCTAssertEqual(r3.speedOverGround, 0.1)
        XCTAssertEqual(r3.courseOverGround, 254.2)
        XCTAssertEqual(r3.trueHeading, 217)
        XCTAssertEqual(r3.position!.latitude, 37.81065, accuracy: 1e-6)
    }

    func testType4BaseStation() throws {
        let m = try decode("!AIVDM,1,1,,B,403OviQuMGCqWrRO9>E6fE700@GO,0*4E")
        XCTAssertEqual(m.mmsi, 3669702)
        guard case let .baseStation(date, p) = m.body else { return XCTFail("not type 4") }
        XCTAssertEqual(date, ISO8601DateFormatter().date(from: "2007-05-14T19:57:39Z"))
        XCTAssertEqual(p!.latitude, 36.883767, accuracy: 1e-6)
        XCTAssertEqual(p!.longitude, -76.352362, accuracy: 1e-6)
    }

    func testType5TwoFragmentStaticAndVoyage() throws {
        let m = try decode("!AIVDM,2,1,1,A,55?MbV02;H;s<HtKR20EHE:0@T4@Dn2222222216L961O5Gf0NSQEp6ClRp8,0*1C",
                           "!AIVDM,2,2,1,A,88888888880,2*25")
        XCTAssertEqual(m.mmsi, 351759000)
        guard case let .staticAndVoyage(s, v) = m.body else { return XCTFail("not type 5") }
        XCTAssertEqual(s.name, "EVER DIADEM")
        XCTAssertEqual(s.callSign, "3FOF8")
        XCTAssertEqual(s.imo, 9134270)
        XCTAssertEqual(s.shipType, 70)
        XCTAssertEqual(s.dimensions, .init(toBow: 225, toStern: 70, toPort: 1, toStarboard: 31))
        XCTAssertEqual(s.dimensions?.length, 295)
        XCTAssertEqual(v.draught, 12.2)
        XCTAssertEqual(v.destination, "NEW YORK")
        XCTAssertEqual(v.etaMonth, 5); XCTAssertEqual(v.etaDay, 15)
        XCTAssertEqual(v.etaHour, 14); XCTAssertEqual(v.etaMinute, 0)
    }

    func testFragmentsOutOfOrderOrInterleavedAreDropped() throws {
        var d = AISDecoder()
        // Second fragment alone: nothing.
        XCTAssertNil(try d.decode(line: "!AIVDM,2,2,1,A,88888888880,2*25"))
        // A single-fragment message between the two halves doesn't disturb the group.
        XCTAssertNil(try d.decode(line: "!AIVDM,2,1,1,A,55?MbV02;H;s<HtKR20EHE:0@T4@Dn2222222216L961O5Gf0NSQEp6ClRp8,0*1C"))
        XCTAssertEqual(try d.decode(line: "!AIVDM,1,1,,B,15M67FC000G?ufbE`FepT@3n00Sa,0*5C")?.message.mmsi, 366053209)
        XCTAssertEqual(try d.decode(line: "!AIVDM,2,2,1,A,88888888880,2*25")?.message.mmsi, 351759000)
        // A group that times out is discarded.
        let t0 = Date(timeIntervalSince1970: 0)
        XCTAssertNil(try d.decode(line: "!AIVDM,2,1,1,A,55?MbV02;H;s<HtKR20EHE:0@T4@Dn2222222216L961O5Gf0NSQEp6ClRp8,0*1C", at: t0))
        XCTAssertNil(try d.decode(line: "!AIVDM,2,2,1,A,88888888880,2*25", at: t0 + 60))
    }

    func testType18ClassB() throws {
        let m = try decode("!AIVDM,1,1,,A,B6CdCm0t3`tba35f@V9faHi7kP06,0*58")
        XCTAssertEqual(m.mmsi, 423302100)
        let r = try position(m)
        XCTAssertTrue(r.isClassB)
        XCTAssertEqual(r.speedOverGround, 1.4)
        XCTAssertEqual(r.position!.longitude, 53.010997, accuracy: 1e-6)
        XCTAssertEqual(r.position!.latitude, 40.005283, accuracy: 1e-6)
        XCTAssertEqual(r.courseOverGround, 177)
        XCTAssertEqual(r.trueHeading, 177)
        XCTAssertEqual(r.timestampSecond, 34)
    }

    func testType19ClassBExtended() throws {
        let m = try decode("!AIVDM,1,1,,B,C5N3SRgPEnJGEBT>NhWAwwo862PaLELTBJ:V00000000S0D:R220,0*0B")
        XCTAssertEqual(m.mmsi, 367059850)
        guard case let .position(r, s) = m.body else { return XCTFail("not type 19") }
        XCTAssertEqual(r.speedOverGround, 8.7)
        XCTAssertEqual(r.position!.latitude, 29.543695, accuracy: 1e-6)
        XCTAssertEqual(r.position!.longitude, -88.810392, accuracy: 1e-6)
        XCTAssertEqual(r.courseOverGround, 335.9)
        XCTAssertNil(r.trueHeading)
        XCTAssertEqual(s?.name, "CAPT.J.RIMES")
        XCTAssertEqual(s?.shipType, 70)
        XCTAssertEqual(s?.dimensions, .init(toBow: 5, toStern: 21, toPort: 4, toStarboard: 4))
    }

    func testType21AidToNavigation() throws {
        let m = try decode("!AIVDM,1,1,,B,E>jCfrv2`0c2h0W:0a2ah@@@@@@004WD>;2<H50hppN000,4*0A")
        XCTAssertEqual(m.mmsi, 992276203)
        guard case let .aidToNavigation(a) = m.body else { return XCTFail("not type 21") }
        XCTAssertEqual(a.aidType, 28) // isolated danger
        XCTAssertEqual(a.name, "EPAVE ANTARES")
        XCTAssertEqual(a.position!.latitude, 49.536165, accuracy: 1e-6)
        XCTAssertEqual(a.position!.longitude, 0.0315, accuracy: 1e-6)
        XCTAssertFalse(a.offPosition)
        XCTAssertFalse(a.isVirtual)
    }

    func testType24PartB() throws {
        let m = try decode("!AIVDM,1,1,,A,H52KMeDU653hhhi0000000000000,0*1A")
        XCTAssertEqual(m.mmsi, 338091445)
        guard case let .staticDataReport(s) = m.body else { return XCTFail("not type 24") }
        XCTAssertEqual(s.part, 1)
        XCTAssertEqual(s.shipType, 37) // pleasure craft
        XCTAssertEqual(s.vendorID, "FEC")
        XCTAssertEqual(s.callSign, "")
    }

    func testBadChecksumAndBadPayloadThrow() {
        var d = AISDecoder()
        // Same type 24 sentence published with a wrong checksum (0x35, should be 0x34).
        XCTAssertThrowsError(try d.decode(line: "!AIVDM,1,1,,B,H52KMeDT4@Dhhhi0000000000000,0*35"))
        XCTAssertThrowsError(try d.decode(line: NMEASentence.make("!", "AIVDM,1,1,,A,15M67F~000,0")))
        XCTAssertThrowsError(try d.decode(line: NMEASentence.make("!", "AIVDM,1,1,,A,15M6,0"))) // too short
    }

    func testBitReaderSignedFields() throws {
        // "w" = 63 = 111111: as a 6-bit signed value, −1.
        let b = try XCTUnwrap(AISBits(payload: "w0", fillBits: 0))
        XCTAssertEqual(b.int(0, 6), -1)
        XCTAssertEqual(b.uint(0, 6), 63)
        XCTAssertEqual(b.int(6, 6), 0)
        XCTAssertEqual(AISMessage.rateOfTurn(-127), .fastTurn(starboard: false))
        if case let .degreesPerMinute(r)? = AISMessage.rateOfTurn(10) { XCTAssertEqual(r, 4.464, accuracy: 0.001) } else { XCTFail() }
    }
}
