import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum APIError: Error, LocalizedError, Sendable, Equatable {
    case invalidURL(String)
    case http(source: DataSourceID, status: Int, message: String)
    /// The provider answered 200 but reported an application-level error
    /// (CO-OPS returns `{"error": {"message": ...}}`).
    case provider(source: DataSourceID, message: String)
    case decoding(source: DataSourceID, message: String)
    case missingCredential(CredentialKey)
    case unauthorized(source: DataSourceID)
    case rateLimited(source: DataSourceID, retryAfter: TimeInterval?)
    case network(source: DataSourceID, message: String)
    case misconfigured(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let s): return "Invalid URL: \(s)"
        case .http(let src, let status, let msg): return "\(DataSourceInfo.info(src).name) returned HTTP \(status). \(msg)"
        case .provider(let src, let msg): return "\(DataSourceInfo.info(src).name): \(msg)"
        case .decoding(let src, let msg): return "Unexpected response from \(DataSourceInfo.info(src).name): \(msg)"
        case .missingCredential(let k): return "\(k.displayName) is not set. Add it in Settings › Data Sources."
        case .unauthorized(let src): return "\(DataSourceInfo.info(src).name) rejected the credentials. Check the key in Settings."
        case .rateLimited(let src, _): return "\(DataSourceInfo.info(src).name) is rate limiting requests. Try again shortly."
        case .network(let src, let msg): return "Couldn't reach \(DataSourceInfo.info(src).name): \(msg)"
        case .misconfigured(let msg): return msg
        }
    }
}

/// Abstracts the HTTP stack so tests can inject canned responses.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 60
            config.requestCachePolicy = .reloadIgnoringLocalCacheData // we cache ourselves
            config.httpMaximumConnectionsPerHost = 4
            self.session = URLSession(configuration: config)
        }
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}

/// An outgoing request description. Credentials are attached by
/// `APIClient`, never by callers, so they can be redacted consistently.
public struct Endpoint: Sendable {
    public var source: DataSourceID
    public var url: URL
    public var headers: [String: String]
    /// How long a successful response may be served from cache.
    public var cacheTTL: TimeInterval
    /// Attach the source's credential (if the source uses one).
    public var credential: CredentialKey?
    public var credentialRequired: Bool

    public init(source: DataSourceID, url: URL, headers: [String: String] = [:], cacheTTL: TimeInterval = 0,
                credential: CredentialKey? = nil, credentialRequired: Bool = false) {
        self.source = source
        self.url = url
        self.headers = headers
        self.cacheTTL = cacheTTL
        self.credential = credential
        self.credentialRequired = credentialRequired
    }

    public static func build(_ source: DataSourceID, _ base: String, _ query: [String: String?] = [:],
                             cacheTTL: TimeInterval = 0) throws -> Endpoint {
        guard var c = URLComponents(string: base) else { throw APIError.invalidURL(base) }
        let items = query.compactMap { k, v in v.map { URLQueryItem(name: k, value: $0) } }.sorted { $0.name < $1.name }
        if !items.isEmpty { c.queryItems = (c.queryItems ?? []) + items }
        guard let url = c.url else { throw APIError.invalidURL(base) }
        return Endpoint(source: source, url: url, cacheTTL: cacheTTL)
    }
}

