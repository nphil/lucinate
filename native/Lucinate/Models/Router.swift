import Foundation

/// A saved OpenWrt router entry, mirroring `lib/models/router.dart`.
struct Router: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let ipAddress: String
    let username: String
    let password: String
    let useHttps: Bool
    let lastKnownHostname: String?

    init(
        id: String,
        ipAddress: String,
        username: String,
        password: String,
        useHttps: Bool,
        lastKnownHostname: String? = nil
    ) {
        self.id = id
        self.ipAddress = ipAddress
        self.username = username
        self.password = password
        self.useHttps = useHttps
        self.lastKnownHostname = lastKnownHostname
    }

    /// Canonical id convention used across the app ("ip-username").
    static func makeID(ipAddress: String, username: String) -> String {
        "\(ipAddress)-\(username)"
    }

    func copyWith(
        id: String? = nil,
        ipAddress: String? = nil,
        username: String? = nil,
        password: String? = nil,
        useHttps: Bool? = nil,
        lastKnownHostname: String?? = nil
    ) -> Router {
        Router(
            id: id ?? self.id,
            ipAddress: ipAddress ?? self.ipAddress,
            username: username ?? self.username,
            password: password ?? self.password,
            useHttps: useHttps ?? self.useHttps,
            lastKnownHostname: lastKnownHostname ?? self.lastKnownHostname
        )
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id, ipAddress, username, password, useHttps, lastKnownHostname
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        ipAddress = try container.decode(String.self, forKey: .ipAddress)
        username = try container.decode(String.self, forKey: .username)
        password = try container.decode(String.self, forKey: .password)
        // Legacy storage may hold `useHttps` as a Bool or as the string
        // "true"/"false" (the Flutter app tolerated both). Anything else
        // (missing, unparsable) falls back to false, matching the Dart logic
        // `json['useHttps'] == true || json['useHttps'] == 'true'`.
        if let boolValue = try? container.decode(Bool.self, forKey: .useHttps) {
            useHttps = boolValue
        } else if let stringValue = try? container.decode(String.self, forKey: .useHttps) {
            useHttps = stringValue.lowercased() == "true"
        } else {
            useHttps = false
        }
        lastKnownHostname = try container.decodeIfPresent(String.self, forKey: .lastKnownHostname)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(ipAddress, forKey: .ipAddress)
        try container.encode(username, forKey: .username)
        try container.encode(password, forKey: .password)
        try container.encode(useHttps, forKey: .useHttps)
        try container.encodeIfPresent(lastKnownHostname, forKey: .lastKnownHostname)
    }
}
