import Foundation

/// A decoded AIS message (ITU-R M.1371-5). Covers what a chart plotter needs for
/// traffic display and collision avoidance: Class A and B position reports, static and
/// voyage data, base stations and aids to navigation.
public struct AISMessage: Sendable, Hashable {
    public var type: Int
    public var repeatIndicator: Int
    public var mmsi: Int
    public var body: Body

    public enum Body: Sendable, Hashable {
        /// Types 1, 2, 3 (Class A), 18 (Class B CS) and 19 (Class B extended, whose static
        /// part is also delivered as `staticData`).
        case position(PositionReport, staticData: StaticData?)
        /// Type 4: base station report (UTC and surveyed position).
        case baseStation(date: Date?, position: GeoCoordinate?)
        /// Type 5: Class A static and voyage data.
        case staticAndVoyage(StaticData, Voyage)
        /// Type 21: aid to navigation.
        case aidToNavigation(AidToNavigation)
        /// Type 24: Class B static data, part A (name) or B (type, call sign, dimensions).
        case staticDataReport(StaticData)
        /// Valid framing but a type this decoder does not interpret.
        case unsupported
    }

    public struct PositionReport: Sendable, Hashable {
        public var navigationStatus: NavigationStatus?
        public var rateOfTurn: RateOfTurn?
        /// Knots; nil when not available. 102.2 means "102.2 kn or more".
        public var speedOverGround: Double?
        public var positionAccuracyHigh: Bool
        public var position: GeoCoordinate?
        /// Degrees true; nil when not available.
        public var courseOverGround: Double?
        /// Degrees true; nil when not available.
        public var trueHeading: Int?
        /// UTC second of the report (0–59); nil when unavailable or the EPFD is degraded.
        public var timestampSecond: Int?
        public var raim: Bool
        public var isClassB: Bool
    }

    /// Identity and dimensions. Fields absent from a given message type are nil.
    public struct StaticData: Sendable, Hashable {
        public var name: String?
        public var callSign: String?
        public var imo: Int?
        public var shipType: Int?
        public var dimensions: Dimensions?
        /// Type 24 part number (0 = A, 1 = B), nil for other types.
        public var part: Int?
        public var vendorID: String?
        /// MMSI of the mother ship, for auxiliary craft (MMSI 98xxxxxxx).
        public var mothershipMMSI: Int?

        public init(name: String? = nil, callSign: String? = nil, imo: Int? = nil, shipType: Int? = nil,
                    dimensions: Dimensions? = nil, part: Int? = nil, vendorID: String? = nil, mothershipMMSI: Int? = nil) {
            self.name = name; self.callSign = callSign; self.imo = imo; self.shipType = shipType
            self.dimensions = dimensions; self.part = part; self.vendorID = vendorID; self.mothershipMMSI = mothershipMMSI
        }
    }

    /// Distances (metres) from the GNSS antenna to the bow, stern, port and starboard.
    public struct Dimensions: Sendable, Hashable {
        public var toBow: Int, toStern: Int, toPort: Int, toStarboard: Int
        public var length: Int { toBow + toStern }
        public var beam: Int { toPort + toStarboard }
        public var isKnown: Bool { length > 0 }
    }

    public struct Voyage: Sendable, Hashable {
        /// Static draught, metres.
        public var draught: Double?
        public var destination: String?
        /// ETA (month, day, hour, minute in UTC; no year in the message).
        public var etaMonth: Int?, etaDay: Int?, etaHour: Int?, etaMinute: Int?
    }

    public struct AidToNavigation: Sendable, Hashable {
        /// Table 74 type (1 reference point … 28 isolated danger, 30 special mark…).
        public var aidType: Int
        public var name: String
        public var position: GeoCoordinate?
        public var dimensions: Dimensions?
        public var offPosition: Bool
        public var isVirtual: Bool
    }

    public enum NavigationStatus: Int, Sendable, Hashable, CaseIterable {
        case underWayUsingEngine = 0, atAnchor, notUnderCommand, restrictedManoeuverability, constrainedByDraught,
             moored, aground, engagedInFishing, underWaySailing
        case aisSARTActive = 14
    }

