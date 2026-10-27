import Foundation

// MARK: - Errors

enum UbusError: Error, LocalizedError {
    case httpStatus(Int)
    case rpcError(code: Int, message: String)
    case ubusStatus(Int, String?)
    case badCredentials
    case certificateNotTrusted(hostPort: String)
    case network(String)
    case notLoggedIn
    case invalidResponse

    private static let accessDeniedText = "The router session expired or this login lacks permission"
    private static let notFoundText = "The router doesn't offer this feature"

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code):
            return isAccessDenied ? Self.accessDeniedText : "Failed to call RPC: HTTP \(code)"
        case .rpcError(let code, let message):
            if isAccessDenied { return Self.accessDeniedText }
            return "RPC error \(code): \(message)"
        case .ubusStatus(let status, let message):
            if let message, !message.isEmpty { return message }
            if isAccessDenied { return Self.accessDeniedText }
            if isNotFound { return Self.notFoundText }
            if status == 7 { return "The router took too long to answer" }
            return "ubus call failed (status \(status))"
        case .badCredentials: return "Login failed — check username and password"
        case .certificateNotTrusted(let hostPort):
            return "The certificate for \(hostPort) is not trusted"
        case .network(let message): return message
        case .notLoggedIn: return "Not logged in"
        case .invalidResponse: return "Invalid response from router"
        }
    }

    // ubus status codes: 0 OK, 1 INVALID_COMMAND, 2 INVALID_ARGUMENT, 3 METHOD_NOT_FOUND,
    // 4 NOT_FOUND, 5 NO_DATA, 6 PERMISSION_DENIED, 7 TIMEOUT, 8 NOT_SUPPORTED,
    // 9 UNKNOWN_ERROR, 10 CONNECTION_FAILED.

    /// The router refused the call: an unknown or expired session (JSON-RPC
    /// -32002, the code LuCI's own UI treats as "session expired"), an ACL
    /// denial (ubus 6), or HTTP 403. LuCI also answers -32002 for an object no
    /// installed ACL covers, e.g. an uninstalled plugin. From `UbusClient` this
    /// already survived one re-login, so it is a genuine permission gap.
    var isAccessDenied: Bool {
        switch self {
        case .rpcError(let code, _): return code == -32002
        case .ubusStatus(let status, _): return status == 6
        case .httpStatus(let code): return code == 403
        default: return false
        }
    }

    /// The ubus object or method does not exist (ubus 3 or 4).
    var isNotFound: Bool {
        guard case .ubusStatus(let status, _) = self else { return false }
        return status == 3 || status == 4
    }

    /// A failure that may clear up on its own: no answer from the router, a
    /// ubus timeout or connection failure, or a server-side HTTP error.
    var isTransient: Bool {
        switch self {
        case .network: return true
        case .ubusStatus(let status, _): return status == 7 || status == 10
        case .httpStatus(let code): return (500...599).contains(code)
        default: return false
        }
    }

    /// Object missing or not usable by this login. Used to degrade gracefully
    /// when optional rpcd objects (tailscale, luci.wireguard) aren't available.
    var isUnavailableObject: Bool { isNotFound || isAccessDenied }
}

// MARK: - Retry policy

/// Which failed requests may be sent again. A reply that never arrived does
/// not prove the router skipped the request, so only reads — or requests that
/// provably never left the phone — are repeated.
enum UbusRetryPolicy {
    static let maxAttempts = 3

    private static let readOnlyProcedures: Set<String> = [
        "get", "read", "list", "status", "info", "board", "dump", "assoclist", "scan",
        "access", "state", "stat",
    ]

    /// Procedures that only read (`getWirelessDevices`, `get_status`, `board`, …).
    /// Everything else — uci set/add/delete/commit, file exec, set_settings,
    /// reboot — is single-attempt.
    static func isReadOnly(procedure: String) -> Bool {
        procedure.hasPrefix("get") || readOnlyProcedures.contains(procedure)
    }

    /// URLError codes raised before any request bytes went out (the TCP
    /// connection was never established), so the router cannot have acted.
    static func requestNeverSent(urlErrorCode code: Int) -> Bool {
        switch code {
        case NSURLErrorCannotConnectToHost,
            NSURLErrorCannotFindHost,
            NSURLErrorDNSLookupFailed,
            NSURLErrorNotConnectedToInternet:
            return true
        default:
            return false
        }
    }
}

