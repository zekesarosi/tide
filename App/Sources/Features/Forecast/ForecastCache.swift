import Foundation
import TideKit

/// The last forecast built for each station, kept in memory for the session
/// and on disk (Caches) across launches, so a station opens instantly on what
/// the app already knows and refreshes in the background.
@MainActor
final class ForecastCache {
    static let shared = ForecastCache()

    private var memory: [String: ForecastResult] = [:]
    private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("forecasts", isDirectory: true)
    }

    /// In memory (this session) only; instant.
    func cached(_ station: Station) -> ForecastResult? { memory[station.id] }

    /// From disk, decoded off the main thread (a 90-day forecast is a few MB).
    func load(_ station: Station) async -> ForecastResult? {
        if let hit = memory[station.id] { return hit }
        let url = file(for: station)
        let result = await Task.detached(priority: .userInitiated) { () -> ForecastResult? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? PropertyListDecoder().decode(ForecastResult.self, from: data)
        }.value
        if let result, memory[station.id] == nil { memory[station.id] = result }
        return memory[station.id]
    }

    /// Keep `result` in memory now and write it to disk in the background.
    func store(_ result: ForecastResult, for station: Station) {
        memory[station.id] = result
        let url = file(for: station), dir = directory
        Task.detached(priority: .utility) {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            guard let data = try? encoder.encode(result) else { return }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    private func file(for station: Station) -> URL {
        let name = station.id.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }
        return directory.appendingPathComponent(String(name) + ".plist")
    }
}
