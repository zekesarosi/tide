import Foundation

/// Responses kept on disk across launches and shared between processes (the
/// app and its widget extension point it at the same App Group folder), so
/// slow-changing data (harmonic constants, datums, flood levels, tide-table
/// predictions, the weather model run) is downloaded once per expiry by
/// whichever process asks first, not once per process per launch.
///
/// Each entry is a file named by a hash of the request key, holding a small
/// header (expiry and time-to-live), the key itself (checked on read, so a
/// hash collision is a miss, never the wrong response) and the body. Keeping
/// the expiry in the file avoids reading file timestamps. Plain Foundation,
/// so it builds on Linux too.
public struct DiskResponseCache: Sendable {
    public let directory: URL

    /// Only responses that stay valid at least this long are written to
    /// disk; shorter-lived ones (live observations, alerts) would just churn.
    public static let minimumTTL: TimeInterval = 15 * 60

    /// Entries whose time-to-live is under this count as volatile: a manual
    /// refresh drops them but keeps the slow-changing reference data.
    public static let volatileTTL: TimeInterval = 86_400

    private static let headerSize = 16

    public init(directory: URL) { self.directory = directory }

    func file(for key: String) -> URL {
        // FNV-1a, 64-bit: stable across launches and platforms (unlike `Hasher`).
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return directory.appendingPathComponent(String(format: "%016llx", hash))
    }

    /// The body stored for `key` if it hasn't expired.
    public func read(_ key: String, now: Date = Date()) -> Data? {
        guard let data = try? Data(contentsOf: file(for: key)), let h = Self.header(data),
              h.expires > now.timeIntervalSince1970 else { return nil }
        let rest = data.dropFirst(Self.headerSize)
        let keyBytes = Data(key.utf8)
        guard rest.count >= 4 else { return nil }
        let length = rest.prefix(4).enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        guard length == keyBytes.count, rest.dropFirst(4).prefix(length).elementsEqual(keyBytes) else { return nil }
        return Data(rest.dropFirst(4 + length))
    }

    public func write(_ body: Data, for key: String, ttl: TimeInterval, now: Date = Date()) {
        guard ttl >= Self.minimumTTL else { return }
        var out = Data(capacity: Self.headerSize + body.count)
        withUnsafeBytes(of: (now.timeIntervalSince1970 + ttl).bitPattern.littleEndian) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: ttl.bitPattern.littleEndian) { out.append(contentsOf: $0) }
        let keyBytes = Data(key.utf8)
        withUnsafeBytes(of: UInt32(keyBytes.count).littleEndian) { out.append(contentsOf: $0) }
        out.append(keyBytes)
        out.append(body)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? out.write(to: file(for: key), options: .atomic)
    }

    /// Delete expired entries, and with `volatileOnly` every short-lived one.
    public func prune(volatileOnly: Bool = false, now: Date = Date()) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names {
            let url = directory.appendingPathComponent(name)
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            let head = (try? handle.read(upToCount: Self.headerSize)) ?? Data()
            try? handle.close()
            guard let h = Self.header(head) else { try? fm.removeItem(at: url); continue }
            if h.expires <= now.timeIntervalSince1970 || (volatileOnly && h.ttl < Self.volatileTTL) {
                try? fm.removeItem(at: url)
            }
        }
    }

    public func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    private static func header(_ data: Data) -> (expires: Double, ttl: Double)? {
        guard data.count >= headerSize else { return nil }
        let bytes = [UInt8](data.prefix(headerSize))
        func double(_ offset: Int) -> Double {
            var bits: UInt64 = 0
            for i in 0..<8 { bits |= UInt64(bytes[offset + i]) << (8 * UInt64(i)) }
            return Double(bitPattern: bits)
        }
        return (double(0), double(8))
    }
}