    public enum RateOfTurn: Sendable, Hashable {
        /// Degrees per minute, positive to starboard.
        case degreesPerMinute(Double)
        /// Turning faster than 5° per 30 s with no turn indicator; `starboard` gives the direction.
        case fastTurn(starboard: Bool)
    }

    /// AIS-SART, MOB and EPIRB-AIS devices transmit from MMSI 970xxxxxx, 972xxxxxx and 974xxxxxx.
    public var isEmergencyDevice: Bool {
        let prefix = mmsi / 1_000_000
        return prefix == 970 || prefix == 972 || prefix == 974
    }
}

extension AISMessage {
    public enum DecodeError: Error, Sendable, Hashable {
        case tooShort(type: Int, bits: Int)
    }

    /// Decodes a reassembled payload (see `AISAssembler`).
    public init(bits b: AISBits) throws {
        guard b.count >= 38 else { throw DecodeError.tooShort(type: -1, bits: b.count) }
        let type = Int(b.uint(0, 6))
        self.type = type
        repeatIndicator = Int(b.uint(6, 2))
        mmsi = Int(b.uint(8, 30))
        func need(_ n: Int) throws { if b.count < n { throw DecodeError.tooShort(type: type, bits: b.count) } }

        switch type {
        case 1, 2, 3:
            try need(149)
            body = .position(PositionReport(
                navigationStatus: NavigationStatus(rawValue: Int(b.uint(38, 4))),
                rateOfTurn: Self.rateOfTurn(Int(b.int(42, 8))),
                speedOverGround: Self.speed(b.uint(50, 10)),
                positionAccuracyHigh: b.bool(60),
                position: Self.position(b, lon: 61, lat: 89),
                courseOverGround: Self.course(b.uint(116, 12)),
                trueHeading: Self.heading(b.uint(128, 9)),
                timestampSecond: Self.second(b.uint(137, 6)),
                raim: b.bool(148), isClassB: false), staticData: nil)
        case 4, 11:
            try need(134)
            let c = DateComponents(year: Int(b.uint(38, 14)), month: Int(b.uint(52, 4)), day: Int(b.uint(56, 5)),
                                   hour: Int(b.uint(61, 5)), minute: Int(b.uint(66, 6)), second: Int(b.uint(72, 6)))
            let valid = (c.year ?? 0) > 0 && (1...12).contains(c.month ?? 0) && (1...31).contains(c.day ?? 0)
                && (c.hour ?? 99) < 24 && (c.minute ?? 99) < 60 && (c.second ?? 99) < 60
            body = .baseStation(date: valid ? NMEAMessage.utcCalendar.date(from: c) : nil, position: Self.position(b, lon: 79, lat: 107))
        case 5:
            try need(420) // some transmitters drop the final DTE/spare bits
            let stat = StaticData(name: b.text(112, 120), callSign: b.text(70, 42), imo: Self.nonZero(b.uint(40, 30)),
                                  shipType: Int(b.uint(232, 8)), dimensions: Self.dimensions(b, at: 240))
            let draught = b.uint(294, 8)
            let voyage = Voyage(draught: draught == 0 ? nil : Double(draught) / 10, destination: b.text(302, 120),
                                etaMonth: Self.nonZero(b.uint(274, 4)), etaDay: Self.nonZero(b.uint(278, 5)),
                                etaHour: b.uint(283, 5) < 24 ? Int(b.uint(283, 5)) : nil,
                                etaMinute: b.uint(288, 6) < 60 ? Int(b.uint(288, 6)) : nil)
            body = .staticAndVoyage(stat, voyage)
        case 18, 19:
            try need(type == 18 ? 148 : 301)
            let report = PositionReport(
                navigationStatus: nil, rateOfTurn: nil,
                speedOverGround: Self.speed(b.uint(46, 10)),
                positionAccuracyHigh: b.bool(56),
                position: Self.position(b, lon: 57, lat: 85),
                courseOverGround: Self.course(b.uint(112, 12)),
                trueHeading: Self.heading(b.uint(124, 9)),
                timestampSecond: Self.second(b.uint(133, 6)),
                raim: b.bool(type == 18 ? 147 : 305), isClassB: true)
            var stat: StaticData?
            if type == 19 {
                stat = StaticData(name: b.text(143, 120), shipType: Int(b.uint(263, 8)), dimensions: Self.dimensions(b, at: 271))
            }
            body = .position(report, staticData: stat)
        case 21:
            try need(271)
            var name = b.text(43, 120)
            if b.count > 272 {
                let extBits = (b.count - 272) / 6 * 6
                name += b.text(272, extBits)
            }
            body = .aidToNavigation(AidToNavigation(aidType: Int(b.uint(38, 5)), name: name,
                                                    position: Self.position(b, lon: 164, lat: 192),
                                                    dimensions: Self.dimensions(b, at: 219),
                                                    offPosition: b.bool(259), isVirtual: b.bool(269)))
        case 24:
            try need(40)
            let part = Int(b.uint(38, 2))
            if part == 0 {
                try need(160)
                body = .staticDataReport(StaticData(name: b.text(40, 120), part: 0))
            } else {
                try need(162)
                let auxiliary = mmsi / 10_000_000 == 98
                body = .staticDataReport(StaticData(callSign: b.text(90, 42), shipType: Int(b.uint(40, 8)),
                                                    dimensions: auxiliary ? nil : Self.dimensions(b, at: 132), part: part,
                                                    vendorID: b.text(48, 18),
                                                    mothershipMMSI: auxiliary ? Int(b.uint(132, 30)) : nil))
            }
        default:
            body = .unsupported
        }
    }

