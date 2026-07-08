import Foundation

// MARK: - Errors

enum UbusError: Error, LocalizedError {
    case httpStatus(Int)
    case rpcError(String)
    case ubusStatus(Int, String?)
    case badCredentials
    case certificateNotTrusted(hostPort: String)
    case network(String)
    case notLoggedIn
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code): return "Failed to call RPC: HTTP \(code)"
        case .rpcError(let message): return "RPC error: \(message)"
        case .ubusStatus(let status, let message):
            if let message, !message.isEmpty { return message }
            if status == 6 { return "Permission denied (ubus status 6)" }
            return "ubus call failed (status \(status))"
        case .badCredentials: return "Login failed — check username and password"
        case .certificateNotTrusted(let hostPort):
            return "The certificate for \(hostPort) is not trusted"
        case .network(let message): return message
        case .notLoggedIn: return "Not logged in"
        case .invalidResponse: return "Invalid response from router"
        }
    }

    /// Object missing / permission denied — used to degrade gracefully when
    /// optional rpcd objects (tailscale, luci.wireguard) aren't installed.
    var isUnavailableObject: Bool {
        if case .ubusStatus(let status, _) = self {
            // ubus: 2 = invalid command, 4 = not found, 6 = permission denied
            return status == 2 || status == 4 || status == 6
        }
        return false
    }
}

// MARK: - TLS trust-on-first-use delegate

