import Foundation

/// The recent gauge record per station, kept on disk (in the App Group, so
/// the app and widget share it) so a refresh downloads only what was
/// measured since the last one instead of the whole training window.
///
/// The surge model trains on about a month of observations; at 6-minute
/// resolution that is several requests and a few hundred kB, while the new
/// readings since a refresh 20 minutes ago are a handful of points.
public struct ObservationArchive: Sendable {
    public let directory: URL

    /// Re-request this much before the last stored reading: providers fill
    /// late readings in and revise preliminary ones.
    public static let overlap: TimeInterval = 2 * 3_600

    public init(directory: URL) { self.directory = directory }

    struct Entry: Codable {
        /// Start of the span the archive is complete for (gaps inside it are real gaps).
        var coveredFrom: Date
        var series: TimeSeries
    }

    /// Observations over `from...to`: the stored record plus a fetch of the
    /// tail, or a full fetch when nothing usable is stored. If the tail fetch
    /// fails, the stored record is returned (it's still the best training data).
    public func series(key: String, from: Date, to: Date,
                       fetch: @Sendable (Date, Date) async throws -> TimeSeries) async throws -> TimeSeries {
        let stored = load(key)
        guard let stored, stored.coveredFrom <= from + 3_600, let last = stored.series.last?.date, last > from else {
            let full = try await fetch(from, to)
            save(Entry(coveredFrom: from, series: full), key: key)
            return full
        }
        let tailStart = max(last - Self.overlap, from)
        let tail: TimeSeries
        do {
            tail = try await fetch(tailStart, to)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return stored.series.sliced(from: from, to: to)
        }
        // Keep stored points before the tail; the tail replaces the overlap.
        let head = stored.series.points.filter { $0.date >= from && $0.date < (tail.first?.date ?? .distantFuture) }
        let merged = TimeSeries(points: head + tail.points)
        save(Entry(coveredFrom: from, series: merged), key: key)
        return merged
    }

    func file(for key: String) -> URL {
        let safe = key.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }
        return directory.appendingPathComponent("obs-\(String(safe)).plist")
    }

    func load(_ key: String) -> Entry? {
        guard let data = try? Data(contentsOf: file(for: key)) else { return nil }
        return try? PropertyListDecoder().decode(Entry.self, from: data)
    }

    func save(_ entry: Entry, key: String) {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(entry) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file(for: key), options: .atomic)
    }
}
