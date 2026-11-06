import Foundation
import Observation
import TideKit

/// The Bay model's live layer: the latest SFBOFS non-tidal residual (surge,
/// wind, river flow), published as `sfbay.residual.deflate` by
/// `.github/workflows/sfbay-live.yml` (docs/SFBAY.md).
///
/// The URL comes from Info.plist `TideBayLiveURL` (Config/App.xcconfig,
/// overridden in Config/Secrets.xcconfig). Without it the store never touches
/// the network and the scene shows the tide alone. Every failure falls back to
/// the cached residual, or to none: the tide-only model always works.
@MainActor @Observable
final class BayLiveStore {
    /// The newest valid residual for the current mesh, or nil (tide only).
    private(set) var residual: BayResidual?
    /// One short line for the UI about the live layer's state.
    private(set) var statusText: String?

    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var lastAttempt: Date?
    @ObservationIgnored private let url: URL?
    @ObservationIgnored private let cacheURL: URL

    /// SFBOFS cycles run at 03/09/15/21 UTC; the workflow publishes ~1 h 40 m
    /// later. Allow a little more before expecting a cycle.
    static let publishDelay: TimeInterval = 2 * 3_600
    /// Don't ask again sooner than this when the expected cycle isn't up yet.
    static let retryInterval: TimeInterval = 15 * 60

    init() {
        url = Self.configuredURL()
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheURL = caches.appendingPathComponent("BayLive", isDirectory: true)
            .appendingPathComponent("sfbay.residual.deflate")
    }

    static func configuredURL(_ bundle: Bundle = .main) -> URL? {
        guard let s = (bundle.object(forInfoDictionaryKey: "TideBayLiveURL") as? String)?
                .trimmingCharacters(in: .whitespaces),
              !s.isEmpty, !s.contains("$("),
              let url = URL(string: s), url.scheme == "https" || url.scheme == "http" else { return nil }
        return url
    }

    /// The newest SFBOFS cycle that should be published by `now`.
    static func expectedCycle(at now: Date) -> Date {
        let sixHours = 6.0 * 3_600, offset = 3.0 * 3_600
        let t = now.timeIntervalSince1970 - publishDelay - offset
        return Date(timeIntervalSince1970: (t / sixHours).rounded(.down) * sixHours + offset)
    }

    /// Loads the cached residual, then downloads a newer one if a newer
    /// cycle should be out. Safe to call often; never throws or blocks.
    func refresh(mesh: TideMesh) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }

        if let r = residual, r.meshID != mesh.meshID || r.nodeCount != mesh.nodeCount { residual = nil }
        if residual == nil, let cached = await Self.load(contentsOf: cacheURL, mesh: mesh) {
            residual = cached
        }
        guard let url else {
            statusText = residual.map(Self.describe) ?? "Tide only"
            return
        }

        let now = Date()
        if let r = residual, r.cycle >= Self.expectedCycle(at: now) {
            statusText = Self.describe(r)
            return
        }
        if let last = lastAttempt, now.timeIntervalSince(last) < Self.retryInterval {
            return
        }
        lastAttempt = now

        switch await Self.download(url, mesh: mesh) {
        case .success(let (fresh, bytes)):
            if residual.map({ fresh.cycle > $0.cycle }) ?? true {
                residual = fresh
                Self.store(bytes, at: cacheURL)
            }
            statusText = residual.map(Self.describe)
        case .failure(let error):
            statusText = residual.map { Self.describe($0) + " (couldn't update)" }
                ?? "Tide only (live data unavailable)"
            #if DEBUG
            print("BayLive: \(error)")
            #endif
        }
    }

    // MARK: Helpers (off the main actor)

    enum Failure: Error {
        case http(Int)
        case decode(Error)
    }

    nonisolated private static func download(_ url: URL, mesh: TideMesh) async -> Result<(BayResidual, Data), Error> {
        do {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw Failure.http(http.statusCode) }
            return .success((try decode(data, mesh: mesh), data))
        } catch {
            return .failure(error)
        }
    }

    nonisolated private static func load(contentsOf file: URL, mesh: TideMesh) async -> BayResidual? {
        await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: file) else { return nil }
            return try? decode(data, mesh: mesh)
        }.value
    }

    /// Raw deflate (zlib wbits −15) → `BayResidual`, validated against `mesh`.
    nonisolated static func decode(_ compressed: Data, mesh: TideMesh) throws -> BayResidual {
        do {
            // Apple's `.zlib` algorithm is raw deflate (RFC 1951), no header.
            let raw = try (compressed as NSData).decompressed(using: .zlib) as Data
            return try BayResidual(data: raw, mesh: mesh)
        } catch {
            throw Failure.decode(error)
        }
    }

    nonisolated private static func store(_ data: Data, at file: URL) {
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }

    private static func describe(_ r: BayResidual) -> String {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "HH'z' MMM d"
        return "Live: NOAA SFBOFS \(f.string(from: r.cycle))"
    }
}