/// Accepts self-signed server certificates only for host:port pairs the user
/// has previously accepted (persisted in the Keychain).
final class TOFUTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var sessionAccepted: Set<String> = []
    private var _lastRejected: String?

    var lastRejectedHostPort: String? {
        lock.lock()
        defer { lock.unlock() }
        return _lastRejected
    }

    func acceptForSession(hostPort: String) {
        lock.lock()
        sessionAccepted.insert(hostPort)
        lock.unlock()
    }

    private func isAccepted(_ hostPort: String) -> Bool {
        lock.lock()
        let inSession = sessionAccepted.contains(hostPort)
        lock.unlock()
        if inSession { return true }
        return KeychainStore.shared.acceptedCertificateHosts().contains(hostPort)
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        // If the system already trusts it, proceed normally.
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        let host = challenge.protectionSpace.host
        let port = challenge.protectionSpace.port
        let hostPort = "\(host):\(port == 0 ? 443 : port)"
        if isAccepted(hostPort) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            lock.lock()
            _lastRejected = hostPort
            lock.unlock()
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

// MARK: - Transport protocol (mockable)

protocol UbusCalling: Sendable {
    func call(_ object: String, _ procedure: String, _ params: JSONValue) async throws -> JSONValue
}

// MARK: - UbusClient

/// One instance per router connection. Handles LuCI form login (sysauth cookie),
/// JSON-RPC calls through /cgi-bin/luci/admin/ubus, transient retries, a global
/// 3-concurrent-call gate, and TOFU TLS.
actor UbusClient: UbusCalling {
    private(set) var endpoint: RouterEndpoint
    private(set) var token: String?

    private let trustDelegate = TOFUTrustDelegate()
    private let semaphore = AsyncSemaphore(limit: 3)
    private var session: URLSession

    init(endpoint: RouterEndpoint) {
        self.endpoint = endpoint
        self.session = Self.makeSession(delegate: trustDelegate)
    }

    private static func makeSession(delegate: TOFUTrustDelegate) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.waitsForConnectivity = false
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    func invalidate() {
        session.invalidateAndCancel()
        token = nil
    }

    /// Marks the endpoint's certificate as user-accepted (TOFU) and persists it.
    func acceptCertificate() {
        let key = endpoint.certificateKey
        trustDelegate.acceptForSession(hostPort: key)
        KeychainStore.shared.acceptCertificate(hostPort: key)
    }

    // MARK: Login (LuCI form POST — §3.1 of the rewrite plan)

    struct LoginResult: Sendable {
        let token: String
        let useHttps: Bool
    }

    func login(username: String, password: String) async throws -> LoginResult {
        var lastError: Error = UbusError.badCredentials
        for attempt in 1...3 {
            do {
                return try await loginOnce(username: username, password: password)
            } catch let error as UbusError {
                switch error {
                case .badCredentials, .certificateNotTrusted:
                    throw error  // definitive — do not retry
                default:
                    lastError = error
                }
            } catch {
                lastError = error
            }
            if attempt < 3 {
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000)
            }
        }
        throw lastError
    }

    private func loginOnce(username: String, password: String) async throws -> LoginResult {
        do {
            return try await loginAttempt(
                endpoint: endpoint, username: username, password: password)
        } catch let error as UbusError {
            // HTTP attempt failed at the transport level: retry once over HTTPS.
            if !endpoint.useHttps {
                if case .network = error {
                    let httpsEndpoint = endpoint.with(useHttps: true)
                    let result = try await loginAttempt(
                        endpoint: httpsEndpoint, username: username, password: password)
                    endpoint = httpsEndpoint
                    return result
                }
            }
            throw error
        }
    }

    private func loginAttempt(
        endpoint: RouterEndpoint, username: String, password: String
    ) async throws -> LoginResult {
        guard let url = URL(string: "\(endpoint.baseURLString)/cgi-bin/luci/") else {
            throw UbusError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body =
            "luci_username=\(Self.formEncode(username))&luci_password=\(Self.formEncode(password))"
        request.httpBody = Data(body.utf8)
        request.timeoutInterval = 15

        let (_, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse else { throw UbusError.invalidResponse }
        guard (200...399).contains(http.statusCode) else {
            throw UbusError.httpStatus(http.statusCode)
        }

        // The sysauth cookie may have been set on an intermediate redirect
        // response; the session's cookie storage captured it.
        let finalURL = http.url ?? url
        let finalHttps = (finalURL.scheme?.lowercased() == "https")
        let cookieURLs = [finalURL, url]
        var sysauth: String?
        if let storage = session.configuration.httpCookieStorage {
            for cookieURL in cookieURLs {
                for cookie in storage.cookies(for: cookieURL) ?? []
                where cookie.name.lowercased().contains("sysauth") {
                    sysauth = cookie.value
                    break
                }
                if sysauth != nil { break }
            }
            // Secure cookies won't match an http:// URL; scan the jar as a fallback.
            if sysauth == nil {
                for cookie in storage.cookies ?? []
                where cookie.name.lowercased().contains("sysauth")
                    && cookie.domain.contains(endpoint.host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
                {
                    sysauth = cookie.value
                    break
                }
            }
        }

        guard let sysauth, !sysauth.isEmpty else {
            throw UbusError.badCredentials
        }

        let actualHttps = finalHttps || endpoint.useHttps
        if actualHttps != self.endpoint.useHttps {
            self.endpoint = self.endpoint.with(useHttps: actualHttps)
        } else {
            self.endpoint = endpoint
        }
        self.token = sysauth
        return LoginResult(token: sysauth, useHttps: actualHttps)
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    // MARK: RPC (ubus call — §3.2)

    func call(_ object: String, _ procedure: String, _ params: JSONValue = .object([:]))
        async throws -> JSONValue
    {
        guard let token else { throw UbusError.notLoggedIn }
        return try await rawCall(sessionID: token, object: object, procedure: procedure, params: params)
    }

    /// Unauthenticated availability probe (session id "").
    func probeCall(_ object: String, _ procedure: String) async throws -> JSONValue {
        try await rawCall(sessionID: "", object: object, procedure: procedure, params: .object([:]))
    }

    private func rawCall(
        sessionID: String, object: String, procedure: String, params: JSONValue
    ) async throws -> JSONValue {
        var lastError: Error = UbusError.invalidResponse
        for attempt in 1...3 {
            do {
                return try await semaphore.run { [endpoint, session] in
                    try await Self.executeRPC(
                        session: session, endpoint: endpoint, sessionID: sessionID,
                        object: object, procedure: procedure, params: params)
                }
            } catch let error as UbusError {
                if case .network = error {
                    lastError = error  // transient — retry
                } else {
                    throw error
                }
            } catch {
                lastError = error
            }
            if attempt < 3 {
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 300_000_000)
            }
        }
        throw lastError
    }

    private static func executeRPC(
        session: URLSession, endpoint: RouterEndpoint, sessionID: String,
        object: String, procedure: String, params: JSONValue
    ) async throws -> JSONValue {
        guard let url = URL(string: "\(endpoint.baseURLString)/cgi-bin/luci/admin/ubus") else {
            throw UbusError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        let envelope: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "id": .number(1),
            "method": .string("call"),
            "params": .array([
                .string(sessionID), .string(object), .string(procedure), params,
            ]),
        ])
        request.httpBody = try envelope.encoded()

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Self.mapTransportError(error, endpoint: endpoint)
        }
        guard let http = response as? HTTPURLResponse else { throw UbusError.invalidResponse }
        guard http.statusCode == 200 else { throw UbusError.httpStatus(http.statusCode) }

        let json = try JSONValue.parse(data)
        if !json["error"].isNull {
            let message = json["error"]["message"].stringValue
                ?? json["error"].coercedString ?? "unknown"
            throw UbusError.rpcError(message)
        }
        let result = json["result"]
        guard let items = result.arrayValue else {
            // Normalize a bare result to [0, result].
            return result
        }
        guard let status = items.first?.intValue else {
            return .null
        }
        guard status == 0 else {
            let message = items.count > 1 ? items[1].stringValue : nil
            throw UbusError.ubusStatus(status, message)
        }
        return items.count > 1 ? items[1] : .null
    }

    private static func mapTransportError(_ error: Error, endpoint: RouterEndpoint) -> UbusError {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorServerCertificateUntrusted,
                NSURLErrorServerCertificateHasBadDate,
                NSURLErrorServerCertificateHasUnknownRoot,
                NSURLErrorServerCertificateNotYetValid,
                NSURLErrorSecureConnectionFailed,
                NSURLErrorClientCertificateRejected,
                NSURLErrorCancelled:
                // .cancelled is what surfaces when the TOFU delegate rejects.
                return .certificateNotTrusted(hostPort: endpoint.certificateKey)
            default:
                return .network(nsError.localizedDescription)
            }
        }
        return .network(nsError.localizedDescription)
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw Self.mapTransportError(error, endpoint: endpoint)
        }
    }

    // MARK: Reachability probe (reboot recovery — §3.8)

    /// Returns true when any of the well-known LuCI paths answers over HTTP.
    func probeReachable() async -> Bool {
        for path in ["/", "/cgi-bin/luci/", "/cgi-bin/luci/admin"] {
            guard let url = URL(string: "\(endpoint.baseURLString)\(path)") else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 8
            if let (_, response) = try? await session.data(for: request),
                let http = response as? HTTPURLResponse,
                http.statusCode < 500
            {
                return true
            }
        }
        return false
    }
}
