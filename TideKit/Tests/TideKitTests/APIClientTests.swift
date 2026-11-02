import XCTest
@testable import TideKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class MockTransport: HTTPTransport, @unchecked Sendable {
    var responses: [(Int, Data, [String: String])]
    private(set) var requests: [URLRequest] = []
    private let lock = NSLock()

    init(_ responses: [(Int, Data, [String: String])]) { self.responses = responses }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (status, data, headers): (Int, Data, [String: String]) = lock.withLock {
            requests.append(request)
            return responses.isEmpty ? (200, Data("{}".utf8), [:]) : responses.removeFirst()
        }
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
}

final class APIClientTests: XCTestCase {
    let identity = AppIdentity(appName: "Tide App", version: "1.2", contact: "ops@example.com")

    func client(_ t: MockTransport, _ secrets: [CredentialKey: String] = [:]) -> APIClient {
        APIClient(identity: identity, credentials: InMemoryCredentialStore(secrets), transport: t, maxAttempts: 3, baseBackoff: 0.01, hostSpacing: [:])
    }

    func testIdentifyingUserAgentAndCoopsApplication() async throws {
        let t = MockTransport([(200, Data(), [:])])
        let api = client(t)
        _ = try await api.data(for: Endpoint.build(.nwsAlerts, "https://api.weather.gov/alerts/active", ["point": "1,2"]))
        XCTAssertEqual(t.requests[0].value(forHTTPHeaderField: "User-Agent"), "Tide App/1.2 (ops@example.com)")
        XCTAssertEqual(identity.coopsApplication, "TideApp")
    }

    func testOpenMeteoKeyGoesInQueryOnlyWhenPresent() async throws {
        let t = MockTransport([(200, Data(), [:]), (200, Data(), [:])])
        var ep = try Endpoint.build(.openMeteo, "https://customer-api.open-meteo.com/v1/forecast", ["latitude": "1"])
        ep.credential = .openMeteoAPIKey
        _ = try await client(t).data(for: ep)
        XCTAssertFalse(t.requests[0].url!.absoluteString.contains("apikey"))
        _ = try await client(t, [.openMeteoAPIKey: "secret123"]).data(for: ep)
        XCTAssertTrue(t.requests[1].url!.absoluteString.contains("apikey=secret123"))
    }

    func testAdmiraltyKeyHeaderAndMissingKey() async throws {
        let t = MockTransport([(200, Data("[]".utf8), [:])])
        let withKey = AdmiraltyClient(api: client(t, [.ukAdmiraltySubscriptionKey: "abc"]))
        _ = try await withKey.tidalEvents(stationID: "0001")
        XCTAssertEqual(t.requests[0].value(forHTTPHeaderField: "Ocp-Apim-Subscription-Key"), "abc")
        XCTAssertFalse(t.requests[0].url!.absoluteString.contains("abc"))

        let none = AdmiraltyClient(api: client(MockTransport([])))
        do {
            _ = try await none.tidalEvents(stationID: "0001")
            XCTFail("expected missing credential")
        } catch let e as APIError {
            XCTAssertEqual(e, .missingCredential(.ukAdmiraltySubscriptionKey))
        }
    }

    func testRetriesTransientFailures() async throws {
        let t = MockTransport([(503, Data(), [:]), (429, Data(), ["Retry-After": "0"]), (200, Data("ok".utf8), [:])])
        let d = try await client(t).data(for: Endpoint.build(.noaaCoops, "https://api.tidesandcurrents.noaa.gov/x"))
        XCTAssertEqual(String(decoding: d, as: UTF8.self), "ok")
        XCTAssertEqual(t.requests.count, 3)
    }

    func testUnauthorizedIsNotRetried() async throws {
        let t = MockTransport([(401, Data(), [:])])
        do {
            _ = try await client(t, [.ukAdmiraltySubscriptionKey: "bad"]).data(for: {
                var e = try Endpoint.build(.ukAdmiralty, "https://admiraltyapi.azure-api.net/uktidalapi/api/V1/Stations")
                e.credential = .ukAdmiraltySubscriptionKey
                return e
            }())
            XCTFail()
        } catch let e as APIError {
            XCTAssertEqual(e, .unauthorized(source: .ukAdmiralty))
        }
        XCTAssertEqual(t.requests.count, 1)
    }

    func testCachingAndRedaction() async throws {
        let t = MockTransport([(200, Data("a".utf8), [:]), (200, Data("b".utf8), [:])])
        let api = client(t)
        let ep = try Endpoint.build(.noaaCoops, "https://api.tidesandcurrents.noaa.gov/y", cacheTTL: 60)
        let a = try await api.data(for: ep), b = try await api.data(for: ep)
        XCTAssertEqual(a, b)
        XCTAssertEqual(t.requests.count, 1)
        XCTAssertEqual(APIClient.redact("https://x.test/v1?apikey=SECRET&lat=1"), "https://x.test/v1?apikey=REDACTED&lat=1")
    }

    func testBundleStoreIgnoresUnexpandedXcconfigVariables() {
        let store = BundleCredentialStore(bundle: .main)
        XCTAssertNil(store.secret(for: .ukAdmiraltySubscriptionKey))
        let layered = LayeredCredentialStore(primary: InMemoryCredentialStore(), fallbacks: [InMemoryCredentialStore([.openMeteoAPIKey: "fallback"])])
        XCTAssertEqual(layered.secret(for: .openMeteoAPIKey), "fallback")
    }
}
