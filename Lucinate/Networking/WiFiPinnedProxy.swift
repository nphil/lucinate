import Foundation
import Network

/// A tiny HTTP proxy on 127.0.0.1 that sends everything a web view loads out over Wi-Fi only.
///
/// WebKit's own networking follows iOS's default route, which is cellular while iOS considers the
/// Wi-Fi captive, so a plain web view would never see the hotel's sign-in page. Pointing
/// `WKWebsiteDataStore.proxyConfigurations` at this proxy moves the real connections, and their
/// DNS lookups, into the app, where every upstream socket requires Wi-Fi and prohibits cellular.
///
/// Handles `CONNECT host:port` tunnels (HTTPS, and plain HTTP when the client tunnels it) and
/// absolute-form plain HTTP requests, which are rewritten to origin-form and sent with
/// `Connection: close`. Only the app's own web view is meant to use it: it listens on loopback,
/// for as long as the sign-in sheet is open.
///
/// `@unchecked Sendable`: every mutable property of this class and of `Session` is read and
/// written only on `queue`, and every Network.framework callback and timer is scheduled on that
/// same serial queue.
final class WiFiPinnedProxy: @unchecked Sendable {
    enum StartError: Error {
        case bindFailed(String)
        case timedOut
        case stopped
    }

    private static let maxSessions = 48
    private static let startTimeout: TimeInterval = 3
    private static let headTimeout: TimeInterval = 15
    private static let connectTimeout = 10

    private let queue = DispatchQueue(label: "app.cogwheel.lucimobile.wifi-proxy")
    private var listener: NWListener?
    private var sessions: [ObjectIdentifier: Session] = [:]
    private var pendingStart: CheckedContinuation<NWEndpoint.Port, Error>?
    private var isStopped = false

    // MARK: - Lifecycle

