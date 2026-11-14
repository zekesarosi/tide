import Foundation

/// One `!AIVDM` (other vessels) or `!AIVDO` (own vessel) sentence: a fragment of an
/// AIS radio message (ITU-R M.1371-5, IEC 61162-1 encapsulation).
public struct AISFragment: Sendable, Hashable {
    public var fragmentCount: Int
    public var fragmentNumber: Int
    /// Sequential message id that links multi-fragment messages (0–9), nil for single fragments.
    public var sequenceID: Int?
    /// Radio channel `A`/`B` (or `1`/`2`), if given.
    public var channel: String?
    /// 6-bit ASCII armoured payload.
    public var payload: String
    /// Pad bits in the last character (0–5).
    public var fillBits: Int
    /// True for VDO (own ship).
    public var isOwnShip: Bool

    public init(_ s: NMEASentence) throws {
        guard s.formatter == "VDM" || s.formatter == "VDO" else { throw NMEASentence.ParseError.malformed("not VDM/VDO") }
        guard let count = s.int(0), let number = s.int(1), (1...9).contains(count), (1...count).contains(number),
              let payload = s.string(4) else {
            throw NMEASentence.ParseError.malformed("bad AIS fragment header")
        }
        guard payload.utf8.allSatisfy({ AISBits.sixBit($0) != nil }) else {
            throw NMEASentence.ParseError.malformed("bad AIS payload character")
        }
        fragmentCount = count
        fragmentNumber = number
        sequenceID = s.int(2)
        channel = s.string(3)
        self.payload = payload
        fillBits = s.int(5) ?? 0
        isOwnShip = s.formatter == "VDO"
    }
}

/// Reassembles multi-sentence AIS messages. Fragments of one message share a
/// sequential id and channel and arrive in order; anything incomplete for longer than
/// `timeout` is discarded, as is a group that is interrupted by an out-of-order fragment.
public struct AISAssembler: Sendable {
    struct Key: Hashable { let sequenceID: Int?; let channel: String?; let ownShip: Bool }
    struct Pending { var parts: [String]; var started: Date; let count: Int }

    private var pending: [Key: Pending] = [:]
    public var timeout: TimeInterval = 10

    public init() {}

    /// Feeds one fragment. Returns the complete payload bits once the last fragment arrives.
    public mutating func add(_ f: AISFragment, at now: Date = Date()) -> (bits: AISBits, isOwnShip: Bool)? {
        pending = pending.filter { now.timeIntervalSince($0.value.started) <= timeout }
        if f.fragmentCount == 1 {
            return AISBits(payload: f.payload, fillBits: f.fillBits).map { ($0, f.isOwnShip) }
        }
        let key = Key(sequenceID: f.sequenceID, channel: f.channel, ownShip: f.isOwnShip)
        if f.fragmentNumber == 1 {
            pending[key] = Pending(parts: [f.payload], started: now, count: f.fragmentCount)
            return nil
        }
        guard var p = pending[key], p.count == f.fragmentCount, p.parts.count == f.fragmentNumber - 1 else {
            pending[key] = nil
            return nil
        }
        p.parts.append(f.payload)
        if f.fragmentNumber < f.fragmentCount {
            pending[key] = p
            return nil
        }
        pending[key] = nil
        return AISBits(payload: p.parts.joined(), fillBits: f.fillBits).map { ($0, f.isOwnShip) }
    }
}

/// The de-armoured AIS bit string, with readers for the field types in ITU-R M.1371.
public struct AISBits: Sendable, Hashable {
    public let bits: [Bool]

    public init?(payload: String, fillBits: Int) {
        var out: [Bool] = []
        out.reserveCapacity(payload.utf8.count * 6)
        for c in payload.utf8 {
            guard let v = Self.sixBit(c) else { return nil }
            for i in stride(from: 5, through: 0, by: -1) { out.append((v >> UInt8(i)) & 1 == 1) }
        }
        let fill = max(0, min(5, fillBits))
        if fill > 0, out.count >= fill { out.removeLast(fill) }
        bits = out
    }

    /// Payload armour: '0'…'W' → 0…39, '`'…'w' → 40…63.
    static func sixBit(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...87: return c - 48
        case 96...119: return c - 56
        default: return nil
        }
    }

    public var count: Int { bits.count }

    /// Unsigned integer of `length` bits at `start`. Bits past the end read as zero, the
    /// way receivers treat short ("truncated") messages.
    public func uint(_ start: Int, _ length: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in start..<(start + length) { v = v << 1 | (i < bits.count && bits[i] ? 1 : 0) }
        return v
    }

    /// Two's-complement signed integer.
    public func int(_ start: Int, _ length: Int) -> Int64 {
        let u = uint(start, length)
        let sign: UInt64 = 1 << UInt64(length - 1)
        return u & sign != 0 ? Int64(bitPattern: u) - Int64(bitPattern: sign << 1) : Int64(u)
    }

    public func bool(_ start: Int) -> Bool { start < bits.count && bits[start] }

    /// 6-bit ASCII text, with `@` padding and trailing spaces removed.
    public func text(_ start: Int, _ length: Int) -> String {
        var s = ""
        var i = start
        while i + 6 <= start + length {
            let v = UInt8(uint(i, 6))
            s.append(Character(Unicode.Scalar(v < 32 ? v + 64 : v)))
            i += 6
        }
        if let at = s.firstIndex(of: "@") { s = String(s[..<at]) }
        while s.last == " " { s.removeLast() }
        return s
    }
}
