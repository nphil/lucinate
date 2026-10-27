import Foundation
import Network

/// Asks "is this Wi-Fi really online?" over Wi-Fi only.
///
/// While iOS treats a Wi-Fi network as captive it keeps the interface up but will not use it as
/// the default route, so an ordinary URLSession request can leave over cellular and report an
/// internet connection the router does not have. This probe pins its socket, and with it the DNS
/// lookup, to Wi-Fi. It requests the page iOS's own check requests, so a portal answers it the
/// same way it answers the system.
enum WiFiPinnedProbe {
    enum Outcome: Sendable, Equatable {
        /// Apple's untouched "Success" page came back.
        case online
        /// Something else answered: a sign-in redirect (with its target when given) or a sign-in
        /// page served in place of Apple's.
        case captive(redirect: URL?)
        /// No Wi-Fi path, connect failure, upstream gateway error or timeout.
        case unreachable
    }

    static let host = "captive.apple.com"
    static let path = "/hotspot-detect.html"
    static let url = URL(string: "http://captive.apple.com/hotspot-detect.html")!

    static let defaultTimeout: TimeInterval = 6

    /// Apple's page is about 70 bytes; anything this large is a portal page and the verdict is
    /// long settled.
    static let maxResponseBytes = 64 * 1024

    /// Runs one check. Never throws; cancelling the calling task ends it as `.unreachable`.
    static func run(timeout: TimeInterval = defaultTimeout) async -> Outcome {
        let attempt = Attempt(timeout: timeout)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
                attempt.start(continuation)
            }
        } onCancel: {
            attempt.cancel()
        }
    }

    // MARK: - Response classification (pure)

    /// Verdict for a finished response: the connection closed or the read was cut off. A reply
    /// that is not HTTP at all, or no reply, is `.unreachable`.
    static func classify(_ response: Data) -> Outcome {
        guard let head = ResponseHead(response) else { return .unreachable }
        return head.outcome
    }

    /// Verdict as soon as the bytes received so far settle it, or nil while more bytes could
    /// still change the answer.
    static func earlyOutcome(_ received: Data) -> Outcome? {
        guard let head = ResponseHead(received), head.isHeadComplete else { return nil }
        guard head.status == 200 else { return head.outcome }
        if head.bodyContainsSuccess { return .online }
        if let length = head.contentLength, head.body.count >= length { return head.outcome }
        return nil
    }

    private struct ResponseHead {
        let status: Int
        let location: String?
        let contentLength: Int?
        let isHeadComplete: Bool
        let body: Data

        init?(_ data: Data) {
            let bytes = [UInt8](data)
            let headEnd = HTTPWire.headEnd(in: bytes)
            let lines = HTTPWire.lines(in: bytes[0..<(headEnd ?? bytes.count)])
            guard let statusLine = lines.first, let status = Self.parseStatus(in: statusLine) else {
                return nil
            }
            var location: String?
            var contentLength: Int?
            for line in lines.dropFirst() {
                guard let header = HTTPWire.header(in: line) else { continue }
                switch header.name.lowercased() {
                case "location":
                    if location == nil { location = header.value }
                case "content-length":
                    contentLength = Int(header.value)
                default:
                    break
                }
            }
            self.status = status
            self.location = location
            self.contentLength = contentLength
            self.isHeadComplete = headEnd != nil
            self.body = headEnd.map { Data(bytes[$0...]) } ?? Data()
        }

        var bodyContainsSuccess: Bool {
            String(decoding: body, as: UTF8.self).contains("Success")
        }

        var outcome: Outcome {
            switch status {
            case 200:
                return bodyContainsSuccess ? .online : .captive(redirect: nil)
            case 502, 503, 504:
                // A gateway that cannot reach the internet is "offline", not "needs sign-in".
                return .unreachable
            default:
                // 3xx sign-in redirect, 511 (network authentication required), or any other answer
                // that is not Apple's page: something on the path is intercepting.
                return .captive(redirect: redirectTarget)
            }
        }

        private var redirectTarget: URL? {
            guard let location, !location.isEmpty else { return nil }
            return URL(string: location, relativeTo: WiFiPinnedProbe.url)?.absoluteURL
        }

        private static func parseStatus(in line: ArraySlice<UInt8>) -> Int? {
            let parts = String(decoding: line, as: UTF8.self)
                .split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 2, parts[0].hasPrefix("HTTP/"), let code = Int(parts[1]),
                (100...599).contains(code)
            else { return nil }
            return code
        }
    }

    // MARK: - One attempt

    /// One connect → request → read cycle.
    ///
    /// `@unchecked Sendable`: every mutable property is read and written only on `queue`, and
    /// every Network.framework callback and timer is scheduled on that same serial queue.
    private final class Attempt: @unchecked Sendable {
        private let queue = DispatchQueue(label: "app.cogwheel.lucimobile.wifi-probe")
        private let timeout: TimeInterval
        private var continuation: CheckedContinuation<Outcome, Never>?
        private var connection: NWConnection?
        private var received = Data()
        private var isFinished = false

        init(timeout: TimeInterval) {
            self.timeout = timeout
        }

        func start(_ continuation: CheckedContinuation<Outcome, Never>) {
            queue.async { self.begin(continuation) }
        }

        func cancel() {
            queue.async { self.finish(.unreachable) }
        }

        private func begin(_ continuation: CheckedContinuation<Outcome, Never>) {
            // Cancelled before the work got going.
            guard !isFinished else {
                continuation.resume(returning: .unreachable)
                return
            }
            self.continuation = continuation
            let connection = NWConnection(
                host: NWEndpoint.Host(WiFiPinnedProbe.host),
                port: .http,
                using: .wifiPinnedTCP(connectTimeout: max(1, Int(timeout.rounded(.up)))))
            self.connection = connection
            connection.stateUpdateHandler = { [self] state in handle(state) }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { [self] in
                finish(WiFiPinnedProbe.classify(received))
            }
        }

        private func handle(_ state: NWConnection.State) {
            guard !isFinished else { return }
            switch state {
            case .ready:
                sendRequest()
            case .failed:
                finish(WiFiPinnedProbe.classify(received))
            default:
                // `.waiting` means no Wi-Fi path (or DNS not answering) right now; the overall
                // timeout decides, so a Wi-Fi that comes up a moment late still counts.
                break
            }
        }

        private func sendRequest() {
            // iOS's own check sends this User-Agent, so a gateway that special-cases it answers
            // the probe exactly as it answers the system.
            let request =
                "GET \(WiFiPinnedProbe.path) HTTP/1.1\r\n"
                + "Host: \(WiFiPinnedProbe.host)\r\n"
                + "User-Agent: CaptiveNetworkSupport-355.60.2 wispr\r\n"
                + "Accept: */*\r\n"
                + "Connection: close\r\n\r\n"
            connection?.send(
                content: Data(request.utf8),
                completion: .contentProcessed({ [self] error in
                    if error != nil {
                        finish(WiFiPinnedProbe.classify(received))
                    } else {
                        receive()
                    }
                }))
        }

        private func receive() {
            guard let connection, !isFinished else { return }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) {
                [self] data, _, isComplete, error in
                guard !isFinished else { return }
                if let data, !data.isEmpty { received.append(data) }
                if let early = WiFiPinnedProbe.earlyOutcome(received) {
                    finish(early)
                } else if received.count >= WiFiPinnedProbe.maxResponseBytes || isComplete
                    || error != nil
                {
                    finish(WiFiPinnedProbe.classify(received))
                } else {
                    receive()
                }
            }
        }

        private func finish(_ outcome: Outcome) {
            guard !isFinished else { return }
            isFinished = true
            connection?.stateUpdateHandler = nil
            connection?.cancel()
            connection = nil
            continuation?.resume(returning: outcome)
            continuation = nil
        }
    }
}

