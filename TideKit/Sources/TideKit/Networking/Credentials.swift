import Foundation
#if canImport(Security)
import Security
#endif

/// Identifies this app to upstream services.
///
/// * NWS api.weather.gov requires a User-Agent with contact details and may
///   block anonymous or generic agents.
/// * NOAA CO-OPS asks callers to pass `application=<name>` so they can reach
///   heavy users.
public struct AppIdentity: Sendable, Hashable {
    public var appName: String
    public var version: String
    /// Contact e-mail or URL for the operator of the app (not the end user).
    public var contact: String

    public init(appName: String, version: String, contact: String) {
        self.appName = appName
        self.version = version
        self.contact = contact
    }

    public var userAgent: String { "\(appName)/\(version) (\(contact))" }

    /// CO-OPS `application` parameter (alphanumerics/underscores only).
    public var coopsApplication: String {
        let allowed = appName.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "_" }
        let s = String(String.UnicodeScalarView(allowed))
        return s.isEmpty ? "TideApp" : s
    }

    /// Reads `TideAppName`, `CFBundleShortVersionString` and `TideContact`
    /// from an Info.plist dictionary (populated from xcconfig at build time).
    public static func fromBundle(_ bundle: Bundle = .main) -> AppIdentity {
        let info = bundle.infoDictionary ?? [:]
        let name = (info["TideAppName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "TideForecast"
        let version = info["CFBundleShortVersionString"] as? String ?? "0.0"
        let contact = (info["TideContact"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "contact-not-configured"
        return AppIdentity(appName: name, version: version, contact: contact)
    }
}

/// Secrets the app may hold. Public NOAA/NWS/DFO endpoints need none.
public enum CredentialKey: String, Sendable, CaseIterable, Hashable {
    case openMeteoAPIKey = "open-meteo.apikey"
    case ukAdmiraltySubscriptionKey = "uk-admiralty.subscription-key"

    public var source: DataSourceID {
        switch self {
        case .openMeteoAPIKey: return .openMeteo
        case .ukAdmiraltySubscriptionKey: return .ukAdmiralty
        }
    }

    public var displayName: String {
        switch self {
        case .openMeteoAPIKey: return "Open-Meteo API key (commercial)"
        case .ukAdmiraltySubscriptionKey: return "UK Admiralty subscription key"
        }
    }

    /// Info.plist key used for an optional build-time default (from an
    /// untracked Secrets.xcconfig). Keychain values take precedence.
    public var infoPlistKey: String {
        switch self {
        case .openMeteoAPIKey: return "TideOpenMeteoAPIKey"
        case .ukAdmiraltySubscriptionKey: return "TideAdmiraltyKey"
        }
    }
}

public protocol CredentialStore: Sendable {
    func secret(for key: CredentialKey) -> String?
    func setSecret(_ value: String?, for key: CredentialKey) throws
}

public extension CredentialStore {
    func hasSecret(for key: CredentialKey) -> Bool { !(secret(for: key) ?? "").isEmpty }
}

/// Test / preview store.
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private var storage: [CredentialKey: String]
    private let lock = NSLock()

    public init(_ initial: [CredentialKey: String] = [:]) { storage = initial }

    public func secret(for key: CredentialKey) -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    public func setSecret(_ value: String?, for key: CredentialKey) throws {
        lock.lock(); defer { lock.unlock() }
        storage[key] = value
    }
}

/// Layers stores: the first non-empty value wins; writes go to `primary`.
public struct LayeredCredentialStore: CredentialStore {
    public let primary: CredentialStore
    public let fallbacks: [CredentialStore]

    public init(primary: CredentialStore, fallbacks: [CredentialStore]) {
        self.primary = primary
        self.fallbacks = fallbacks
    }

    public func secret(for key: CredentialKey) -> String? {
        for store in [primary] + fallbacks {
            if let v = store.secret(for: key), !v.isEmpty { return v }
        }
        return nil
    }

    public func setSecret(_ value: String?, for key: CredentialKey) throws {
        try primary.setSecret(value, for: key)
    }
}

/// Read-only defaults injected at build time via Info.plist.
public struct BundleCredentialStore: CredentialStore {
    let info: [String: String]

    public init(bundle: Bundle = .main) {
        info = (bundle.infoDictionary ?? [:]).compactMapValues { $0 as? String }
    }

    public func secret(for key: CredentialKey) -> String? {
        guard let v = info[key.infoPlistKey] else { return nil }
        let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
        // Unexpanded xcconfig variables look like "$(FOO)".
        return trimmed.isEmpty || trimmed.hasPrefix("$(") ? nil : trimmed
    }

    public func setSecret(_ value: String?, for key: CredentialKey) throws {}
}

#if canImport(Security)
/// Stores secrets in the iOS Keychain (this device only, after first unlock,
/// so background refresh and widgets can read them; never synced to iCloud).
///
/// With an `accessGroup` the items are shared with other targets of the
/// same team that list the group in their `keychain-access-groups`
/// entitlement (the widget extension). If the group isn't entitled (e.g. an
/// unsigned simulator build), it falls back to the app's own keychain.
public struct KeychainCredentialStore: CredentialStore {
    public let service: String
    public let accessGroup: String?

    public init(service: String = "app.tide.credentials", accessGroup: String? = nil) {
        self.service = service
        let g = accessGroup?.trimmingCharacters(in: .whitespaces)
        self.accessGroup = (g?.isEmpty ?? true) || g!.contains("$(") ? nil : g
    }

    public enum KeychainError: Error, LocalizedError {
        case status(OSStatus)
        public var errorDescription: String? {
            if case .status(let s) = self { return "Keychain error \(s)" }
            return nil
        }
    }

    private func query(_ key: CredentialKey, group: String?) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        if let group { q[kSecAttrAccessGroup as String] = group }
        return q
    }

    public func secret(for key: CredentialKey) -> String? {
        for group in [accessGroup, nil] {
            var q = query(key, group: group)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: AnyObject?
            if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data {
                return String(data: data, encoding: .utf8)
            }
            if accessGroup == nil { break }
        }
        return nil
    }

    public func setSecret(_ value: String?, for key: CredentialKey) throws {
        SecItemDelete(query(key, group: nil) as CFDictionary)
        if accessGroup != nil { SecItemDelete(query(key, group: accessGroup) as CFDictionary) }
        guard let value, !value.isEmpty else { return }
        func add(_ group: String?) -> OSStatus {
            var add = query(key, group: group)
            add[kSecValueData as String] = Data(value.utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(add as CFDictionary, nil)
        }
        var status = add(accessGroup)
        if status == errSecMissingEntitlement, accessGroup != nil { status = add(nil) }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }
}
#endif
