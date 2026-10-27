import Foundation

/// Counting semaphore for structured concurrency. Gates concurrent ubus RPCs
/// (OpenWrt's uhttpd serves the CGI bridge with a tiny process cap).
actor AsyncSemaphore {
    private let limit: Int
    private var available: Int
    private var waiters: [(id: UInt64, continuation: CheckedContinuation<Void, Error>)] = []
    private var nextWaiterID: UInt64 = 0

    init(limit: Int) {
        self.limit = limit
        self.available = limit
    }

    /// Takes a permit, queueing behind earlier callers. A task cancelled while
    /// queued leaves the queue and throws `CancellationError`, so it never
    /// holds a place in line (or a permit) for a request nobody wants any more.
    func wait() async throws {
        try Task.checkCancellation()
        if available > 0 {
            available -= 1
            return
        }
        let id = nextWaiterID
        nextWaiterID &+= 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                waiters.append((id: id, continuation: continuation))
                // A cancellation that fired before the waiter was queued found
                // nobody to cancel; catch it here.
                if Task.isCancelled { cancelWaiter(id) }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    /// Runs on the actor, so it is ordered against `signal()`: whichever comes
    /// first removes the waiter, and only a waiter still queued is cancelled.
    /// One that already received its permit is untouched and releases it
    /// through `run`'s `defer`.
    private func cancelWaiter(_ id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    func signal() {
        if waiters.isEmpty {
            if available < limit { available += 1 }
        } else {
            // Hand the permit straight to the next waiter.
            waiters.removeFirst().continuation.resume()
        }
    }

    /// Runs `body` while holding a permit.
    func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        try await wait()
        defer { signal() }
        return try await body()
    }
}