    /// Binds 127.0.0.1 on an ephemeral port and returns it once the listener is ready.
    func start() async throws -> NWEndpoint.Port {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<NWEndpoint.Port, Error>) in
            queue.async { self.listen(continuation) }
        }
    }

    /// Cancels the listener and every live connection. Safe to call at any time, any number of
    /// times; a `start()` still waiting fails with `.stopped`.
    func stop() {
        queue.async { self.shutDown() }
    }

    private func listen(_ continuation: CheckedContinuation<NWEndpoint.Port, Error>) {
        guard !isStopped else {
            continuation.resume(throwing: StartError.stopped)
            return
        }
        guard listener == nil else {
            continuation.resume(throwing: StartError.bindFailed("Already started."))
            return
        }
        let parameters = NWParameters.tcp
        // Small TLS handshake writes must not wait on Nagle behind a delayed ACK.
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }
        // Bound to 127.0.0.1 on an ephemeral port, and `accept` refuses any peer that is not
        // loopback, so no other device on the Wi-Fi can use this phone as a proxy.
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let newListener: NWListener
        do {
            newListener = try NWListener(using: parameters)
        } catch {
            continuation.resume(throwing: StartError.bindFailed(error.localizedDescription))
            return
        }
        listener = newListener
        pendingStart = continuation
        newListener.stateUpdateHandler = { [weak self] state in self?.listenerChanged(state) }
        newListener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        newListener.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.startTimeout) { [weak self] in
            guard let self, self.pendingStart != nil else { return }
            self.failStart(.timedOut)
        }
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let port = listener?.port {
                resumeStart(.success(port))
            } else {
                failStart(.bindFailed("The listener has no port."))
            }
        case .failed(let error):
            failStart(.bindFailed(error.localizedDescription))
        case .cancelled:
            resumeStart(.failure(StartError.stopped))
        default:
            break
        }
    }

    private func resumeStart(_ result: Result<NWEndpoint.Port, Error>) {
        guard let continuation = pendingStart else { return }
        pendingStart = nil
        continuation.resume(with: result)
    }

    private func failStart(_ error: StartError) {
        resumeStart(.failure(error))
        listener?.cancel()
        listener = nil
    }

    private func shutDown() {
        isStopped = true
        resumeStart(.failure(StartError.stopped))
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        let live = Array(sessions.values)
        sessions.removeAll()
        for session in live { session.close() }
    }

    private func accept(_ connection: NWConnection) {
        guard !isStopped, sessions.count < Self.maxSessions,
            Self.isLoopbackPeer(connection.endpoint)
        else {
            connection.cancel()
            return
        }
        let session = Session(client: connection, queue: queue, owner: self)
        sessions[ObjectIdentifier(session)] = session
        session.start()
    }

    private func sessionClosed(_ session: Session) {
        sessions[ObjectIdentifier(session)] = nil
    }

    /// Second layer behind the loopback bind: refuse anything that is positively not loopback.
    private static func isLoopbackPeer(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return true }
        switch host {
        case .ipv4(let address): return address.isLoopback
        case .ipv6(let address): return address.isLoopback
        default: return true
        }
    }

    // MARK: - Request parsing (pure)

    static let maxHeadBytes = 64 * 1024

    enum Request: Equatable, Sendable {
        /// `CONNECT host:port`: answer 200, then pipe bytes both ways. `trailing` is whatever
        /// the client sent after the header, which belongs to the tunnel.
        case connect(host: String, port: UInt16, trailing: Data)
        /// Absolute-form plain HTTP: `head` is the request already rewritten to origin-form
        /// (header block included), `trailing` is the start of the body.
        case http(host: String, port: UInt16, head: Data, trailing: Data)

        var destination: (host: String, port: UInt16) {
            switch self {
            case .connect(let host, let port, _), .http(let host, let port, _, _):
                return (host, port)
            }
        }
    }

    enum Rejection: Equatable, Sendable {
        case malformed
        case headTooLarge
        /// An origin-form request, i.e. someone talking to the proxy as if it were the server.
        case notAProxyRequest
        /// Absolute-form with a scheme other than http; HTTPS arrives as CONNECT.
        case unsupportedScheme

        var httpStatus: (code: Int, reason: String) {
            switch self {
            case .headTooLarge: return (431, "Request Header Fields Too Large")
            default: return (400, "Bad Request")
            }
        }
    }

    enum ParseResult: Equatable, Sendable {
        /// The header block is not complete yet.
        case needMoreData
        case request(Request)
        case rejected(Rejection)
    }

    /// Hop-by-hop headers dropped from forwarded plain-HTTP requests. `Connection` is replaced
    /// by `Connection: close`: one request per upstream socket keeps the piping trivial.
    private static let droppedHeaders: Set<String> = [
        "connection", "proxy-connection", "keep-alive", "proxy-authorization",
    ]

    /// Parses what has been read from a client so far. Pure so it can be tested without sockets.
    static func parseRequest(_ buffered: Data) -> ParseResult {
        let bytes = [UInt8](buffered)
        guard let headEnd = HTTPWire.headEnd(in: bytes) else {
            return bytes.count > maxHeadBytes ? .rejected(.headTooLarge) : .needMoreData
        }
        guard headEnd <= maxHeadBytes else { return .rejected(.headTooLarge) }

        var lines = HTTPWire.lines(in: bytes[0..<headEnd])
        // RFC 9112 §2.2: empty lines ahead of the request line are ignored.
        while let first = lines.first, first.isEmpty { lines.removeFirst() }
        guard let requestLine = lines.first else { return .rejected(.malformed) }

        let parts = String(decoding: requestLine, as: UTF8.self)
            .split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return .rejected(.malformed) }
        let method = String(parts[0])
        let target = String(parts[1])
        let version = String(parts[2])
        let trailing = Data(bytes[headEnd...])

        if method.uppercased() == "CONNECT" {
            guard let (host, port) = parseAuthority(target, defaultPort: nil) else {
                return .rejected(.malformed)
            }
            return .request(.connect(host: host, port: port, trailing: trailing))
        }

        if target.hasPrefix("/") || target == "*" { return .rejected(.notAProxyRequest) }
        guard let schemeEnd = target.range(of: "://") else { return .rejected(.malformed) }
        guard target[..<schemeEnd.lowerBound].lowercased() == "http" else {
            return .rejected(.unsupportedScheme)
        }
        let afterScheme = target[schemeEnd.upperBound...]
        let authorityEnd =
            afterScheme.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" })
            ?? afterScheme.endIndex
        guard let (host, port) = parseAuthority(String(afterScheme[..<authorityEnd]), defaultPort: 80)
        else { return .rejected(.malformed) }

        var originForm = String(afterScheme[authorityEnd...])
        if let hash = originForm.firstIndex(of: "#") { originForm = String(originForm[..<hash]) }
        if originForm.isEmpty {
            originForm = "/"
        } else if originForm.hasPrefix("?") {
            originForm = "/" + originForm
        }

        var forwarded: [[UInt8]] = []
        var hasHost = false
        var dropping = false
        for line in lines.dropFirst().prefix(while: { !$0.isEmpty }) {
            // Obsolete line folding: a continuation belongs to the header above it.
            if line.first == 0x20 || line.first == 0x09 {
                if !dropping { forwarded.append(Array(line)) }
                continue
            }
            guard let header = HTTPWire.header(in: line) else {
                dropping = true
                continue
            }
            let name = header.name.lowercased()
            dropping = droppedHeaders.contains(name)
            if dropping { continue }
            if name == "host" { hasHost = true }
            forwarded.append(Array(line))
        }

        var head = Data("\(method) \(originForm) \(version)\r\n".utf8)
        if !hasHost {
            let literal = host.contains(":") ? "[\(host)]" : host
            let authority = port == 80 ? literal : "\(literal):\(port)"
            head.append(Data("Host: \(authority)\r\n".utf8))
        }
        for line in forwarded {
            head.append(contentsOf: line)
            head.append(contentsOf: [0x0D, 0x0A])
        }
        head.append(Data("Connection: close\r\n\r\n".utf8))
        return .request(.http(host: host, port: port, head: head, trailing: trailing))
    }

    /// `host`, `host:port` or `[v6]:port`, with any `user@` prefix dropped.
    private static func parseAuthority(_ text: String, defaultPort: UInt16?)
        -> (host: String, port: UInt16)?
    {
        var authority = Substring(text)
        if let at = authority.lastIndex(of: "@") { authority = authority[authority.index(after: at)...] }
        guard !authority.isEmpty else { return nil }

        let host: String
        var portText: Substring?
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { return nil }
            host = String(authority[authority.index(after: authority.startIndex)..<close])
            let rest = authority[authority.index(after: close)...]
            if rest.hasPrefix(":") {
                portText = rest.dropFirst()
            } else if !rest.isEmpty {
                return nil
            }
            guard isValidHost(host, bracketed: true) else { return nil }
        } else {
            if let colon = authority.lastIndex(of: ":") {
                host = String(authority[..<colon])
                portText = authority[authority.index(after: colon)...]
            } else {
                host = String(authority)
            }
            guard isValidHost(host, bracketed: false) else { return nil }
        }

        if let portText, !portText.isEmpty {
            guard let port = UInt16(portText), port != 0 else { return nil }
            return (host, port)
        }
        guard let defaultPort else { return nil }
        return (host, defaultPort)
    }

    /// Visible ASCII without URL delimiters; colons only inside an IPv6 literal.
    private static func isValidHost(_ host: String, bracketed: Bool) -> Bool {
        guard !host.isEmpty else { return false }
        for scalar in host.unicodeScalars {
            guard scalar.value > 0x20, scalar.value < 0x7F else { return false }
            switch Character(scalar) {
            case "/", "?", "#", "@", "\\", "[", "]": return false
            case ":": if !bracketed { return false }
            default: break
            }
        }
        return true
    }

    // MARK: - One client connection

    /// One client connection and, once the request is understood, its upstream twin.
    private final class Session: @unchecked Sendable {
        private enum Phase { case readingHead, connecting, relaying, closing, closed }

        private let client: NWConnection
        private let queue: DispatchQueue
        private weak var owner: WiFiPinnedProxy?
        private var upstream: NWConnection?
        private var request: Request?
        private var phase = Phase.readingHead
        private var headBuffer = Data()

        init(client: NWConnection, queue: DispatchQueue, owner: WiFiPinnedProxy) {
            self.client = client
            self.queue = queue
            self.owner = owner
        }

        func start() {
            client.stateUpdateHandler = { [weak self] state in self?.clientChanged(state) }
            client.start(queue: queue)
            receiveHead()
            queue.asyncAfter(deadline: .now() + WiFiPinnedProxy.headTimeout) { [weak self] in
                guard let self, self.phase == .readingHead else { return }
                self.close()
            }
        }

        func close() {
            guard phase != .closed else { return }
            phase = .closed
            client.stateUpdateHandler = nil
            upstream?.stateUpdateHandler = nil
            client.cancel()
            upstream?.cancel()
            upstream = nil
            owner?.sessionClosed(self)
        }

        private func clientChanged(_ state: NWConnection.State) {
            switch state {
            case .failed, .cancelled: close()
            default: break
            }
        }

        // MARK: Reading the request

        private func receiveHead() {
            client.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) {
                [weak self] data, _, isComplete, error in
                guard let self, self.phase == .readingHead else { return }
                if let data { self.headBuffer.append(data) }
                switch WiFiPinnedProxy.parseRequest(self.headBuffer) {
                case .request(let request):
                    self.connectUpstream(for: request)
                case .rejected(let rejection):
                    let status = rejection.httpStatus
                    self.respondAndClose(status: status.code, reason: status.reason)
                case .needMoreData:
                    if error != nil || isComplete { self.close() } else { self.receiveHead() }
                }
            }
        }

        // MARK: Upstream

        private func connectUpstream(for request: Request) {
            let destination = request.destination
            guard let port = NWEndpoint.Port(rawValue: destination.port) else {
                respondAndClose(status: 400, reason: "Bad Request")
                return
            }
            self.request = request
            phase = .connecting
            headBuffer = Data()

            let upstream = NWConnection(
                host: NWEndpoint.Host(destination.host), port: port,
                using: .wifiPinnedTCP(connectTimeout: WiFiPinnedProxy.connectTimeout))
            self.upstream = upstream
            upstream.stateUpdateHandler = { [weak self] state in self?.upstreamChanged(state) }
            upstream.start(queue: queue)
            // `.waiting` (no Wi-Fi path, DNS not answering) never fails on its own, so a deadline
            // turns it into an error page instead of an endless spinner.
            queue.asyncAfter(deadline: .now() + TimeInterval(WiFiPinnedProxy.connectTimeout)) {
                [weak self] in
                guard let self, self.phase == .connecting else { return }
                self.respondAndClose(status: 504, reason: "Gateway Timeout")
            }
        }

        private func upstreamChanged(_ state: NWConnection.State) {
            switch state {
            case .ready:
                if phase == .connecting { upstreamReady() }
            case .failed:
                if phase == .connecting {
                    respondAndClose(status: 502, reason: "Bad Gateway")
                } else {
                    close()
                }
            case .cancelled:
                if phase == .connecting || phase == .relaying { close() }
            default:
                break
            }
        }

        private func upstreamReady() {
            guard let upstream, let request else {
                close()
                return
            }
            phase = .relaying
            switch request {
            case .connect(_, _, let trailing):
                let accepted = Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)
                client.send(
                    content: accepted,
                    completion: .contentProcessed({ [weak self] error in
                        guard let self, self.phase == .relaying else { return }
                        if error != nil {
                            self.close()
                        } else if trailing.isEmpty {
                            self.startRelaying()
                        } else {
                            self.forwardThenRelay(trailing, to: upstream)
                        }
                    }))
            case .http(_, _, let head, let trailing):
                var outgoing = head
                outgoing.append(trailing)
                forwardThenRelay(outgoing, to: upstream)
            }
        }

        private func forwardThenRelay(_ data: Data, to upstream: NWConnection) {
            upstream.send(
                content: data,
                completion: .contentProcessed({ [weak self] error in
                    guard let self, self.phase == .relaying else { return }
                    if error != nil { self.close() } else { self.startRelaying() }
                }))
        }

        // MARK: Piping

        private func startRelaying() {
            guard phase == .relaying, let upstream else { return }
            relay(from: client, to: upstream)
            relay(from: upstream, to: client)
        }

        /// Copies one direction until EOF or an error, then tears down both sides. The next read
        /// is only issued once the previous chunk has been handed to the other socket, which is
        /// all the back-pressure a sign-in page needs.
        private func relay(from source: NWConnection, to sink: NWConnection) {
            source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                [weak self] data, _, isComplete, error in
                guard let self, self.phase == .relaying else { return }
                let ended = isComplete || error != nil
                if let data, !data.isEmpty {
                    sink.send(
                        content: data,
                        completion: .contentProcessed({ [weak self] sendError in
                            guard let self, self.phase == .relaying else { return }
                            if sendError != nil || ended {
                                self.close()
                            } else {
                                self.relay(from: source, to: sink)
                            }
                        }))
                } else if ended {
                    self.close()
                } else {
                    self.relay(from: source, to: sink)
                }
            }
        }

        // MARK: Errors

        private func respondAndClose(status: Int, reason: String) {
            guard phase != .closed, phase != .closing else { return }
            phase = .closing
            upstream?.stateUpdateHandler = nil
            upstream?.cancel()
            upstream = nil
            let response =
                "HTTP/1.1 \(status) \(reason)\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"
            client.send(
                content: Data(response.utf8),
                completion: .contentProcessed({ [weak self] _ in self?.close() }))
        }
    }
}
