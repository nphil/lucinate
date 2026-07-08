import Foundation

/// Counting semaphore for structured concurrency. Gates concurrent ubus RPCs
/// (OpenWrt's uhttpd serves the CGI bridge with a tiny process cap).
actor AsyncSemaphore {
    private let limit: Int
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
        self.available = limit
    }

    func wait() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else if available < limit {
            available += 1
        }
    }

    /// Runs `body` while holding a permit.
    func run<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        await wait()
        defer { signal() }
        return try await body()
    }
}
