import Foundation

/// Parsed router address. Reproduces the Flutter app's URL-parsing contract:
/// - trim + strip trailing slashes
/// - explicit scheme wins (default port 80/443)
/// - bare host -> http:80; host:port -> https only if port is 443 or 8443
/// - [IPv6]:port supported (brackets preserved in `host`)
struct RouterEndpoint: Sendable, Equatable {
    let host: String
    let port: Int
    let useHttps: Bool

    var scheme: String { useHttps ? "https" : "http" }

    var isDefaultPort: Bool { port == (useHttps ? 443 : 80) }

    /// Host plus port, omitting the port when it is the scheme default.
    var hostWithPort: String { isDefaultPort ? host : "\(host):\(port)" }

    /// e.g. "https://192.168.1.1:8443"
    var baseURLString: String { "\(scheme)://\(hostWithPort)" }

    /// Key used for the accepted-certificates map ("host:port", always explicit).
    var certificateKey: String { "\(host):\(port)" }

    func with(useHttps: Bool) -> RouterEndpoint {
        // When flipping scheme on a default port, move to the new default port.
        var newPort = port
        if isDefaultPort {
            newPort = useHttps ? 443 : 80
        }
        return RouterEndpoint(host: host, port: newPort, useHttps: useHttps)
    }

    enum ParseError: Error, LocalizedError, Equatable {
        case empty
        case invalidPort
        case invalidHost

        var errorDescription: String? {
            switch self {
            case .empty: return "Router address is empty"
            case .invalidPort: return "Port must be between 1 and 65535"
            case .invalidHost: return "Invalid router address"
            }
        }
    }

    static func parse(_ input: String) throws -> RouterEndpoint {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ParseError.empty }
        while text.hasSuffix("/") { text.removeLast() }
        guard !text.isEmpty else { throw ParseError.empty }

        var explicitScheme: Bool? = nil
        if text.lowercased().hasPrefix("https://") {
            explicitScheme = true
            text = String(text.dropFirst(8))
        } else if text.lowercased().hasPrefix("http://") {
            explicitScheme = false
            text = String(text.dropFirst(7))
        }
        while text.hasSuffix("/") { text.removeLast() }
        guard !text.isEmpty else { throw ParseError.invalidHost }
        // Drop any path component the user pasted.
        if let slash = text.firstIndex(of: "/") {
            text = String(text[text.startIndex..<slash])
        }

        var host: String
        var portText: String? = nil

        if text.hasPrefix("[") {
            // Bracketed IPv6, optional :port after the closing bracket.
            guard let close = text.firstIndex(of: "]") else { throw ParseError.invalidHost }
            host = String(text[text.startIndex...close])
            let rest = String(text[text.index(after: close)...])
            if rest.hasPrefix(":") {
                portText = String(rest.dropFirst())
            } else if !rest.isEmpty {
                throw ParseError.invalidHost
            }
            let inner = String(host.dropFirst().dropLast())
            guard !inner.isEmpty, inner.contains(":") else { throw ParseError.invalidHost }
        } else if text.filter({ $0 == ":" }).count > 1 {
            // Unbracketed IPv6 literal — keep whole, add brackets for URL use.
            host = "[\(text)]"
        } else if let colon = text.firstIndex(of: ":") {
            host = String(text[text.startIndex..<colon])
            portText = String(text[text.index(after: colon)...])
        } else {
            host = text
        }

        var port: Int? = nil
        if let portText {
            guard let value = Int(portText), (1...65535).contains(value) else {
                throw ParseError.invalidPort
            }
            port = value
        }

        if !host.hasPrefix("[") {
            try validateHost(host)
        }

        let useHttps: Bool
        if let explicitScheme {
            useHttps = explicitScheme
        } else if let port {
            useHttps = (port == 443 || port == 8443)
        } else {
            useHttps = false
        }

        return RouterEndpoint(
            host: host,
            port: port ?? (useHttps ? 443 : 80),
            useHttps: useHttps
        )
    }

    private static func validateHost(_ host: String) throws {
        guard !host.isEmpty else { throw ParseError.invalidHost }
        // IPv4?
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        let looksNumeric = parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
        if looksNumeric {
            guard parts.count == 4,
                parts.allSatisfy({ if let octet = Int($0) { return (0...255).contains(octet) } else { return false } })
            else { throw ParseError.invalidHost }
            return
        }
        // Hostname: labels of alphanumerics + hyphens, not starting/ending with hyphen.
        let labelOK: (Substring) -> Bool = { label in
            guard !label.isEmpty, label.count <= 63,
                !label.hasPrefix("-"), !label.hasSuffix("-")
            else { return false }
            return label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        }
        guard parts.allSatisfy(labelOK) else { throw ParseError.invalidHost }
    }
}
