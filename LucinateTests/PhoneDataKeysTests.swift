import XCTest

@testable import Lucinate

final class PhoneDataKeysTests: XCTestCase {

    // MARK: - Helpers

    private struct Locked: Error {}

    /// The Keychain, minus the Keychain: it can be made to fail the way the real one does.
    private final class FakeSecrets: PhoneDataSecretStore {
        var data: Data?
        var loadError: Error?
        var saveError: Error?
        private(set) var saves = 0

        func load() throws -> Data? {
            if let loadError { throw loadError }
            return data
        }

        func save(_ data: Data) throws {
            if let saveError { throw saveError }
            saves += 1
            self.data = data
        }
    }

    /// Each router set up over the cable, in order.
    private func makeKeys(routers ids: [String]) throws -> PhoneDataKeys {
        var keys = PhoneDataKeys.new()
        for id in ids { _ = try XCTUnwrap(keys.prepareRouter(routerID: id, link: .usb)) }
        return keys
    }

    private func assertThrows<T>(
        _ expected: PhoneDataKeyError, _ body: @autoclosure () throws -> T,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(error as? PhoneDataKeyError, expected, file: file, line: line)
        }
    }

    // MARK: - Addresses

    func testFirstRouterGetsTheLowestAddress() throws {
        var keys = PhoneDataKeys.new()
        let router = try XCTUnwrap(keys.prepareRouter(routerID: "a", link: .usb))
        XCTAssertEqual(router.routerAddress, "10.7.0.2")
        XCTAssertEqual(keys.peers.map(\.address), ["10.7.0.2"])
    }

    func testRoutersGetTheNextAddressesInOrder() throws {
        let keys = try makeKeys(routers: ["a", "b", "c"])
        XCTAssertEqual(keys.peers.map(\.address), ["10.7.0.2", "10.7.0.3", "10.7.0.4"])
    }

    func testAForgottenRoutersAddressIsTheNextOneGiven() throws {
        var keys = try makeKeys(routers: ["a", "b", "c"])
        keys.removeRouter(routerID: "b")
        let router = try XCTUnwrap(keys.prepareRouter(routerID: "d", link: .usb))
        XCTAssertEqual(router.routerAddress, "10.7.0.3")
        // The others keep theirs.
        XCTAssertEqual(keys.peers.map(\.routerID), ["a", "c", "d"])
        XCTAssertEqual(keys.peers.map(\.address), ["10.7.0.2", "10.7.0.4", "10.7.0.3"])
    }

    func testSettingARouterUpAgainKeepsItsAddressAndPlaceButReplacesItsKey() throws {
        var keys = try makeKeys(routers: ["a", "b"])
        let oldKey = keys.peers[0].publicKey
        let again = try XCTUnwrap(keys.prepareRouter(routerID: "a", link: .usb))
        XCTAssertEqual(again.routerAddress, "10.7.0.2")
        XCTAssertEqual(keys.peers.map(\.routerID), ["a", "b"])
        XCTAssertEqual(keys.peers.map(\.address), ["10.7.0.2", "10.7.0.3"])
        XCTAssertNotEqual(keys.peers[0].publicKey, oldKey)
        // The key the router was given now is the one the iPhone accepts.
        let routerKey = try XCTUnwrap(Data(base64Encoded: again.routerPrivateKey))
        XCTAssertEqual(PhoneDataKeys.publicKey(of: routerKey), keys.peers[0].publicKey)
    }

    func testAFullTunnelTakesNoMoreRoutersButStillRenewsTheOnesItHas() throws {
        var keys = try makeKeys(routers: (0..<253).map { "r\($0)" })
        XCTAssertEqual(Set(keys.peers.map(\.address)).count, 253)
        XCTAssertEqual(keys.peers.first?.address, "10.7.0.2")
        XCTAssertEqual(keys.peers.last?.address, "10.7.0.254")
        XCTAssertNil(keys.freeAddress)
        XCTAssertNil(keys.prepareRouter(routerID: "one too many", link: .usb))
        XCTAssertEqual(keys.peers.count, 253)

        let renewed = try XCTUnwrap(keys.prepareRouter(routerID: "r100", link: .usb))
        XCTAssertEqual(renewed.routerAddress, "10.7.0.102")

        // Forgetting a router makes room, at its address.
        keys.removeRouter(routerID: "r100")
        let next = try XCTUnwrap(keys.prepareRouter(routerID: "one more", link: .usb))
        XCTAssertEqual(next.routerAddress, "10.7.0.102")
    }

    // MARK: - Keys

    func testTheRouterIsGivenTheKeyThatMatchesWhatTheIPhoneKeeps() throws {
        var keys = PhoneDataKeys.new()
        let router = try XCTUnwrap(keys.prepareRouter(routerID: "a", link: .usb))
        let routerPrivateKey = try XCTUnwrap(Data(base64Encoded: router.routerPrivateKey))
        XCTAssertEqual(routerPrivateKey.count, 32)
        XCTAssertEqual(PhoneDataKeys.publicKey(of: routerPrivateKey), keys.peers[0].publicKey)
        XCTAssertEqual(keys.serverPublicKey.count, 32)
        XCTAssertEqual(router.phonePublicKey, keys.serverPublicKey.base64EncodedString())
    }

    // MARK: - Links

    func testKeysSavedBeforeWiFiAreUSBLinks() throws {
        let key = Data(repeating: 7, count: 32).base64EncodedString()
        let saved = Data(
            """
            {"serverPrivateKey": "\(key)", "peers": [
              {"routerID": "a", "publicKey": "\(key)", "address": "10.7.0.2"},
              {"routerID": "b", "publicKey": "\(key)", "address": "10.7.0.3"}
            ]}
            """.utf8)

        let decoded = try JSONDecoder().decode(PhoneDataKeys.self, from: saved)
        XCTAssertEqual(decoded.peers.map(\.link), [.usb, .usb])
        XCTAssertTrue(decoded.isUsable)

        // They load like any saved keys, and the router's Wi-Fi link is one more entry.
        let secrets = FakeSecrets()
        secrets.data = saved
        let store = PhoneDataKeyStore(secrets: secrets)
        XCTAssertTrue(store.loaded)
        XCTAssertFalse(store.needsReset)
        XCTAssertEqual(store.peers.map(\.id), ["a#usb", "b#usb"])
        let wifi = try store.prepareRouter(routerID: "a", link: .wifi)
        XCTAssertEqual(wifi.routerAddress, "10.7.0.4")
        XCTAssertEqual(store.peers.map(\.id), ["a#usb", "b#usb", "a#wifi"])

        // Saved again, the link is written out, and comes back as it was.
        let reloaded = PhoneDataKeyStore(secrets: secrets)
        XCTAssertEqual(reloaded.keys, store.keys)
        XCTAssertEqual(reloaded.peers.map(\.link), [.usb, .usb, .wifi])
    }

    func testTheTwoLinksOfARouterHaveTheirOwnKeysAndAddresses() throws {
        var keys = PhoneDataKeys.new()
        let usb = try XCTUnwrap(keys.prepareRouter(routerID: "a", link: .usb))
        let wifi = try XCTUnwrap(keys.prepareRouter(routerID: "a", link: .wifi))
        XCTAssertEqual(usb.routerAddress, "10.7.0.2")
        XCTAssertEqual(wifi.routerAddress, "10.7.0.3")
        XCTAssertNotEqual(usb.routerPrivateKey, wifi.routerPrivateKey)
        XCTAssertEqual(keys.peers.map(\.id), ["a#usb", "a#wifi"])

        // Each link's router key matches what the iPhone accepts for that link.
        for (router, peer) in zip([usb, wifi], keys.peers) {
            let routerKey = try XCTUnwrap(Data(base64Encoded: router.routerPrivateKey))
            XCTAssertEqual(PhoneDataKeys.publicKey(of: routerKey), peer.publicKey)
            XCTAssertEqual(router.phonePublicKey, keys.serverPublicKey.base64EncodedString())
        }
    }

    func testSettingALinkUpAgainKeepsItsAddressAndLeavesTheOtherLinksAlone() throws {
        var keys = PhoneDataKeys.new()
        _ = try XCTUnwrap(keys.prepareRouter(routerID: "a", link: .usb))
        _ = try XCTUnwrap(keys.prepareRouter(routerID: "a", link: .wifi))
        _ = try XCTUnwrap(keys.prepareRouter(routerID: "b", link: .usb))
        let before = keys.peers

        let again = try XCTUnwrap(keys.prepareRouter(routerID: "a", link: .wifi))
        XCTAssertEqual(again.routerAddress, "10.7.0.3")
        XCTAssertEqual(keys.peers.map(\.id), ["a#usb", "a#wifi", "b#usb"])
        XCTAssertEqual(keys.peers.map(\.address), before.map(\.address))
        XCTAssertNotEqual(keys.peers[1].publicKey, before[1].publicKey)
        XCTAssertEqual(keys.peers[0], before[0])
        XCTAssertEqual(keys.peers[2], before[2])
    }

    func testForgettingOneLinkKeepsTheOtherAndFreesItsAddress() throws {
        var keys = PhoneDataKeys.new()
        _ = try XCTUnwrap(keys.prepareRouter(routerID: "a", link: .usb))
        _ = try XCTUnwrap(keys.prepareRouter(routerID: "a", link: .wifi))

        keys.removeLink(routerID: "a", link: .usb)
        XCTAssertEqual(keys.peers.map(\.id), ["a#wifi"])
        XCTAssertFalse(keys.hasPeer(routerID: "a", link: .usb))
        XCTAssertTrue(keys.hasPeer(routerID: "a", link: .wifi))
        XCTAssertEqual(try XCTUnwrap(keys.prepareRouter(routerID: "b", link: .usb)).routerAddress, "10.7.0.2")
    }

    func testForgettingARouterForgetsBothLinks() throws {
        var keys = PhoneDataKeys.new()
        _ = try XCTUnwrap(keys.prepareRouter(routerID: "a", link: .usb))
        _ = try XCTUnwrap(keys.prepareRouter(routerID: "b", link: .usb))
        _ = try XCTUnwrap(keys.prepareRouter(routerID: "a", link: .wifi))

        keys.removeRouter(routerID: "a")
        XCTAssertEqual(keys.peers.map(\.id), ["b#usb"])
    }

    func testRenamingARouterMovesBothLinksWithTheirKeysAndAddresses() throws {
        var keys = PhoneDataKeys.new()
        _ = try XCTUnwrap(keys.prepareRouter(routerID: "a", link: .usb))
        _ = try XCTUnwrap(keys.prepareRouter(routerID: "a", link: .wifi))
        _ = try XCTUnwrap(keys.prepareRouter(routerID: "c", link: .usb))
        let before = keys.peers

        keys.renameRouter(from: "a", to: "a2")
        XCTAssertEqual(keys.peers.map(\.id), ["a2#usb", "a2#wifi", "c#usb"])
        XCTAssertEqual(keys.peers.map(\.publicKey), before.map(\.publicKey))
        XCTAssertEqual(keys.peers.map(\.address), before.map(\.address))

        // Onto an id that has entries already: the renamed router's keys win, every link of it,
        // and nothing of the old entries is left over.
        keys.renameRouter(from: "a2", to: "c")
        XCTAssertEqual(keys.peers.map(\.id), ["c#usb", "c#wifi"])
        XCTAssertEqual(keys.peers.map(\.publicKey), [before[0].publicKey, before[1].publicKey])
    }

    func testTheStoreForgetsOneLinkAndSavesNothingForALinkThatWasNeverSetUp() throws {
        let secrets = FakeSecrets()
        let store = PhoneDataKeyStore(secrets: secrets)
        _ = try store.prepareRouter(routerID: "a", link: .usb)
        _ = try store.prepareRouter(routerID: "a", link: .wifi)
        XCTAssertEqual(secrets.saves, 2)

        try store.forgetLink(routerID: "a", link: .usb)
        XCTAssertEqual(secrets.saves, 3)
        XCTAssertEqual(store.peers.map(\.id), ["a#wifi"])

        // Already gone, and never set up.
        try store.forgetLink(routerID: "a", link: .usb)
        try store.forgetLink(routerID: "b", link: .wifi)
        XCTAssertEqual(secrets.saves, 3)
        XCTAssertEqual(store.peers.map(\.id), ["a#wifi"])
    }

    func testConnectedLinksSaysOverWhichLinkEachRouterIsUp() throws {
        var keys = PhoneDataKeys.new()
        _ = try XCTUnwrap(keys.prepareRouter(routerID: "a", link: .usb))  // 10.7.0.2
        _ = try XCTUnwrap(keys.prepareRouter(routerID: "a", link: .wifi))  // 10.7.0.3
        _ = try XCTUnwrap(keys.prepareRouter(routerID: "b", link: .usb))  // 10.7.0.4

        let none: [String: Set<PhoneDataLink>] = [:]
        XCTAssertEqual(PhoneDataKeys.connectedLinks(of: keys.peers, addresses: []), none)
        // An address nobody has isn't a router.
        XCTAssertEqual(PhoneDataKeys.connectedLinks(of: keys.peers, addresses: ["10.7.0.99"]), none)

        let onlyWiFi: [String: Set<PhoneDataLink>] = ["a": [.wifi]]
        XCTAssertEqual(PhoneDataKeys.connectedLinks(of: keys.peers, addresses: ["10.7.0.3"]), onlyWiFi)

        // Both links of a router are one router, with both.
        let all: [String: Set<PhoneDataLink>] = ["a": [.usb, .wifi], "b": [.usb]]
        XCTAssertEqual(
            PhoneDataKeys.connectedLinks(
                of: keys.peers, addresses: ["10.7.0.2", "10.7.0.3", "10.7.0.4"]),
            all)
    }

    // MARK: - Loading and saving

    func testNothingSavedMakesNoKeyUntilTheFirstRouterIsSetUp() throws {
        let secrets = FakeSecrets()
        let store = PhoneDataKeyStore(secrets: secrets)
        XCTAssertTrue(store.loaded)
        XCTAssertNil(store.keys)
        XCTAssertEqual(secrets.saves, 0)

        let router = try store.prepareRouter(routerID: "a", link: .usb)
        XCTAssertEqual(router.routerAddress, "10.7.0.2")
        XCTAssertEqual(secrets.saves, 1)
    }

    func testTheSavedKeysComeBackWithTheSameIPhoneKey() throws {
        let secrets = FakeSecrets()
        let first = PhoneDataKeyStore(secrets: secrets)
        _ = try first.prepareRouter(routerID: "a", link: .usb)
        _ = try first.prepareRouter(routerID: "b", link: .usb)

        let second = PhoneDataKeyStore(secrets: secrets)
        XCTAssertEqual(second.keys, first.keys)
        XCTAssertEqual(second.peers.map(\.routerID), ["a", "b"])
    }

    func testALockedKeychainIsNotTakenForNoKeys() throws {
        let secrets = FakeSecrets()
        let before = PhoneDataKeyStore(secrets: secrets)
        _ = try before.prepareRouter(routerID: "a", link: .usb)
        let savedBytes = try XCTUnwrap(secrets.data)
        let savedKey = try XCTUnwrap(before.keys).serverPrivateKey

        // After a restart, before the first unlock.
        secrets.loadError = Locked()
        let store = PhoneDataKeyStore(secrets: secrets)
        XCTAssertFalse(store.loaded)
        XCTAssertEqual(store.problem, .keysLocked)
        XCTAssertFalse(store.needsReset)
        assertThrows(.keysLocked, try store.prepareRouter(routerID: "b", link: .usb))
        assertThrows(.keysLocked, try store.forgetRouter(routerID: "a"))
        assertThrows(.keysLocked, try store.forgetLink(routerID: "a", link: .usb))
        store.load()
        XCTAssertFalse(store.loaded)
        XCTAssertEqual(secrets.data, savedBytes)
        XCTAssertEqual(secrets.saves, 1)

        // The first unlock: the same key comes back, not a new one.
        secrets.loadError = nil
        store.load()
        XCTAssertTrue(store.loaded)
        XCTAssertEqual(store.keys?.serverPrivateKey, savedKey)
        XCTAssertEqual(store.peers.map(\.routerID), ["a"])
    }

    func testResetDoesNothingWhileTheKeychainIsOnlyLocked() throws {
        let secrets = FakeSecrets()
        secrets.loadError = Locked()
        let store = PhoneDataKeyStore(secrets: secrets)
        try store.reset()
        XCTAssertEqual(secrets.saves, 0)
        XCTAssertFalse(store.loaded)
    }

    func testKeysThisVersionCantReadAreKeptUntilReset() throws {
        let secrets = FakeSecrets()
        let unreadable = Data("not keys".utf8)
        secrets.data = unreadable
        let store = PhoneDataKeyStore(secrets: secrets)
        XCTAssertFalse(store.loaded)
        XCTAssertTrue(store.needsReset)
        assertThrows(.keysNeedReset, try store.prepareRouter(routerID: "a", link: .usb))
        XCTAssertEqual(secrets.data, unreadable)
        XCTAssertEqual(secrets.saves, 0)

        try store.reset()
        XCTAssertTrue(store.loaded)
        XCTAssertFalse(store.needsReset)
        XCTAssertEqual(store.peers, [])
        XCTAssertEqual(secrets.saves, 1)
        XCTAssertEqual(try store.prepareRouter(routerID: "a", link: .usb).routerAddress, "10.7.0.2")
    }

    func testKeysOfTheWrongSizeCountAsUnreadable() throws {
        var bad = PhoneDataKeys.new()
        bad.serverPrivateKey = Data(repeating: 1, count: 16)
        let secrets = FakeSecrets()
        secrets.data = try JSONEncoder().encode(bad)
        XCTAssertTrue(PhoneDataKeyStore(secrets: secrets).needsReset)
    }

    func testAFailedSaveChangesNothing() throws {
        let secrets = FakeSecrets()
        let store = PhoneDataKeyStore(secrets: secrets)
        _ = try store.prepareRouter(routerID: "a", link: .usb)
        let saved = secrets.data

        secrets.saveError = Locked()
        assertThrows(.cannotSave, try store.prepareRouter(routerID: "b", link: .usb))
        assertThrows(.cannotSave, try store.prepareRouter(routerID: "a", link: .wifi))
        assertThrows(.cannotSave, try store.forgetRouter(routerID: "a"))
        assertThrows(.cannotSave, try store.forgetLink(routerID: "a", link: .usb))
        XCTAssertEqual(store.peers.map(\.id), ["a#usb"])
        XCTAssertEqual(secrets.data, saved)
    }

    func testNoKeyIsKeptWhenTheFirstSaveFails() throws {
        let secrets = FakeSecrets()
        secrets.saveError = Locked()
        let store = PhoneDataKeyStore(secrets: secrets)
        assertThrows(.cannotSave, try store.prepareRouter(routerID: "a", link: .usb))
        XCTAssertNil(store.keys)
        XCTAssertNil(secrets.data)
    }

    func testForgettingARouterThatWasNeverSetUpSavesNothing() throws {
        let secrets = FakeSecrets()
        let store = PhoneDataKeyStore(secrets: secrets)
        _ = try store.prepareRouter(routerID: "a", link: .usb)
        try store.forgetRouter(routerID: "b")
        XCTAssertEqual(secrets.saves, 1)
        XCTAssertEqual(store.peers.map(\.routerID), ["a"])
    }

    func testAKeychainThatFailsForOtherReasonsIsNotReportedAsLocked() throws {
        let secrets = FakeSecrets()
        secrets.loadError = PhoneDataSecretFailure(code: -34018, lockedForNow: false)
        let store = PhoneDataKeyStore(secrets: secrets)
        XCTAssertEqual(store.problem, .keychainFailed(-34018))
        assertThrows(.keychainFailed(-34018), try store.prepareRouter(routerID: "a", link: .usb))
        XCTAssertNil(secrets.data)

        secrets.loadError = PhoneDataSecretFailure(code: -25308, lockedForNow: true)
        store.load()
        XCTAssertEqual(store.problem, .keysLocked)
    }

    func testARenamedRouterKeepsItsKeyAndAddress() throws {
        var keys = try makeKeys(routers: ["a", "b", "c"])
        let before = keys.peers[1]
        keys.renameRouter(from: "b", to: "b2")
        XCTAssertEqual(keys.peers.map(\.routerID), ["a", "b2", "c"])
        XCTAssertEqual(keys.peers[1].publicKey, before.publicKey)
        XCTAssertEqual(keys.peers[1].address, before.address)

        // Onto an id that already has an entry: the renamed router's keys win, no duplicate.
        keys.renameRouter(from: "b2", to: "a")
        XCTAssertEqual(keys.peers.map(\.routerID), ["a", "c"])
        XCTAssertEqual(keys.peers[0].publicKey, before.publicKey)
    }
}
