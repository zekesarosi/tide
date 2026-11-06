import Foundation

/// A global ocean tide atlas: gridded harmonic constants for the major
/// constituents, packed by `scripts/pack_globe_data.py` (NASA GOT4.10c, 0.5°).
///
/// Each grid cell stores the complex constant H·e^{iG} (metres, Greenwich
/// phase lag G) for each constituent, so the tide anywhere is
/// `Σ f·H·cos(V + u − G) = Σ f·[Hcos G·cos(V+u) + Hsin G·sin(V+u)]`.
/// The renderer evaluates that sum per pixel from `phasors(at:)`. The CPU path
/// feeds the same constants to `HarmonicPredictor`.
public struct TideAtlas: Sendable {
    public struct Constituent: Sendable, Hashable {
        public let name: String
        public let definition: ConstituentDefinition
        public var speed: Double { definition.speed }
    }

    public enum LoadError: Error, Equatable {
        case badHeader
        case unknownConstituent(String)
        case truncated
    }

    public let latitudeCount: Int
    public let longitudeCount: Int
    /// Latitude of row 0 and row spacing, degrees.
    public let latitudeStart: Double, latitudeStep: Double
    /// Longitude of column 0 and column spacing, degrees (columns wrap).
    public let longitudeStart: Double, longitudeStep: Double
    public let constituents: [Constituent]

    /// Raw float16 (re, im) pairs, constituent-major: what the GPU uploads.
    private let payload: Data
    /// The same values as Float, for sampling on the CPU.
    private let values: [Float]

    static let headerSize = 4 + 8 + 16

