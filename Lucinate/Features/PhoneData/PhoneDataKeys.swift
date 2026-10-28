import CryptoKit
import Foundation

// The iPhone's side of Phone Data's WireGuard keys: its own (server) key, and one entry per link of
// each router it lets in (a router can reach the iPhone over the USB cable and over Wi-Fi, each with
// a key pair and a tunnel address of its own). Foundation and CryptoKit only, so the address and load
// rules can be unit-tested without the Keychain or the engine. `PhoneDataController` is the only
// caller; the Keychain sits behind `PhoneDataSecretStore` (`PhoneDataKeychain`, in
// PhoneDataController.swift).

/// How a router reaches the iPhone. A router has one tunnel per link, each with a key pair and a
/// tunnel address of its own, so the cable and the Wi-Fi tunnel can both be up without fighting.
enum PhoneDataLink: String, Codable, Sendable, CaseIterable {
    /// Over the USB cable.
    case usb
    /// Through the iPhone's Personal Hotspot Wi-Fi.
    case wifi
}

/// One link of one router this iPhone lets in.
struct PhoneDataPeer: Codable, Equatable, Sendable, Identifiable {
    /// `Router.id` of the router.
    let routerID: String
    let link: PhoneDataLink
    /// The router's public key for this link, 32 bytes. Its private key is never kept on the iPhone.
    let publicKey: Data
    /// The router's address inside the tunnel for this link, "10.7.0.N".
    let address: String
    var id: String { "\(routerID)#\(link.rawValue)" }

    init(routerID: String, link: PhoneDataLink, publicKey: Data, address: String) {
        self.routerID = routerID
        self.link = link
        self.publicKey = publicKey
        self.address = address
    }

    private enum CodingKeys: String, CodingKey { case routerID, link, publicKey, address }

    /// Keys saved before Wi-Fi existed have no `link`: those routers were set up over USB.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        routerID = try values.decode(String.self, forKey: .routerID)
        link = try values.decodeIfPresent(PhoneDataLink.self, forKey: .link) ?? .usb
        publicKey = try values.decode(Data.self, forKey: .publicKey)
        address = try values.decode(String.self, forKey: .address)
    }
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
    /// The Keychain refused for another reason than being locked; the code is its OSStatus.
    case keychainFailed(Int32)
    case cannotSave
    /// All 253 tunnel addresses belong to routers already (a router uses one per link).
    case noFreeAddress

    var message: String {
        switch self {
        case .keysLocked: "Unlock this iPhone once so Lucinate can read its keys."
        case .keysNeedReset:
            "Lucinate can't read the Phone Data keys saved on this iPhone. Start over with new keys, then set up your routers again."
        case .keychainFailed(let code):
            "This iPhone's Keychain won't give Lucinate its Phone Data keys (error \(code)). Restart the iPhone, then try again."
        case .cannotSave: "Lucinate couldn't save the Phone Data keys on this iPhone. Try again."
        case .noFreeAddress: "This iPhone is already sharing with as many routers as it can. Remove one first."
        }
    }

    var errorDescription: String? { message }
}

/// The iPhone's key and the routers it lets in, as saved.
struct PhoneDataKeys: Codable, Equatable, Sendable {
    /// Routers get "10.7.0.N", N from 2 to 254, one address per link. The iPhone itself needs none.
    static let subnet = "10.7.0."
    static let hosts = 2...254

    var serverPrivateKey: Data
    /// In the order they were first set up, one entry per link of each router.
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

    /// The lowest address no link of any router has, or nil when all 253 are taken.
    var freeAddress: String? {
        let used = Set(peers.map(\.address))
        return Self.hosts.lazy.map(Self.address(host:)).first { !used.contains($0) }
    }

    func hasPeer(routerID: String, link: PhoneDataLink) -> Bool {
        peers.contains { $0.routerID == routerID && $0.link == link }
    }