// MARK: - Shared with the proxy

extension NWParameters {
    /// TCP whose connections can only ever use Wi-Fi. Requiring `.wifi` is what binds the socket
    /// to the Wi-Fi interface even while iOS refuses to make it the default route; prohibiting
    /// cellular states the intent outright. Proxies are skipped so the probe and the tunnels
    /// measure the network itself.
    static func wifiPinnedTCP(connectTimeout: Int) -> NWParameters {
        let parameters = NWParameters.tcp
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.connectionTimeout = connectTimeout
            tcp.noDelay = true
        }
        parameters.requiredInterfaceType = .wifi
        parameters.prohibitedInterfaceTypes = [.cellular]
        parameters.preferNoProxies = true
        return parameters
    }
}

/// Byte-level HTTP/1.x helpers shared by the probe (responses) and the proxy (requests). Working
/// on bytes keeps header lines intact whatever their encoding.
enum HTTPWire {
    /// Offset just past the blank line that closes a header block (CRLF CRLF, or a bare LF LF),
    /// or nil while the block is still open.
    static func headEnd(in bytes: [UInt8]) -> Int? {
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x0A {
                if index + 1 < bytes.count, bytes[index + 1] == 0x0A { return index + 2 }
                if index + 2 < bytes.count, bytes[index + 1] == 0x0D, bytes[index + 2] == 0x0A {
                    return index + 3
                }
            }
            index += 1
        }
        return nil
    }

    /// Splits a header block into lines without their LF or CRLF terminators. The blank line that
    /// ends the block comes back as an empty slice.
    static func lines(in head: ArraySlice<UInt8>) -> [ArraySlice<UInt8>] {
        var result: [ArraySlice<UInt8>] = []
        var lineStart = head.startIndex
        var index = head.startIndex
        while index < head.endIndex {
            if head[index] == 0x0A {
                var lineEnd = index
                if lineEnd > lineStart, head[lineEnd - 1] == 0x0D { lineEnd -= 1 }
                result.append(head[lineStart..<lineEnd])
                lineStart = index + 1
            }
            index += 1
        }
        if lineStart < head.endIndex { result.append(head[lineStart..<head.endIndex]) }
        return result
    }

    /// `Name: value` with surrounding blanks trimmed, or nil for a line without a colon.
    static func header(in line: ArraySlice<UInt8>) -> (name: String, value: String)? {
        guard let colon = line.firstIndex(of: 0x3A) else { return nil }
        let name = String(decoding: line[line.startIndex..<colon], as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
        let value = String(decoding: line[(colon + 1)...], as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
        return (name, value)
    }
}
