import Foundation
import LucinateWG

// The Swift side of Phone Data's engine: PhoneDataEngine/ (Go), linked in as LucinateWG.xcframework.
// It is adapted from Tether's WireGuardServer.swift, see PhoneDataEngine/README.md.

/// Byte totals that only grow, so a reader can take the difference of two.
struct PhoneDataTraffic: Equatable, Sendable {
    var bytesUp: UInt64 = 0
    var bytesDown: UInt64 = 0
}

/// Runs the WireGuard server from PhoneDataEngine/. Only the main actor calls it. The Go side is
/// thread-safe and quick, so nothing here waits.
@MainActor
final class PhoneDataServer {
    /// The WireGuard port on the hotspot address. The routers are set up to reach it.
    nonisolated static let port: UInt16 = 51820

    private(set) var running = false
    private var carried = CarriedTraffic()

    /// The tunnel addresses of the routers with a recent handshake: set up and working, also
    /// before they sent anything. From the last `snapshot()`, so both describe the same moment.
    private(set) var connectedAddresses: Set<String> = []

    /// Listens on the hotspot address only, and lets in exactly `peers`. Replaces a server that is
    /// already running.
    func start(host: String, serverPrivateKey: Data, peers: [PhoneDataPeer]) throws {
        stop()
        // Go reads exactly 32 bytes behind each key pointer.
        guard serverPrivateKey.count == 32 else { throw Failure(message: "the phone key isn't 32 bytes") }
        let error = serverPrivateKey.withUnsafeBytes { key in
            host.withCString { h in
                LucinateWGStart(UnsafeMutablePointer(mutating: h), Int32(Self.port),
                                UnsafeMutablePointer(mutating: key.bindMemory(to: UInt8.self).baseAddress))
            }
        }
        if let message = takeGoString(error) { throw Failure(message: message) }
        running = true
        do {
            try setPeers(peers)
        } catch {
            // Not left half started: the controller retries a server that isn't running.
            LucinateWGStop()
            running = false
            throw error
        }
    }

    func stop() {
        guard running else { return }
        carried.absorb(currentRun())
        LucinateWGStop()
        running = false
        connectedAddresses = []
    }

    /// Lets in exactly these routers. A removed router's open connections are closed. Does nothing
    /// while the server isn't running: `start` takes the routers then.
    func setPeers(_ peers: [PhoneDataPeer]) throws {
        guard running else { return }
        guard peers.allSatisfy({ $0.publicKey.count == 32 }) else { throw Failure(message: "a router key isn't 32 bytes") }
        var keys = Data()
        for peer in peers { keys.append(peer.publicKey) }
        // The addresses come in the order of the keys. The server finds out which router sends for
        // other devices by itself, see noticeRouter in PhoneDataEngine/server.go.
        let addresses = peers.map(\.address).joined(separator: "\n")
        let error = keys.withUnsafeBytes { k in
            addresses.withCString { a in
                LucinateWGSetPeers(UnsafeMutablePointer(mutating: k.bindMemory(to: UInt8.self).baseAddress),
                                   UnsafeMutablePointer(mutating: a), Int32(peers.count))
            }
        }
        if let message = takeGoString(error) { throw Failure(message: message) }
    }

    /// Gives memory Go's GC has freed back to iOS, on a memory warning.
    func freeMemory() {
        if running { LucinateWGFreeMemory() }
    }

    /// Counters that only grow, across restarts. Also refreshes `connectedAddresses`.
    func snapshot() -> PhoneDataTraffic {
        carried.apply(to: running ? currentRun() : PhoneDataTraffic())
    }

    private func currentRun() -> PhoneDataTraffic {
        guard let json = takeGoString(LucinateWGStats()), let data = json.data(using: .utf8),
              let stats = try? JSONDecoder().decode(GoStats.self, from: data) else {
            connectedAddresses = []
            return PhoneDataTraffic()
        }
        connectedAddresses = Set(stats.connected ?? [])
        return PhoneDataTraffic(bytesUp: stats.up, bytesDown: stats.down)
    }

    /// What the engine reports when it can't do what it was asked, in its own words.
    struct Failure: LocalizedError, CustomStringConvertible {
        let message: String
        var description: String { message }
        var errorDescription: String? { message }
    }
}

/// The parts of LucinateWGStats' JSON the app uses, see Stats in PhoneDataEngine/server.go.
private struct GoStats: Decodable {
    let up: UInt64
    let down: UInt64
    let connected: [String]?
}

/// The server starts from zero each time the hotspot comes back, while readers expect counters
/// that only grow. This carries what earlier runs counted.
private struct CarriedTraffic {
    private var carried = PhoneDataTraffic()

    /// Call with a run's last counters when it stops.
    mutating func absorb(_ last: PhoneDataTraffic) {
        carried.bytesUp += last.bytesUp
        carried.bytesDown += last.bytesDown
    }

    func apply(to current: PhoneDataTraffic) -> PhoneDataTraffic {
        PhoneDataTraffic(bytesUp: carried.bytesUp + current.bytesUp, bytesDown: carried.bytesDown + current.bytesDown)
    }
}

/// Reads and frees a string Go returned.
private func takeGoString(_ p: UnsafeMutablePointer<CChar>?) -> String? {
    guard let p else { return nil }
    defer { LucinateWGFree(p) }
    return String(cString: p)
}