    /// A new key pair for one link of `routerID`, which replaces that link's entry if it has one. The
    /// link keeps its address and its place in the list, so setting it up again changes nothing else,
    /// and the router's other link isn't touched. A link seen for the first time gets the lowest free
    /// address (no two links share one); nil when there is none.
    mutating func prepareRouter(routerID: String, link: PhoneDataLink) -> PhoneDataRouterKeys? {
        let existing = peers.firstIndex { $0.routerID == routerID && $0.link == link }
        let address: String
        if let existing {
            address = peers[existing].address
        } else if let free = freeAddress {
            address = free
        } else {
            return nil
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        let peer = PhoneDataPeer(
            routerID: routerID, link: link, publicKey: key.publicKey.rawRepresentation,
            address: address)
        if let existing { peers[existing] = peer } else { peers.append(peer) }
        return PhoneDataRouterKeys(
            routerPrivateKey: key.rawRepresentation.base64EncodedString(),
            routerAddress: address,
            phonePublicKey: serverPublicKey.base64EncodedString())
    }

    /// Forgets every link of the router.
    mutating func removeRouter(routerID: String) {
        peers.removeAll { $0.routerID == routerID }
    }

    /// Forgets one link of the router. Its other link stays, and the address is free again.
    mutating func removeLink(routerID: String, link: PhoneDataLink) {
        peers.removeAll { $0.routerID == routerID && $0.link == link }
    }

    /// Moves a router's entries, every link, to its new `Router.id` (its address or username
    /// changed). Their keys and tunnel addresses stay, so the router keeps working without being set
    /// up again. Entries already under the new id are replaced: the renamed router's keys win.
    mutating func renameRouter(from oldID: String, to newID: String) {
        guard oldID != newID, peers.contains(where: { $0.routerID == oldID }) else { return }
        peers.removeAll { $0.routerID == newID }
        peers = peers.map { peer in
            guard peer.routerID == oldID else { return peer }
            return PhoneDataPeer(
                routerID: newID, link: peer.link, publicKey: peer.publicKey, address: peer.address)
        }
    }

    /// The routers with a recent handshake, and over which links, given the tunnel addresses the
    /// engine says have one. A router with both links up appears once, with both.
    static func connectedLinks(
        of peers: [PhoneDataPeer], addresses: Set<String>
    ) -> [String: Set<PhoneDataLink>] {
        var connected: [String: Set<PhoneDataLink>] = [:]
        for peer in peers where addresses.contains(peer.address) {
            connected[peer.routerID, default: []].insert(peer.link)
        }
        return connected
    }
}

/// Where the keys are kept. They are private keys, so the app keeps them in the Keychain.
protocol PhoneDataSecretStore: AnyObject {
    /// Nil when nothing is saved. Throws when something may be saved but can't be read now.
    func load() throws -> Data?
    func save(_ data: Data) throws
}

/// What a secret store throws when it can't answer. Only `lockedForNow` is worth waiting out
/// (after a restart, until the first unlock); anything else is reported with its code.
struct PhoneDataSecretFailure: Error, Equatable, CustomStringConvertible {
    let code: Int32
    let lockedForNow: Bool
    var description: String { "Keychain error \(code)" }
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
        } catch let failure as PhoneDataSecretFailure where !failure.lockedForNow {
            problem = .keychainFailed(failure.code)
        } catch {
            problem = .keysLocked
        }
    }

    /// A new key pair for one link of the router, saved before it is returned. The iPhone's own key
    /// is made here the first time. Nothing changes when it can't be saved.
    func prepareRouter(routerID: String, link: PhoneDataLink) throws -> PhoneDataRouterKeys {
        if let problem { throw problem }
        var updated = keys ?? PhoneDataKeys.new()
        guard let result = updated.prepareRouter(routerID: routerID, link: link) else {
            throw PhoneDataKeyError.noFreeAddress
        }
        try commit(updated)
        return result
    }

    /// Every link of the router. Nothing changes when it can't be saved. Forgetting a router nobody
    /// set up does nothing.
    func forgetRouter(routerID: String) throws {
        if let problem { throw problem }
        guard var updated = keys, updated.peers.contains(where: { $0.routerID == routerID }) else { return }
        updated.removeRouter(routerID: routerID)
        try commit(updated)
    }

    /// One link of the router; its other link stays. Nothing changes when it can't be saved, or when
    /// the link was never set up.
    func forgetLink(routerID: String, link: PhoneDataLink) throws {
        if let problem { throw problem }
        guard var updated = keys, updated.hasPeer(routerID: routerID, link: link) else { return }
        updated.removeLink(routerID: routerID, link: link)
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
