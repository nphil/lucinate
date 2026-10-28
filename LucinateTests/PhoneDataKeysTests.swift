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

    private func makeKeys(routers ids: [String]) throws -> PhoneDataKeys {
        var keys = PhoneDataKeys.new()
        for id in ids { _ = try XCTUnwrap(keys.prepareRouter(routerID: id)) }
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
        let router = try XCTUnwrap(keys.prepareRouter(routerID: "a"))
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
        let router = try XCTUnwrap(keys.prepareRouter(routerID: "d"))
        XCTAssertEqual(router.routerAddress, "10.7.0.3")
        // The others keep theirs.
        XCTAssertEqual(keys.peers.map(\.routerID), ["a", "c", "d"])
        XCTAssertEqual(keys.peers.map(\.address), ["10.7.0.2", "10.7.0.4", "10.7.0.3"])
    }

    func testSettingARouterUpAgainKeepsItsAddressAndPlaceButReplacesItsKey() throws {
        var keys = try makeKeys(routers: ["a", "b"])
        let oldKey = keys.peers[0].publicKey
        let again = try XCTUnwrap(keys.prepareRouter(routerID: "a"))
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
        XCTAssertNil(keys.prepareRouter(routerID: "one too many"))
        XCTAssertEqual(keys.peers.count, 253)

        let renewed = try XCTUnwrap(keys.prepareRouter(routerID: "r100"))
        XCTAssertEqual(renewed.routerAddress, "10.7.0.102")

        // Forgetting a router makes room, at its address.
        keys.removeRouter(routerID: "r100")
        let next = try XCTUnwrap(keys.prepareRouter(routerID: "one more"))
        XCTAssertEqual(next.routerAddress, "10.7.0.102")
    }

    // MARK: - Keys

    func testTheRouterIsGivenTheKeyThatMatchesWhatTheIPhoneKeeps() throws {
        var keys = PhoneDataKeys.new()
        let router = try XCTUnwrap(keys.prepareRouter(routerID: "a"))
        let routerPrivateKey = try XCTUnwrap(Data(base64Encoded: router.routerPrivateKey))
        XCTAssertEqual(routerPrivateKey.count, 32)
        XCTAssertEqual(PhoneDataKeys.publicKey(of: routerPrivateKey), keys.peers[0].publicKey)
        XCTAssertEqual(keys.serverPublicKey.count, 32)
        XCTAssertEqual(router.phonePublicKey, keys.serverPublicKey.base64EncodedString())
    }

    // MARK: - Loading and saving

    func testNothingSavedMakesNoKeyUntilTheFirstRouterIsSetUp() throws {
        let secrets = FakeSecrets()
        let store = PhoneDataKeyStore(secrets: secrets)
        XCTAssertTrue(store.loaded)
        XCTAssertNil(store.keys)
        XCTAssertEqual(secrets.saves, 0)

        let router = try store.prepareRouter(routerID: "a")
        XCTAssertEqual(router.routerAddress, "10.7.0.2")
        XCTAssertEqual(secrets.saves, 1)
    }

    func testTheSavedKeysComeBackWithTheSameIPhoneKey() throws {
        let secrets = FakeSecrets()
        let first = PhoneDataKeyStore(secrets: secrets)
        _ = try first.prepareRouter(routerID: "a")
        _ = try first.prepareRouter(routerID: "b")

        let second = PhoneDataKeyStore(secrets: secrets)
        XCTAssertEqual(second.keys, first.keys)
        XCTAssertEqual(second.peers.map(\.routerID), ["a", "b"])
    }

    func testALockedKeychainIsNotTakenForNoKeys() throws {
        let secrets = FakeSecrets()
        let before = PhoneDataKeyStore(secrets: secrets)
        _ = try before.prepareRouter(routerID: "a")
        let savedBytes = try XCTUnwrap(secrets.data)
        let savedKey = try XCTUnwrap(before.keys).serverPrivateKey

        // After a restart, before the first unlock.
        secrets.loadError = Locked()
        let store = PhoneDataKeyStore(secrets: secrets)
        XCTAssertFalse(store.loaded)
        XCTAssertEqual(store.problem, .keysLocked)
        XCTAssertFalse(store.needsReset)
        assertThrows(.keysLocked, try store.prepareRouter(routerID: "b"))
        assertThrows(.keysLocked, try store.forgetRouter(routerID: "a"))
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
        assertThrows(.keysNeedReset, try store.prepareRouter(routerID: "a"))
        XCTAssertEqual(secrets.data, unreadable)
        XCTAssertEqual(secrets.saves, 0)

        try store.reset()
        XCTAssertTrue(store.loaded)
        XCTAssertFalse(store.needsReset)
        XCTAssertEqual(store.peers, [])
        XCTAssertEqual(secrets.saves, 1)
        XCTAssertEqual(try store.prepareRouter(routerID: "a").routerAddress, "10.7.0.2")
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
        _ = try store.prepareRouter(routerID: "a")
        let saved = secrets.data

        secrets.saveError = Locked()
        assertThrows(.cannotSave, try store.prepareRouter(routerID: "b"))
        assertThrows(.cannotSave, try store.forgetRouter(routerID: "a"))
        XCTAssertEqual(store.peers.map(\.routerID), ["a"])
        XCTAssertEqual(secrets.data, saved)
    }

    func testNoKeyIsKeptWhenTheFirstSaveFails() throws {
        let secrets = FakeSecrets()
        secrets.saveError = Locked()
        let store = PhoneDataKeyStore(secrets: secrets)
        assertThrows(.cannotSave, try store.prepareRouter(routerID: "a"))
        XCTAssertNil(store.keys)
        XCTAssertNil(secrets.data)
    }

    func testForgettingARouterThatWasNeverSetUpSavesNothing() throws {
        let secrets = FakeSecrets()
        let store = PhoneDataKeyStore(secrets: secrets)
        _ = try store.prepareRouter(routerID: "a")
        try store.forgetRouter(routerID: "b")
        XCTAssertEqual(secrets.saves, 1)
        XCTAssertEqual(store.peers.map(\.routerID), ["a"])
    }
}
