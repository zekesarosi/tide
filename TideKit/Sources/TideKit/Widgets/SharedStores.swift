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

    public func save(_ snapshot: ForecastSnapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        // NaN marks gaps in the curves; encode it explicitly.
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        try encoder.encode(snapshot).write(to: url(for: snapshot.stationID), options: .atomic)
    }

    public func load(stationID: String) -> ForecastSnapshot? {
        guard let data = try? Data(contentsOf: url(for: stationID)) else { return nil }
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        guard let s = try? decoder.decode(ForecastSnapshot.self, from: data), s.version == ForecastSnapshot.currentVersion else { return nil }
        return s
    }

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