/// Shared HTTP client: identification headers, credentials, retries with
/// exponential backoff, per-host pacing, and a small TTL cache.
public actor APIClient {
    public nonisolated let identity: AppIdentity
    public nonisolated let credentials: CredentialStore
    let transport: HTTPTransport
    let maxAttempts: Int
    let baseBackoff: TimeInterval
    /// Minimum spacing between requests to the same host.
    let hostSpacing: [String: TimeInterval]

    private var lastRequestAt: [String: Date] = [:]
    private var cache: [String: (expires: Date, data: Data)] = [:]
    private var inFlight: [String: Task<Data, Error>] = [:]

    public init(identity: AppIdentity, credentials: CredentialStore, transport: HTTPTransport = URLSessionTransport(),
                maxAttempts: Int = 3, baseBackoff: TimeInterval = 1.0,
                hostSpacing: [String: TimeInterval] = APIClient.defaultHostSpacing) {
        self.identity = identity
        self.credentials = credentials
        self.transport = transport
        self.maxAttempts = maxAttempts
        self.baseBackoff = baseBackoff
        self.hostSpacing = hostSpacing
    }

    /// Conservative pacing for providers with published or observed limits.
    public static let defaultHostSpacing: [String: TimeInterval] = [
        "api-iwls.dfo-mpo.gc.ca": 0.35,  // DFO documents a few requests/second
        "api.weather.gov": 0.2,
        "admiraltyapi.azure-api.net": 0.25,
    ]

    public func clearCache() { cache.removeAll() }

    /// Fetch raw bytes, coalescing concurrent identical requests.
    public func data(for endpoint: Endpoint) async throws -> Data {
        let request = try authorize(endpoint)
        let key = Self.cacheKey(for: request)
        if endpoint.cacheTTL > 0, let hit = cache[key], hit.expires > Date() { return hit.data }
        if let task = inFlight[key] { return try await Self.awaitCancellable(task) }

        let task = Task { try await self.perform(request, source: endpoint.source) }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let data = try await Self.awaitCancellable(task)
        if endpoint.cacheTTL > 0 {
            if cache.count > 200 {
                let now = Date()
                cache = cache.filter { $0.value.expires > now }
            }
            cache[key] = (Date().addingTimeInterval(endpoint.cacheTTL), data)
        }
        return data
    }

    public func decode<T: Decodable>(_ type: T.Type, from endpoint: Endpoint, decoder: JSONDecoder = JSONDecoder()) async throws -> T {
        let data = try await data(for: endpoint)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decoding(source: endpoint.source, message: Self.describe(error))
        }
    }

    /// Await a request task while forwarding the caller's cancellation to it
    /// (an unstructured `Task` does not inherit cancellation), so timeouts
    /// such as the widget's actually stop network work.
    private static func awaitCancellable(_ task: Task<Data, Error>) async throws -> Data {
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    // MARK: - Internals

    func authorize(_ endpoint: Endpoint) throws -> URLRequest {
        var url = endpoint.url
        var headers = endpoint.headers
        headers["User-Agent"] = identity.userAgent
        if headers["Accept"] == nil { headers["Accept"] = "application/json" }

        if let key = endpoint.credential {
            let secret = credentials.secret(for: key)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let secret, !secret.isEmpty {
                switch DataSourceInfo.info(endpoint.source).auth {
                case .apiKeyHeader(let name, _):
                    headers[name] = secret
                case .apiKeyQuery(let name, _):
                    guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw APIError.invalidURL(url.absoluteString) }
                    c.queryItems = (c.queryItems ?? []).filter { $0.name != name } + [URLQueryItem(name: name, value: secret)]
                    guard let u = c.url else { throw APIError.invalidURL(url.absoluteString) }
                    url = u
                case .none, .identifyingUserAgent:
                    break
                }
            } else if endpoint.credentialRequired {
                throw APIError.missingCredential(key)
            }
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        return request
    }

    private func perform(_ request: URLRequest, source: DataSourceID) async throws -> Data {
        var attempt = 0
        while true {
            attempt += 1
            try await pace(request.url?.host)
            do {
                let (data, response) = try await transport.send(request)
                switch response.statusCode {
                case 200..<300:
                    return data
                case 401, 403:
                    // NWS returns 403 for missing/blocked User-Agent; keyed APIs for bad keys.
                    if source == .nwsAlerts {
                        throw APIError.http(source: source, status: response.statusCode,
                                            message: "Check the app contact/User-Agent configuration.")
                    }
                    throw APIError.unauthorized(source: source)
                case 429, 500..<600:
                    let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
                    if attempt < maxAttempts {
                        try await backoff(attempt: attempt, retryAfter: retryAfter)
                        continue
                    }
                    if response.statusCode == 429 { throw APIError.rateLimited(source: source, retryAfter: retryAfter) }
                    throw APIError.http(source: source, status: response.statusCode, message: Self.snippet(data))
                default:
                    throw APIError.http(source: source, status: response.statusCode, message: Self.snippet(data))
                }
            } catch let error as APIError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if attempt < maxAttempts {
                    try await backoff(attempt: attempt, retryAfter: nil)
                    continue
                }
                throw APIError.network(source: source, message: Self.redact(error.localizedDescription))
            }
        }
    }

    private func pace(_ host: String?) async throws {
        guard let host, let spacing = hostSpacing[host] else { return }
        let now = Date()
        if let last = lastRequestAt[host] {
            let wait = spacing - now.timeIntervalSince(last)
            if wait > 0 {
                lastRequestAt[host] = now.addingTimeInterval(wait)
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                return
            }
        }
        lastRequestAt[host] = now
    }

    private func backoff(attempt: Int, retryAfter: TimeInterval?) async throws {
        let exp = baseBackoff * pow(2, Double(attempt - 1))
        let delay = min(retryAfter ?? exp * Double.random(in: 0.8...1.2), 30)
        try await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000))
    }

    /// Cache key with credentials removed so secrets never sit in memory twice
    /// or appear in diagnostics.
    static func cacheKey(for request: URLRequest) -> String {
        redact(request.url?.absoluteString ?? "")
    }

    static let secretQueryNames: Set<String> = ["apikey", "api_key", "key", "token", "subscription-key"]

    static func redact(_ s: String) -> String {
        guard var c = URLComponents(string: s), let items = c.queryItems, !items.isEmpty else { return s }
        c.queryItems = items.map { secretQueryNames.contains($0.name.lowercased()) ? URLQueryItem(name: $0.name, value: "REDACTED") : $0 }
        return c.string ?? s
    }

    static func snippet(_ data: Data) -> String {
        let s = String(decoding: data.prefix(300), as: UTF8.self)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? DecodingError {
            switch e {
            case .keyNotFound(let k, let ctx): return "missing key '\(k.stringValue)' at \(ctx.codingPath.map(\.stringValue).joined(separator: "."))"
            case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx), .dataCorrupted(let ctx):
                return "\(ctx.debugDescription) at \(ctx.codingPath.map(\.stringValue).joined(separator: "."))"
            @unknown default: return "\(e)"
            }
        }
        return error.localizedDescription
    }
}
