import Foundation

/// Decoded NMEA 0183 sentences used by a navigation app. Values are SI-free on purpose:
/// they keep the units the instrument sends (knots, degrees, metres), as named.
public enum NMEAMessage: Sendable, Hashable {
    /// RMC: recommended minimum GNSS data.
    case rmc(RMC)
    /// GGA: GNSS fix data.
    case gga(GGA)
    /// GLL: geographic position.
    case gll(GLL)
    /// VTG: course and speed over ground.
    case vtg(VTG)
    /// HDG (heading, deviation, variation), HDT (true) or HDM (magnetic).
    case heading(Heading)
    /// MWV: wind speed and angle (apparent/relative or true/theoretical).
    case wind(Wind)
    /// DBT, DPT: depth.
    case depth(Depth)
    /// VHW: water speed and heading.
    case waterSpeed(WaterSpeed)
    /// MTW: water temperature, °C.
    case waterTemperature(Double)
    /// XTE: cross-track error.
    case crossTrackError(CrossTrackError)
    /// RMB: recommended minimum navigation information (to the active waypoint).
    case rmb(RMB)
    /// ZDA: UTC date and time.
    case zda(Date)
    /// VDM/VDO: one AIS radio-message fragment.
    case ais(AISFragment)
    /// A sentence this decoder does not interpret.
    case other(NMEASentence)

    public struct RMC: Sendable, Hashable {
        public var date: Date?
        public var isValid: Bool
        public var position: GeoCoordinate?
        /// Knots.
        public var speedOverGround: Double?
        /// Degrees true.
        public var courseOverGround: Double?
        /// Degrees, east positive.
        public var magneticVariation: Double?
    }

    public struct GGA: Sendable, Hashable {
        /// Seconds since UTC midnight.
        public var timeOfDay: TimeInterval?
        public var position: GeoCoordinate?
        /// 0 invalid, 1 GPS, 2 DGPS, 4 RTK fixed, 5 RTK float, 6 dead reckoning...
        public var fixQuality: Int
        public var satellites: Int?
        public var hdop: Double?
        /// Antenna altitude above mean sea level, metres.
        public var altitude: Double?
        public var hasFix: Bool { fixQuality > 0 && fixQuality != 6 && position != nil }
    }

    public struct GLL: Sendable, Hashable {
        public var position: GeoCoordinate?
        public var timeOfDay: TimeInterval?
        public var isValid: Bool
    }

    public struct VTG: Sendable, Hashable {
        public var courseTrue: Double?
        public var courseMagnetic: Double?
        /// Knots.
        public var speedKnots: Double?
    }

    public struct Heading: Sendable, Hashable {
        public enum Reference: String, Sendable, Hashable { case `true` = "T", magnetic = "M" }
        public var degrees: Double
        public var reference: Reference
        /// Deviation and variation (HDG), degrees east positive.
        public var deviation: Double?
        public var variation: Double?

        /// True heading, applying deviation and variation when the sentence carries them.
        public var trueHeading: Double? {
            if reference == .true { return degrees }
            guard let variation else { return nil }
            return Navigation.wrap360(degrees + (deviation ?? 0) + variation)
        }
    }

    public struct Wind: Sendable, Hashable {
        /// Degrees, relative to the bow (apparent/relative, `R`) or true (`T`), clockwise.
        public var angle: Double
        public var isRelative: Bool
        /// Knots (converted from km/h or m/s when the sentence uses those).
        public var speedKnots: Double
    }

    public struct Depth: Sendable, Hashable {
        /// Below the transducer, metres.
        public var belowTransducer: Double
        /// DPT offset: positive to the waterline, negative to the keel.
        public var offset: Double?
        /// Depth below the waterline (positive offset) or the keel (negative), metres.
        public var adjusted: Double? { offset.map { belowTransducer + $0 } }
    }

    public struct WaterSpeed: Sendable, Hashable {
        public var headingTrue: Double?
        public var headingMagnetic: Double?
        /// Speed through the water, knots.
        public var speedKnots: Double?
    }

    public struct CrossTrackError: Sendable, Hashable {
        /// Nautical miles. Positive: steer right (the boat is left of track).
        public var steerRightNauticalMiles: Double
        public var isValid: Bool
    }

    public struct RMB: Sendable, Hashable {
        public var isValid: Bool
        public var crossTrack: CrossTrackError?
        public var originID: String?
        public var destinationID: String?
        public var destination: GeoCoordinate?
        /// Nautical miles.
        public var rangeToDestination: Double?
        /// Degrees true.
        public var bearingToDestination: Double?
        /// Knots, positive when closing.
        public var closingVelocity: Double?
        public var arrived: Bool
    }
}

extension NMEAMessage {
    /// Parses one line. Throws for framing errors (bad checksum, garbage); sentences
    /// that frame correctly but are not understood come back as `.other`.
    public static func parse(_ line: some StringProtocol) throws -> NMEAMessage {
        try decode(NMEASentence(line))
    }