    public init(data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= Self.headerSize, bytes[0..<4] == [0x54, 0x41, 0x54, 0x4C] else { throw LoadError.badHeader } // "TATL"
        func u16(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o + 1]) << 8 }
        func f32(_ o: Int) -> Double {
            Double(Float(bitPattern: UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2]) << 16 | UInt32(bytes[o + 3]) << 24))
        }
        guard u16(4) == 1 else { throw LoadError.badHeader }
        latitudeCount = u16(6)
        longitudeCount = u16(8)
        let n = u16(10)
        latitudeStart = f32(12); latitudeStep = f32(16)
        longitudeStart = f32(20); longitudeStep = f32(24)
        var offset = 28
        var cons: [Constituent] = []
        for _ in 0..<n {
            guard offset + 8 <= bytes.count else { throw LoadError.truncated }
            let name = String(decoding: bytes[offset..<offset + 8], as: UTF8.self).trimmingCharacters(in: .whitespaces)
            guard let def = ConstituentCatalog.definition(named: name) else { throw LoadError.unknownConstituent(name) }
            cons.append(Constituent(name: name, definition: def))
            offset += 8
        }
        constituents = cons
        let count = n * latitudeCount * longitudeCount * 2
        guard bytes.count >= offset + count * 2 else { throw LoadError.truncated }
        payload = data.subdata(in: data.startIndex + offset..<data.startIndex + offset + count * 2)
        var v = [Float](repeating: 0, count: count)
        for i in 0..<count {
            v[i] = Self.halfToFloat(UInt16(bytes[offset + 2 * i]) | UInt16(bytes[offset + 2 * i + 1]) << 8)
        }
        values = v
    }

    /// Bytes per constituent grid in `halfFloatGrid` (rg16Float texels).
    public var gridByteCount: Int { latitudeCount * longitudeCount * 4 }

    /// The packed float16 (H cos G, H sin G) grid of one constituent, row 0 = southernmost.
    public func halfFloatGrid(_ index: Int) -> Data {
        let start = payload.startIndex + index * gridByteCount
        return payload.subdata(in: start..<start + gridByteCount)
    }

    /// Bilinearly interpolated (H cos G, H sin G) of constituent `index`.
    func complexConstant(_ index: Int, latitude: Double, longitude: Double) -> (re: Double, im: Double) {
        let fy = min(max((latitude - latitudeStart) / latitudeStep, 0), Double(latitudeCount - 1))
        var fx = (longitude - longitudeStart) / longitudeStep
        fx = fx.truncatingRemainder(dividingBy: Double(longitudeCount))
        if fx < 0 { fx += Double(longitudeCount) }
        let y0 = min(Int(fy), latitudeCount - 2), x0 = Int(fx) % longitudeCount
        let y1 = y0 + 1, x1 = (x0 + 1) % longitudeCount
        let ty = fy - Double(y0), tx = fx - Double(Int(fx))
        let base = index * latitudeCount * longitudeCount
        func at(_ y: Int, _ x: Int) -> (Double, Double) {
            let k = 2 * (base + y * longitudeCount + x)
            return (Double(values[k]), Double(values[k + 1]))
        }
        let a = at(y0, x0), b = at(y0, x1), c = at(y1, x0), d = at(y1, x1)
        let re = (a.0 * (1 - tx) + b.0 * tx) * (1 - ty) + (c.0 * (1 - tx) + d.0 * tx) * ty
        let im = (a.1 * (1 - tx) + b.1 * tx) * (1 - ty) + (c.1 * (1 - tx) + d.1 * tx) * ty
        return (re, im)
    }

    /// Harmonic constants at a point, ready for `HarmonicPredictor`.
    /// Empty where the atlas has no ocean.
    public func harmonicConstituents(latitude: Double, longitude: Double) -> [HarmonicConstituent] {
        let out = constituents.indices.compactMap { i -> HarmonicConstituent? in
            let (re, im) = complexConstant(i, latitude: latitude, longitude: longitude)
            let amp = (re * re + im * im).squareRoot()
            guard amp > 0.000_5 else { return nil }
            return HarmonicConstituent(name: constituents[i].name, amplitude: amp,
                                       phaseGMT: Angle.normalize(atan2(im, re).degrees), speed: constituents[i].speed)
        }
        return out.count == constituents.count ? out : []
    }

    /// Amplitude (m) and Greenwich phase lag (°) of one constituent at a point.
    public func constant(named name: String, latitude: Double, longitude: Double) -> (amplitude: Double, phase: Double)? {
        guard let i = constituents.firstIndex(where: { $0.name == name }) else { return nil }
        let (re, im) = complexConstant(i, latitude: latitude, longitude: longitude)
        return ((re * re + im * im).squareRoot(), Angle.normalize(atan2(im, re).degrees))
    }

    /// Per-constituent (f·cos(V+u), f·sin(V+u)) at `date`, in atlas order.
    /// Node factors follow `HarmonicPredictor` (evaluated at mid-year).
    public func phasors(at date: Date) -> [(cos: Double, sin: Double)] {
        HarmonicBasis.phasors(constituents.map(\.definition), at: date)
    }

    /// Model tide height (m above mean sea level) at a point and time.
    public func height(latitude: Double, longitude: Double, at date: Date) -> Double {
        let p = phasors(at: date)
        return constituents.indices.reduce(0) { sum, i in
            let (re, im) = complexConstant(i, latitude: latitude, longitude: longitude)
            return sum + re * p[i].cos + im * p[i].sin
        }
    }

    /// IEEE 754 half → single, without relying on `Float16` (unavailable on Intel macOS).
    static func halfToFloat(_ h: UInt16) -> Float {
        let sign = UInt32(h & 0x8000) << 16
        let exp = Int(h >> 10) & 0x1F
        let mant = UInt32(h & 0x03FF)
        if exp == 0 {
            if mant == 0 { return Float(bitPattern: sign) }
            let v = Float(mant) / 1024 * pow(2, -14)
            return sign == 0 ? v : -v
        }
        if exp == 31 { return Float(bitPattern: sign | 0x7F80_0000 | mant << 13) }
        return Float(bitPattern: sign | UInt32(exp - 15 + 127) << 23 | mant << 13)
    }
}

/// The time basis of the harmonic method: for each constituent,
/// (f·cos(V+u), f·sin(V+u)) at an instant, so that a constituent with
/// amplitude H and Greenwich lag G contributes `H cos G · c + H sin G · s`.
/// Node factors are evaluated at mid-year, as `HarmonicPredictor` does, so
/// constants fitted against this basis predict consistently with it.
public enum HarmonicBasis {
    public static func phasors(_ definitions: [ConstituentDefinition], at date: Date) -> [(cos: Double, sin: Double)] {
        let astro = AstronomicalArguments(date: date)
        let year = HarmonicPredictor.utcCalendar.component(.year, from: date)
        let nodal = AstronomicalArguments(date: HarmonicPredictor.midYear(of: year))
        return definitions.map { d in
            let (f, u) = d.nodalFactors(nodal)
            let arg = (d.equilibriumArgument(astro) + u).radians
            return (f * cos(arg), f * sin(arg))
        }
    }
}
