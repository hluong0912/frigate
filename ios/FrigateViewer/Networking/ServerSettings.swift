import Foundation
import Security

/// Connection details for one Frigate server. The password and session token
/// live in the Keychain; everything else is kept in UserDefaults.
struct ServerSettings: Codable, Equatable {
    /// Root of the Frigate UI, e.g. `http://192.168.40.249:8971/`.
    var baseURL: URL
    /// Empty when the server runs without authentication (port 5000).
    var username: String
    /// Accept a self-signed TLS certificate for API and image requests.
    /// Video playback (AVPlayer) cannot honour this; see README.
    var allowSelfSigned: Bool

    var usesAuth: Bool { !username.isEmpty }

    private static let defaultsKey = "server.settings"

    static func load() -> ServerSettings? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(ServerSettings.self, from: data)
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        Keychain.delete("password")
        Keychain.delete("token")
        Keychain.delete("cookieName")
    }

    /// Normalises user input such as `192.168.40.249:8971` into a root URL.
    static func normalisedURL(from input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        guard var comps = URLComponents(string: text), comps.host?.isEmpty == false else { return nil }
        var path = comps.path
        if !path.hasSuffix("/") { path += "/" }
        comps.path = path
        comps.query = nil
        comps.fragment = nil
        return comps.url
    }
}

enum Keychain {
    private static let service = "FrigateViewer"

    static func set(_ value: String?, for key: String) {
        delete(key)
        guard let value, let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
