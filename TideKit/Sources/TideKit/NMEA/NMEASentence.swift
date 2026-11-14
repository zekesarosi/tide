import Foundation

/// One NMEA 0183 sentence, split into fields.
///
/// Accepts parametric (`$`) and encapsulated (`!`, e.g. AIS `!AIVDM`) sentences, an
/// optional NMEA 4.10 / IEC 61162-450 tag block (`\s:src,c:1700000000*hh\`) in front,
/// and an optional `*hh` checksum, which is verified whenever it is present.
public struct NMEASentence: Sendable, Hashable {
    public enum ParseError: Error, Sendable, Hashable {
        case empty
        /// The sentence does not start with `$` or `!`.
        case badStart
        case badChecksum(expected: UInt8, actual: UInt8)
        case missingChecksum
        case malformed(String)
    }

    /// The sentence as received, without the tag block or line ending.
    public let raw: String
    /// True for `!` sentences (encapsulated data such as AIS).
    public let isEncapsulated: Bool
    /// Two-letter talker (`GP`, `GN`, `II`, `AI`...), or `P` for proprietary sentences.
    public let talker: String
    /// Sentence formatter (`RMC`, `VDM`...). For proprietary sentences, the manufacturer
    /// code and sentence (`GRMZ`, `SRDF`...).
    public let formatter: String
    /// Data fields after the address field. Empty strings are null fields.
    public let fields: [String]
    /// Tag-block parameters (`s` source, `c` UNIX time, `g` group...), if present.
    public let tagBlock: [String: String]

    /// - Parameter requireChecksum: reject sentences without `*hh`. NMEA 0183 makes the
    ///   checksum optional for some sentences, but every modern device sends it.
    public init(_ line: some StringProtocol, requireChecksum: Bool = false) throws {
        var s = Substring(line).trimmingCharacters(in: .whitespacesAndNewlines)[...]
        guard !s.isEmpty else { throw ParseError.empty }
        var tags: [String: String] = [:]
        if s.first == "\\" {
            let body = s.dropFirst()
            guard let close = body.firstIndex(of: "\\") else { throw ParseError.malformed("unterminated tag block") }
            var block = body[..<close]
            if let star = block.lastIndex(of: "*") { block = block[..<star] }
            for kv in block.split(separator: ",") {
                let parts = kv.split(separator: ":", maxSplits: 1)
                if parts.count == 2 { tags[String(parts[0])] = String(parts[1]) }
            }
            s = body[body.index(after: close)...]
        }
        guard let start = s.first, start == "$" || start == "!" else { throw ParseError.badStart }

        var body = s.dropFirst()
        if let star = body.lastIndex(of: "*") {
            let hex = body[body.index(after: star)...]
            guard hex.count == 2, let expected = UInt8(hex, radix: 16) else { throw ParseError.malformed("bad checksum field") }
            body = body[..<star]
            let actual = Self.checksum(body)
            guard actual == expected else { throw ParseError.badChecksum(expected: expected, actual: actual) }
        } else if requireChecksum {
            throw ParseError.missingChecksum
        }

        var parts = body.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard let address = parts.first, address.count >= 3, address.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            throw ParseError.malformed("bad address field")
        }
        parts.removeFirst()
        if address.hasPrefix("P") {
            talker = "P"
            formatter = String(address.dropFirst())
        } else {
            guard address.count == 5 else { throw ParseError.malformed("bad address field") }
            talker = String(address.prefix(2))
            formatter = String(address.dropFirst(2))
        }
        raw = String(s)
        isEncapsulated = start == "!"
        fields = parts
        tagBlock = tags
    }

    /// XOR of every character between the start delimiter and `*`.
    public static func checksum(_ body: some StringProtocol) -> UInt8 {
        body.utf8.reduce(0) { $0 ^ $1 }
    }

    /// Builds a sentence with its checksum, e.g. `make("$", "GPRMC,...")`.
    public static func make(_ start: Character = "$", _ body: String) -> String {
        String(start) + body + String(format: "*%02X", checksum(body))
    }

    // MARK: Field access

    public func string(_ i: Int) -> String? {
        fields.indices.contains(i) && !fields[i].isEmpty ? fields[i] : nil
    }

    public func double(_ i: Int) -> Double? { string(i).flatMap(Double.init) }
    public func int(_ i: Int) -> Int? { string(i).flatMap { Int($0) } }

    /// A latitude or longitude written `ddmm.mmmm` / `dddmm.mmmm` followed by its hemisphere.
    public func coordinateComponent(_ i: Int) -> Double? {
        guard let v = string(i), let hemi = string(i + 1), let dot = Double(v) else { return nil }
        let degrees = (dot / 100).rounded(.towardZero)
        let minutes = dot - degrees * 100
        guard minutes >= 0, minutes < 60 else { return nil }
        let value = degrees + minutes / 60
        switch hemi {
        case "N", "E": return value
        case "S", "W": return -value
        default: return nil
        }
    }

    /// Latitude at `i`, `i+1` and longitude at `i+2`, `i+3`.
    public func coordinate(_ i: Int) -> GeoCoordinate? {
        guard let lat = coordinateComponent(i), let lon = coordinateComponent(i + 2), abs(lat) <= 90, abs(lon) <= 180 else { return nil }
        return GeoCoordinate(latitude: lat, longitude: lon)
    }

    /// UTC time of day `hhmmss.ss`, as seconds since midnight.
    public func timeOfDay(_ i: Int) -> TimeInterval? {
        guard let v = string(i), v.count >= 6 else { return nil }
        let chars = Array(v)
        guard let h = Int(String(chars[0...1])), let m = Int(String(chars[2...3])),
              let sec = Double(String(chars[4...])), h < 24, m < 60, sec < 61 else { return nil }
        return Double(h * 3_600 + m * 60) + sec
    }
}

/// Splits a byte or text stream (TCP, UDP or serial) into NMEA lines. Lines may be
/// terminated by CR LF, LF or CR; partial lines are held until they are completed.
public struct NMEALineSplitter: Sendable {
    private var buffer = ""
    /// Lines longer than this are discarded (NMEA allows 82 characters; tag blocks and
    /// some devices go further).
    public var maxLineLength = 1_024

    public init() {}

    /// Appends received text and returns every completed, non-empty line.
    public mutating func append(_ text: String) -> [String] {
        buffer += text
        var lines: [String] = []
        while let r = buffer.firstIndex(where: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) {
            let line = String(buffer[..<r])
            buffer = String(buffer[buffer.index(after: r)...])
            if !line.isEmpty, line.count <= maxLineLength { lines.append(line) }
        }
        if buffer.count > maxLineLength { buffer = "" }
        return lines
    }

    public mutating func append(_ data: Data) -> [String] {
        append(String(decoding: data, as: UTF8.self))
    }
}