    // MARK: Field conversions

    static func position(_ b: AISBits, lon: Int, lat: Int) -> GeoCoordinate? {
        let x = Double(b.int(lon, 28)) / 600_000, y = Double(b.int(lat, 27)) / 600_000
        guard abs(x) <= 180, abs(y) <= 90 else { return nil } // 181° / 91° mean "not available"
        return GeoCoordinate(latitude: y, longitude: x)
    }

    static func speed(_ raw: UInt64) -> Double? { raw == 1023 ? nil : Double(raw) / 10 }
    static func course(_ raw: UInt64) -> Double? { raw >= 3600 ? nil : Double(raw) / 10 }
    static func heading(_ raw: UInt64) -> Int? { raw > 359 ? nil : Int(raw) }
    static func second(_ raw: UInt64) -> Int? { raw > 59 ? nil : Int(raw) }
    static func nonZero(_ raw: UInt64) -> Int? { raw == 0 ? nil : Int(raw) }

    static func rateOfTurn(_ raw: Int) -> RateOfTurn? {
        switch raw {
        case -128: return nil
        case 127: return .fastTurn(starboard: true)
        case -127: return .fastTurn(starboard: false)
        default:
            let r = Double(raw) / 4.733
            return .degreesPerMinute(raw < 0 ? -r * r : r * r)
        }
    }

    static func dimensions(_ b: AISBits, at i: Int) -> Dimensions {
        Dimensions(toBow: Int(b.uint(i, 9)), toStern: Int(b.uint(i + 9, 9)),
                   toPort: Int(b.uint(i + 18, 6)), toStarboard: Int(b.uint(i + 24, 6)))
    }
}

/// Line-at-a-time AIS decoding: NMEA framing, fragment reassembly, message decoding.
public struct AISDecoder: Sendable {
    public private(set) var assembler = AISAssembler()
    public init() {}

    /// Returns the decoded message when `line` completes one; nil for an intermediate
    /// fragment. Throws on framing or decoding errors.
    public mutating func decode(line: some StringProtocol, at now: Date = Date()) throws -> (message: AISMessage, isOwnShip: Bool)? {
        let s = try NMEASentence(line)
        let f = try AISFragment(s)
        guard let (bits, own) = assembler.add(f, at: now) else { return nil }
        return (try AISMessage(bits: bits), own)
    }
}