    public static func decode(_ s: NMEASentence) throws -> NMEAMessage {
        switch s.formatter {
        case "RMC":
            // hhmmss,A,lat,N,lon,W,sog,cog,ddmmyy,var,E[,mode[,nav status]]
            let valid = s.string(1) == "A" && s.string(11) != "N"
            var variation = s.double(9)
            if s.string(10) == "W", let v = variation { variation = -v }
            return .rmc(RMC(date: Self.date(ddmmyy: s.string(8), timeOfDay: s.timeOfDay(0)), isValid: valid,
                            position: s.coordinate(2), speedOverGround: s.double(6), courseOverGround: s.double(7),
                            magneticVariation: variation))
        case "GGA":
            return .gga(GGA(timeOfDay: s.timeOfDay(0), position: s.coordinate(1), fixQuality: s.int(5) ?? 0,
                            satellites: s.int(6), hdop: s.double(7), altitude: s.double(8)))
        case "GLL":
            return .gll(GLL(position: s.coordinate(0), timeOfDay: s.timeOfDay(4), isValid: s.string(5) == "A" && s.string(6) != "N"))
        case "VTG":
            // Modern: cogT,T,cogM,M,sogN,N,sogK,K[,mode]. Legacy (pre-2.3) has no unit letters.
            if s.string(1) == "T" || s.string(3) == "M" || s.string(5) == "N" {
                let kn = s.double(4) ?? s.double(6).map { $0 / 1.852 }
                return .vtg(VTG(courseTrue: s.double(0), courseMagnetic: s.double(2), speedKnots: kn))
            }
            return .vtg(VTG(courseTrue: s.double(0), courseMagnetic: s.double(1), speedKnots: s.double(2)))
        case "HDG":
            guard let h = s.double(0) else { throw NMEASentence.ParseError.malformed("HDG without heading") }
            return .heading(Heading(degrees: h, reference: .magnetic,
                                    deviation: signed(s.double(1), s.string(2)), variation: signed(s.double(3), s.string(4))))
        case "HDT", "HDM":
            guard let h = s.double(0) else { throw NMEASentence.ParseError.malformed("\(s.formatter) without heading") }
            return .heading(Heading(degrees: h, reference: s.formatter == "HDT" ? .true : .magnetic))
        case "MWV":
            // angle,R|T,speed,K|M|N|S,A
            guard s.string(4) == "A", let angle = s.double(0), let speed = s.double(2) else {
                throw NMEASentence.ParseError.malformed("MWV invalid")
            }
            let knots: Double
            switch s.string(3) {
            case "K": knots = speed / 1.852
            case "M": knots = Navigation.knots(fromMetersPerSecond: speed)
            default: knots = speed // N (and S, statute mph, is obsolete)
            }
            return .wind(Wind(angle: angle, isRelative: s.string(1) != "T", speedKnots: knots))
        case "DBT":
            // feet,f,metres,M,fathoms,F
            let metres = s.double(2) ?? s.double(0).map { $0 * LengthUnit.metersPerFoot } ?? s.double(4).map { $0 * 1.8288 }
            guard let m = metres else { throw NMEASentence.ParseError.malformed("DBT without depth") }
            return .depth(Depth(belowTransducer: m, offset: nil))
        case "DPT":
            guard let d = s.double(0) else { throw NMEASentence.ParseError.malformed("DPT without depth") }
            return .depth(Depth(belowTransducer: d, offset: s.double(1)))
        case "VHW":
            let kn = s.double(4) ?? s.double(6).map { $0 / 1.852 }
            return .waterSpeed(WaterSpeed(headingTrue: s.double(0), headingMagnetic: s.double(2), speedKnots: kn))
        case "MTW":
            guard let t = s.double(0) else { throw NMEASentence.ParseError.malformed("MTW without temperature") }
            return .waterTemperature(t)
        case "XTE":
            guard let x = crossTrack(s, magnitude: 2, direction: 3, status: 0, status2: 1) else {
                throw NMEASentence.ParseError.malformed("XTE without distance")
            }
            return .crossTrackError(x)
        case "RMB":
            // A,xte,L|R,origin,dest,lat,N,lon,W,range,bearing,vel,arrived[,mode]
            return .rmb(RMB(isValid: s.string(0) == "A", crossTrack: crossTrack(s, magnitude: 1, direction: 2, status: 0, status2: nil),
                            originID: s.string(3), destinationID: s.string(4), destination: s.coordinate(5),
                            rangeToDestination: s.double(9), bearingToDestination: s.double(10), closingVelocity: s.double(11),
                            arrived: s.string(12) == "A"))
        case "ZDA":
            guard let tod = s.timeOfDay(0), let d = s.int(1), let m = s.int(2), let y = s.int(3),
                  let midnight = utcCalendar.date(from: DateComponents(year: y, month: m, day: d)) else {
                throw NMEASentence.ParseError.malformed("ZDA incomplete")
            }
            return .zda(midnight + tod)
        case "VDM", "VDO":
            return .ais(try AISFragment(s))
        default:
            return .other(s)
        }
    }

    static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// `ddmmyy` + seconds since midnight. Two-digit years pivot at 1980 (GPS epoch).
    static func date(ddmmyy: String?, timeOfDay: TimeInterval?) -> Date? {
        guard let v = ddmmyy, v.count == 6, let n = Int(v) else { return nil }
        let dd = n / 10_000, mm = (n / 100) % 100, yy = n % 100
        let year = yy < 80 ? 2000 + yy : 1900 + yy
        guard let midnight = utcCalendar.date(from: DateComponents(year: year, month: mm, day: dd)) else { return nil }
        return midnight + (timeOfDay ?? 0)
    }

    static func signed(_ v: Double?, _ hemi: String?) -> Double? {
        guard let v else { return nil }
        return hemi == "W" ? -v : v
    }

    static func crossTrack(_ s: NMEASentence, magnitude: Int, direction: Int, status: Int, status2: Int?) -> CrossTrackError? {
        guard let m = s.double(magnitude) else { return nil }
        var nm = m
        // XTE units field (index 4) can be K (km) in old devices; N is the norm.
        if s.formatter == "XTE", s.string(4) == "K" { nm = m / 1.852 }
        let valid = s.string(status) == "A" && (status2.map { s.string($0) == "A" } ?? true)
        return CrossTrackError(steerRightNauticalMiles: s.string(direction) == "L" ? -nm : nm, isValid: valid)
    }
}
