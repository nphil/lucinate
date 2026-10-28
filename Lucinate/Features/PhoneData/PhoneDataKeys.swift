import CryptoKit
import Foundation

// The iPhone's side of Phone Data's WireGuard keys: its own (server) key, and one entry per router
// it lets in. Foundation and CryptoKit only, so the address and load rules can be unit-tested
// without the Keychain or the engine. `PhoneDataController` is the only caller; the Keychain sits
// behind `PhoneDataSecretStore` (`PhoneDataKeychain`, in PhoneDataController.swift).

/// One router this iPhone lets in.
struct PhoneDataPeer: Codable, Equatable, Sendable, Identifiable {
    /// `Router.id` of the router.
    let routerID: String
    /// The router's public key, 32 bytes. Its private key is never kept on the iPhone.
    let publicKey: Data
    /// The router's address inside the tunnel, "10.7.0.N".
    let address: String
    var id: String { routerID }
}

/// What the router must be given at setup.
struct PhoneDataRouterKeys: Equatable, Sendable {
    /// The router's own private key, base64.
    let routerPrivateKey: String
    /// "10.7.0.N"
    let routerAddress: String
    /// Base64 of the public half of the iPhone's key.
    let phonePublicKey: String
}

/// Why the keys can't be used or changed, worded for the person using the app.
enum PhoneDataKeyError: Error, Equatable, LocalizedError {
    /// The Keychain wouldn't answer, as after a restart until the first unlock.
    case keysLocked
    /// Something is saved, but not in a form this version can use.
    case keysNeedReset
    case cannotSave
    /// All 253 tunnel addresses belong to routers already.
    case noFreeAddress

    var message: String {
        switch self {
        case .keysLocked: "Unlock this iPhone once so Lucinate can read its keys."
        case .keysNeedReset:
            "Lucinate can't read the Phone Data keys saved on this iPhone. Start over with new keys, then set up your routers again."
        case .cannotSave: "Lucinate couldn't save the Phone Data keys on this iPhone. Try again."
        case .noFreeAddress: "This iPhone is already set up with 253 routers. Remove one first."
        }
    }

    var errorDescription: String? { message }
}

/// The iPhone's key and the routers it lets in, as saved.
struct PhoneDataKeys: Codable, Equatable, Sendable {
    /// Routers get "10.7.0.N", N from 2 to 254. The iPhone itself needs no address.
    static let subnet = "10.7.0."
    static let hosts = 2...254

    var serverPrivateKey: Data
    /// In the order they were first set up.
    var peers: [PhoneDataPeer]

    static func new() -> PhoneDataKeys {
        PhoneDataKeys(serverPrivateKey: Curve25519.KeyAgreement.PrivateKey().rawRepresentation, peers: [])
    }

    var serverPublicKey: Data { Self.publicKey(of: serverPrivateKey) }

    /// Empty for anything but a 32-byte key.
    static func publicKey(of privateKey: Data) -> Data {
        (try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey))?.publicKey.rawRepresentation ?? Data()
    }

    /// The engine reads exactly 32 bytes behind every key it is given, so nothing else may get there.
    var isUsable: Bool {
        serverPrivateKey.count == 32 && peers.allSatisfy { $0.publicKey.count == 32 }
    }

    static func address(host: Int) -> String { subnet + String(host) }

    /// The lowest address no router has, or nil when all 253 are taken.
    var freeAddress: String? {
        let used = Set(peers.map(\.address))
        return Self.hosts.lazy.map(Self.address(host:)).first { !used.contains($0) }
    }

    /// A new key pair for `routerID`, which replaces the router's entry if it has one. The router
    /// keeps its address and its place in the list, so setting it up again changes nothing else.
    /// A router seen for the first time gets the lowest free address; nil when there is none.
    mutating func prepareRouter(routerID: String) -> PhoneDataRouterKeys? {
        let existing = peers.firstIndex { $0.routerID == routerID }
        let address: String
        if let existing {
            address = peers[existing].address
        } else if let free = freeAddress {
            address = free
        } else {
            return nil
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        let peer = PhoneDataPeer(routerID: routerID, publicKey: key.publicKey.rawRepresentation, address: address)
        if let existing { peers[existing] = peer } else { peers.append(peer) }
        return PhoneDataRouterKeys(
            routerPrivateKey: key.rawRepresentation.base64EncodedString(),
            routerAddress: address,
            phonePublicKey: serverPublicKey.base64EncodedString())
    }

    mutating func removeRouter(routerID: String) {
        peers.removeAll { $0.routerID == routerID }
    }

    /// Moves a router's entry to its new `Router.id` (its address or username changed). Its keys and
    /// tunnel address stay, so the router keeps working without being set up again.
    mutating func renameRouter(from oldID: String, to newID: String) {
        guard oldID != newID, let old = peers.first(where: { $0.routerID == oldID }) else { return }
        peers.removeAll { $0.routerID == newID }
        let moved = PhoneDataPeer(routerID: newID, publicKey: old.publicKey, address: old.address)
        if let at = peers.firstIndex(where: { $0.routerID == oldID }) { peers[at] = moved }
    }
}