/// A transport failure plus whether the request provably never left the
/// phone. Internal to the retry loop; callers only ever see the `UbusError`.
private struct RequestFailure: Error {
    let error: UbusError
    let neverSent: Bool
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
    /// Runs a command through cgi-io's `/cgi-bin/cgi-exec` (what LuCI's
    /// `fs.exec_direct` uses) and returns its raw stdout. Unlike ubus
    /// `file exec` it isn't killed at rpcd's timeout and isn't size-capped,
    /// so it suits package management. Single attempt: callers must never
    /// have a mutating command silently re-issued.
    func cgiExec(command: String, params: [String], timeout: TimeInterval) async throws -> Data
    /// Names of every ubus object registered on the router (JSON-RPC `list`,
    /// no session needed).
    func listObjects() async throws -> [String]
}

// MARK: - UbusClient

/// One instance per router connection. Handles LuCI form login (sysauth cookie),
/// JSON-RPC calls through /cgi-bin/luci/admin/ubus, a single shared re-login when
/// the router rejects the session, retries of read-only calls, a global
/// 3-concurrent-call gate, and TOFU TLS.
actor UbusClient: UbusCalling {
    private(set) var endpoint: RouterEndpoint
    private(set) var token: String?

    private let trustDelegate = TOFUTrustDelegate()
    private let semaphore = AsyncSemaphore(limit: 3)
    private var session: URLSession

    /// Credentials of the last successful `login`, kept so an expired LuCI
    /// session can be replaced without involving the user.
    private struct Credentials: Sendable {
        let username: String
        let password: String
    }
    private var credentials: Credentials?
    private var lastLoginAt: ContinuousClock.Instant?
    /// The one re-login shared by every call that finds the session rejected.
    private var reloginTask: Task<String, Error>?
    /// A denial this soon after a successful login is the account's ACL, not an
    /// expired session; logging in again would not help and would hammer the router.
    private static let reloginCooldown: Duration = .seconds(5)

    /// Object names from the latest `list`, so a denial for an uninstalled
    /// plugin is recognised without a re-login. Short-lived: installing a
    /// package changes the set.
    private struct ObjectCache {
        let names: Set<String>
        let fetchedAt: ContinuousClock.Instant
    }
    private var objectCache: ObjectCache?
    private var objectListTask: Task<Set<String>?, Never>?
    private static let objectCacheLifetime: Duration = .seconds(30)

    init(endpoint: RouterEndpoint) {
        self.endpoint = endpoint
        self.session = Self.makeSession(delegate: trustDelegate)
    }

    private static func makeSession(delegate: TOFUTrustDelegate) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        // Ceiling for the whole request. Normal calls still hit their 15s
        // per-request timeout first; only long package operations (which set a
        // larger per-request timeout) use the extra headroom.
        config.timeoutIntervalForResource = 300
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.waitsForConnectivity = false
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    func invalidate() {
        session.invalidateAndCancel()
        reloginTask?.cancel()
        reloginTask = nil
        objectListTask?.cancel()
        objectListTask = nil
        objectCache = nil
        credentials = nil
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

    /// `maxAttempts` caps the transient-retry loop. Pass 1 for a silent
    /// background auto-connect so an unreachable router fails fast instead of
    /// retrying for the better part of a minute.
    func login(username: String, password: String, maxAttempts: Int = 3) async throws
        -> LoginResult
    {
        let attempts = max(1, maxAttempts)
        var lastError: Error = UbusError.badCredentials
        for attempt in 1...attempts {
            if Task.isCancelled { throw CancellationError() }
            do {
                let result = try await loginOnce(username: username, password: password)
                credentials = Credentials(username: username, password: password)
                lastLoginAt = ContinuousClock.now
                objectCache = nil
                return result
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
            if attempt < attempts {
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
            // LuCI answers a rejected login with 403 and no session cookie.
            throw http.statusCode == 403
                ? UbusError.badCredentials : UbusError.httpStatus(http.statusCode)
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

    // MARK: Session recovery

    /// Replaces a session the router rejected. Returns the token to retry
    /// with, or nil when logging in again cannot help.
    private func recoverSession(rejecting rejectedToken: String) async throws -> String? {
        // A concurrent caller already swapped the session while this call was in flight.
        if let current = token, current != rejectedToken { return current }
        if let reloginTask { return try await reloginTask.value }
        guard let credentials else { return nil }
        if let lastLoginAt, ContinuousClock.now - lastLoginAt < Self.reloginCooldown {
            return nil
        }

        // `login` keeps the http→https detection. Two attempts: the router just
        // answered, so a second try only has to cover a web server mid-restart.
        let task: Task<String, Error> = Task {
            defer { self.reloginTask = nil }
            do {
                return try await self.login(
                    username: credentials.username, password: credentials.password,
                    maxAttempts: 2
                ).token
            } catch UbusError.badCredentials {
                // The stored password no longer works; stop retrying it on every call.
                self.credentials = nil
                throw UbusError.badCredentials
            }
        }
        reloginTask = task
        return try await task.value
    }

    // MARK: RPC (ubus call — §3.2)

    func call(_ object: String, _ procedure: String, _ params: JSONValue = .object([:]))
        async throws -> JSONValue
    {
        guard let token else { throw UbusError.notLoggedIn }
        do {
            return try await rawCall(
                sessionID: token, object: object, procedure: procedure, params: params)
        } catch let error as UbusError where error.isAccessDenied {
            // LuCI answers an object no installed ACL covers (an uninstalled
            // plugin) with the same "access denied" as an expired session, and a
            // re-login cannot fix that.
            if await isMissingFromRouter(object) {
                throw UbusError.ubusStatus(4, "\(object) is not installed")
            }
            // A denied call never ran, so repeating it after a re-login is safe
            // even for mutations.
            guard let fresh = try await recoverSession(rejecting: token) else { throw error }
            return try await rawCall(
                sessionID: fresh, object: object, procedure: procedure, params: params)
        }
    }

    /// `list` needs no session, so a denial here is never a reason to re-login.
    func listObjects() async throws -> [String] {
        let names = try await withRetries(readOnly: true) { session, endpoint in
            try await Self.executeList(session: session, endpoint: endpoint)
        }
        objectCache = ObjectCache(names: Set(names), fetchedAt: ContinuousClock.now)
        return names
    }

    /// True only when an object list was fetched and lacks `object`. When the
    /// list can't be fetched the answer is unknown and the caller re-logs in.
    private func isMissingFromRouter(_ object: String) async -> Bool {
        guard let names = await knownObjects() else { return false }
        return !names.contains(object)
    }

    /// The cached object set, fetched lazily and shared by concurrent callers.
    private func knownObjects() async -> Set<String>? {
        if let objectCache, ContinuousClock.now - objectCache.fetchedAt < Self.objectCacheLifetime {
            return objectCache.names
        }
        if let objectListTask { return await objectListTask.value }
        let task: Task<Set<String>?, Never> = Task {
            defer { self.objectListTask = nil }
            guard let names = try? await self.listObjects() else { return nil }
            return Set(names)
        }
        objectListTask = task
        return await task.value
    }

    func cgiExec(command: String, params: [String], timeout: TimeInterval) async throws -> Data {
        guard let token else { throw UbusError.notLoggedIn }
        do {
            return try await runCgiExec(
                sessionID: token, command: command, params: params, timeout: timeout)
        } catch let error as UbusError where error.isAccessDenied {
            guard let fresh = try await recoverSession(rejecting: token) else { throw error }
            return try await runCgiExec(
                sessionID: fresh, command: command, params: params, timeout: timeout)
        }
    }

    /// Single attempt: a command that may already have run is never re-sent.
    private func runCgiExec(
        sessionID: String, command: String, params: [String], timeout: TimeInterval
    ) async throws -> Data {
        do {
            return try await semaphore.run { [endpoint, session] in
                try await Self.executeCgiExec(
                    session: session, endpoint: endpoint, sessionID: sessionID,
                    command: command, params: params, timeout: timeout)
            }
        } catch let failure as RequestFailure {
            throw failure.error
        }
    }

    private func rawCall(
        sessionID: String, object: String, procedure: String, params: JSONValue
    ) async throws -> JSONValue {
        try await withRetries(readOnly: UbusRetryPolicy.isReadOnly(procedure: procedure)) {
            session, endpoint in
            try await Self.executeRPC(
                session: session, endpoint: endpoint, sessionID: sessionID,
                object: object, procedure: procedure, params: params)
        }
    }

    /// Runs one request through the concurrency gate, repeating it on a
    /// transient failure only when that cannot duplicate a change: reads, or a
    /// request that provably never left the phone.
    private func withRetries<T: Sendable>(
        readOnly: Bool,
        _ request: @escaping @Sendable (URLSession, RouterEndpoint) async throws -> T
    ) async throws -> T {
        var attempt = 1
        while true {
            let session = self.session
            let endpoint = self.endpoint
            do {
                return try await semaphore.run { try await request(session, endpoint) }
            } catch let failure as RequestFailure {
                guard attempt < UbusRetryPolicy.maxAttempts, readOnly || failure.neverSent else {
                    throw failure.error
                }
            } catch let error as UbusError {
                guard attempt < UbusRetryPolicy.maxAttempts, readOnly, error.isTransient else {
                    throw error
                }
            }
            try await Task.sleep(nanoseconds: UInt64(attempt) * 300_000_000)
            attempt += 1
        }
    }

    private static func rpcRequest(
        endpoint: RouterEndpoint, method: String, params: JSONValue
    ) throws -> URLRequest {
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
            "method": .string(method),
            "params": params,
        ])
        request.httpBody = try envelope.encoded()
        return request
    }

    /// Sends the request. A transport-level failure surfaces as `RequestFailure`
    /// so the retry loop can tell whether the request ever left the phone.
    private static func send(
        _ request: URLRequest, session: URLSession, endpoint: RouterEndpoint
    ) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            let mapped = Self.mapTransportError(error, endpoint: endpoint)
            guard case .network = mapped else { throw mapped }
            let nsError = error as NSError
            throw RequestFailure(
                error: mapped,
                neverSent: nsError.domain == NSURLErrorDomain
                    && UbusRetryPolicy.requestNeverSent(urlErrorCode: nsError.code))
        }
        guard let http = response as? HTTPURLResponse else { throw UbusError.invalidResponse }
        return (data, http)
    }

    private static func rpcError(from error: JSONValue) -> UbusError {
        let message = error["message"].stringValue ?? error.coercedString ?? "unknown"
        // A reply without a numeric code is malformed; -32603 is JSON-RPC's
        // generic "Internal error".
        let code = error["code"].intValue ?? -32603
        return .rpcError(code: code, message: message)
    }

    private static func executeRPC(
        session: URLSession, endpoint: RouterEndpoint, sessionID: String,
        object: String, procedure: String, params: JSONValue
    ) async throws -> JSONValue {
        let request = try rpcRequest(
            endpoint: endpoint, method: "call",
            params: .array([
                .string(sessionID), .string(object), .string(procedure), params,
            ]))
        let (data, http) = try await send(request, session: session, endpoint: endpoint)
        guard http.statusCode == 200 else { throw UbusError.httpStatus(http.statusCode) }

        let json = try JSONValue.parse(data)
        if !json["error"].isNull { throw rpcError(from: json["error"]) }
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

    private static func executeList(
        session: URLSession, endpoint: RouterEndpoint
    ) async throws -> [String] {
        let request = try rpcRequest(endpoint: endpoint, method: "list", params: .array([]))
        let (data, http) = try await send(request, session: session, endpoint: endpoint)
        guard http.statusCode == 200 else { throw UbusError.httpStatus(http.statusCode) }

        let json = try JSONValue.parse(data)
        if !json["error"].isNull { throw rpcError(from: json["error"]) }
        guard let names = parseObjectList(json["result"]) else { throw UbusError.invalidResponse }
        return names
    }

    /// Object names from a `list` result. LuCI wraps them in a one-element
    /// array (`[["system", "uci"]]`); a bare array is tolerated too.
    static func parseObjectList(_ result: JSONValue) -> [String]? {
        guard let items = result.arrayValue else { return nil }
        let names = items.first?.arrayValue ?? items
        return names.compactMap { $0.stringValue }
    }

    private static func executeCgiExec(
        session: URLSession, endpoint: RouterEndpoint, sessionID: String,
        command: String, params: [String], timeout: TimeInterval
    ) async throws -> Data {
        guard let url = URL(string: "\(endpoint.baseURLString)/cgi-bin/cgi-exec") else {
            throw UbusError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        // cgi-io splits the command line on unescaped whitespace; escape the
        // way LuCI does (backslash before backslashes and whitespace).
        let commandLine = ([command] + params).map(cgiEscape).joined(separator: " ")
        let body =
            "sessionid=\(formEncode(sessionID))&command=\(formEncode(commandLine))&stderr=0"
        request.httpBody = Data(body.utf8)

        let (data, http) = try await send(request, session: session, endpoint: endpoint)
        switch http.statusCode {
        case 200:
            return data
        case 403:
            // cgi-io: "Exec permission denied" / "Access to command denied by ACL".
            let message = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw UbusError.ubusStatus(6, message.isEmpty ? nil : message)
        default:
            throw UbusError.httpStatus(http.statusCode)
        }
    }

    private static func cgiEscape(_ argument: String) -> String {
        var escaped = ""
        for character in argument {
            if character == "\\" || character.isWhitespace { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
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
