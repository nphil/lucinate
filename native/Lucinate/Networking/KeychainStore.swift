import Foundation
import Security

/// Thin generic-password Keychain wrapper. Values are UTF-8 strings keyed by
/// account name under a single service. Mirrors the Flutter secure-storage schema:
///   ipAddress / username / password / useHttps      (active credentials)
///   routers                                          (JSON array of saved routers)
///   selectedRouterId
///   accepted_certificates                            ({"host:port": true})
struct KeychainStore: Sendable {
    static let shared = KeychainStore()

    private let service = "app.cogwheel.lucimobile"

    enum Key {
        static let ipAddress = "ipAddress"
        static let username = "username"
        static let password = "password"
        static let useHttps = "useHttps"
        static let routers = "routers"
        static let selectedRouterId = "selectedRouterId"
        static let acceptedCertificates = "accepted_certificates"
    }

    func string(for key: String) -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func set(_ value: String, for key: String) -> Bool {
        let data = Data(value.utf8)
        var query = baseQuery(for: key)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        if updateStatus == errSecItemNotFound {
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    @discardableResult
    func delete(_ key: String) -> Bool {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - JSON helpers

    func json(for key: String) -> JSONValue? {
        guard let text = string(for: key), let data = text.data(using: .utf8) else { return nil }
        return try? JSONValue.parse(data)
    }

    @discardableResult
    func setJSON(_ value: JSONValue, for key: String) -> Bool {
        guard let data = try? value.encoded(), let text = String(data: data, encoding: .utf8) else {
            return false
        }
        return set(text, for: key)
    }

    // MARK: - Accepted certificates (TOFU)

    func acceptedCertificateHosts() -> Set<String> {
        guard let json = json(for: Key.acceptedCertificates),
            let dict = json.objectValue
        else { return [] }
        return Set(dict.filter { $0.value.boolValue == true }.keys)
    }

    func acceptCertificate(hostPort: String) {
        var hosts = acceptedCertificateHosts()
        hosts.insert(hostPort)
        saveAcceptedCertificates(hosts)
    }

    func removeCertificate(hostPort: String) {
        var hosts = acceptedCertificateHosts()
        hosts.remove(hostPort)
        saveAcceptedCertificates(hosts)
    }

    func clearAcceptedCertificates() {
        delete(Key.acceptedCertificates)
    }

    private func saveAcceptedCertificates(_ hosts: Set<String>) {
        var dict: [String: JSONValue] = [:]
        for host in hosts { dict[host] = .bool(true) }
        setJSON(.object(dict), for: Key.acceptedCertificates)
    }

    private func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}
