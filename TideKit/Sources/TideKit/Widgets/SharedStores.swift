import Foundation

/// Stores one `ForecastSnapshot` per station as JSON files in a directory
/// (the App Group container, shared by the app and its widget extension).
public struct ForecastSnapshotStore: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    func url(for stationID: String) -> URL {
        let safe = stationID.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }
        return directory.appendingPathComponent("snapshot-\(String(safe)).json")
    }

    /// Save `snapshot` unless the store already holds a newer one for the
    /// station. The app and the widget extension both write here, so the
    /// check and the write are coordinated across processes: the newest
    /// forecast always wins, whoever finished last. Returns whether it was saved.
    @discardableResult
    public func save(_ snapshot: ForecastSnapshot) throws -> Bool {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        // NaN marks gaps in the curves; encode it explicitly.
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        let data = try encoder.encode(snapshot)
        func writeIfNewer(_ target: URL) -> Result<Bool, Error> {
            if let existing = Self.decode(at: target), existing.issued > snapshot.issued { return .success(false) }
            return Result { try data.write(to: target, options: .atomic); return true }
        }
        #if canImport(Darwin)
        var coordinationError: NSError?
        var outcome: Result<Bool, Error> = .success(false)
        NSFileCoordinator().coordinate(writingItemAt: url(for: snapshot.stationID), options: .forReplacing,
                                       error: &coordinationError) { outcome = writeIfNewer($0) }
        if let coordinationError { throw coordinationError }
        return try outcome.get()
        #else
        // No app extensions here, so no other process to coordinate with.
        return try writeIfNewer(url(for: snapshot.stationID)).get()
        #endif
    }

    static func decode(at url: URL) -> ForecastSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        guard let s = try? decoder.decode(ForecastSnapshot.self, from: data), s.version == ForecastSnapshot.currentVersion else { return nil }
        return s
    }

    public func load(stationID: String) -> ForecastSnapshot? { Self.decode(at: url(for: stationID)) }

    public func remove(stationID: String) {
        try? FileManager.default.removeItem(at: url(for: stationID))
    }
}

/// The station list, cached on disk so launch, widgets and the widget
/// station picker work offline.
public struct StationCatalogCache: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    struct File: Codable {
        var saved: Date
        var stations: [Station]
    }

    public func load() -> (saved: Date, stations: [Station])? {
        guard let data = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(File.self, from: data) else { return nil }
        return (f.saved, f.stations)
    }

    public func save(_ stations: [Station], at date: Date = Date()) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(File(saved: date, stations: stations)).write(to: url, options: .atomic)
    }
}