/// Where the keys are kept. They are private keys, so the app keeps them in the Keychain.
protocol PhoneDataSecretStore: AnyObject {
    /// Nil when nothing is saved. Throws when something may be saved but can't be read now.
    func load() throws -> Data?
    func save(_ data: Data) throws
}

/// The saved keys. Nothing saved is fine and stays that way until the first router is set up, which
/// makes the iPhone's key. Anything else that goes wrong leaves the saved keys alone: nothing is
/// saved and no router can be added, so a Keychain that is locked for now, or keys this version
/// can't decode, never replace the key every router was set up with. `load()` tries again after a
/// locked Keychain, `reset()` gives up on keys that don't decode.
final class PhoneDataKeyStore {
    /// Nil until something is saved.
    private(set) var keys: PhoneDataKeys?
    /// Why the saved keys can't be used yet. Nil once the Keychain has answered, with keys or without.
    private(set) var problem: PhoneDataKeyError? = .keysLocked
    private let secrets: PhoneDataSecretStore

    init(secrets: PhoneDataSecretStore) {
        self.secrets = secrets
        load()
    }

    /// The Keychain has answered: there are keys, or there is nothing saved.
    var loaded: Bool { problem == nil }
    /// The saved keys are there but this version can't use them, so only `reset()` gets past it.
    var needsReset: Bool { problem == .keysNeedReset }
    var peers: [PhoneDataPeer] { keys?.peers ?? [] }

    /// Reads the saved keys, again after a failure. Does nothing once it has worked.
    func load() {
        guard !loaded else { return }
        do {
            guard let data = try secrets.load() else {
                keys = nil
                problem = nil
                return
            }
            guard let saved = try? JSONDecoder().decode(PhoneDataKeys.self, from: data), saved.isUsable else {
                problem = .keysNeedReset
                return
            }
            keys = saved
            problem = nil
        } catch {
            problem = .keysLocked
        }
    }

    /// A new key pair for the router, saved before it is returned. The iPhone's own key is made
    /// here the first time. Nothing changes when it can't be saved.
    func prepareRouter(routerID: String) throws -> PhoneDataRouterKeys {
        if let problem { throw problem }
        var updated = keys ?? PhoneDataKeys.new()
        guard let result = updated.prepareRouter(routerID: routerID) else { throw PhoneDataKeyError.noFreeAddress }
        try commit(updated)
        return result
    }

    /// Nothing changes when it can't be saved. Forgetting a router nobody set up does nothing.
    func forgetRouter(routerID: String) throws {
        if let problem { throw problem }
        guard var updated = keys, updated.peers.contains(where: { $0.routerID == routerID }) else { return }
        updated.removeRouter(routerID: routerID)
        try commit(updated)
    }

    /// Nothing changes when it can't be saved, or when the router was never set up.
    func renameRouter(from oldID: String, to newID: String) throws {
        if let problem { throw problem }
        guard var updated = keys, updated.peers.contains(where: { $0.routerID == oldID }) else { return }
        updated.renameRouter(from: oldID, to: newID)
        try commit(updated)
    }

    /// A new key for the iPhone and no routers, replacing saved keys this version can't use. Every
    /// router has to be set up again. Does nothing in any other case: a Keychain that is only locked
    /// may hold the right keys.
    func reset() throws {
        guard needsReset else { return }
        try commit(PhoneDataKeys.new())
    }

    private func commit(_ updated: PhoneDataKeys) throws {
        do {
            try secrets.save(JSONEncoder().encode(updated))
        } catch {
            throw PhoneDataKeyError.cannotSave
        }
        keys = updated
        problem = nil
    }
}
