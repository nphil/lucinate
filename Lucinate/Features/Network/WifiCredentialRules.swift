import Foundation

/// Limits hostapd enforces on Wi-Fi credentials. A value outside them makes it
/// refuse to bring the interface up, so after `wifi reload` the router's own
/// network (the one the phone is on) stays down.
enum WifiCredentialRules {
    static let maxSSIDBytes = 32

    /// Why `ssid` would be refused, or nil when it is fine.
    static func ssidProblem(_ ssid: String) -> String? {
        guard ssid.utf8.count > maxSSIDBytes else { return nil }
        return "The network name is too long. Wi-Fi allows 32 bytes, and accented letters "
            + "and emoji use more than one."
    }

    /// Encryption modes that take a WPA passphrase (psk, psk2, psk-mixed, sae, sae-mixed, …).
    static func usesPassphrase(encryption: String) -> Bool {
        encryption.hasPrefix("psk") || encryption.hasPrefix("sae")
    }

    /// Why a newly typed password would be refused under `encryption`, or nil
    /// when it is acceptable or empty (empty means "keep the current one").
    static func passphraseProblem(_ password: String, encryption: String) -> String? {
        guard !password.isEmpty, usesPassphrase(encryption: encryption) else { return nil }
        let length = password.utf8.count
        if (8...63).contains(length) { return nil }
        // OpenWrt's hostapd script reads exactly 64 characters as a raw hex key.
        if length == 64, password.allSatisfy({ $0.isASCII && $0.isHexDigit }) { return nil }
        return "The password must be 8 to 63 characters."
    }
}
