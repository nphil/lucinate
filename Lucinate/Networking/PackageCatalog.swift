import Foundation

// MARK: - apk version ordering

/// apk-tools version ordering, ported from apk-tools `src/version.c`
/// (`apk_version_compare`). Version grammar:
/// `digit{.digit}...{letter}{_suf{#}}...{~hash}{-r#}`.
enum ApkVersion {
    private enum Token: Int, Comparable {
        case initialDigit, digit, letter, suffix, suffixNumber, commitHash, revision, end, invalid

        static func < (lhs: Token, rhs: Token) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Pre-release suffixes sort below "no suffix" (4); the rest above it.
    private static let suffixRanks: [String: Int] = [
        "alpha": 0, "beta": 1, "pre": 2, "rc": 3, "cvs": 5, "svn": 6, "git": 7, "hg": 8, "p": 9,
    ]
    private static let noSuffixRank = 4

    private struct State {
        var token: Token = .initialDigit
        var suffix = 0
        var number: UInt64 = 0
        var value: ArraySlice<UInt8> = []
    }

    private struct Cursor {
        let bytes: [UInt8]
        var pos = 0

        var peek: UInt8? { pos < bytes.count ? bytes[pos] : nil }

        mutating func span(while predicate: (UInt8) -> Bool) -> ArraySlice<UInt8> {
            let start = pos
            while let byte = peek, predicate(byte) { pos += 1 }
            return bytes[start..<pos]
        }
    }

    /// Orders `a` relative to `b` exactly as `apk version -t a b` does.
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        var cursorA = Cursor(bytes: Array(a.utf8))
        var cursorB = Cursor(bytes: Array(b.utf8))
        var tokenA = State()
        var tokenB = State()
        parseDigits(&tokenA, &cursorA)
        parseDigits(&tokenB, &cursorB)

        while tokenA.token == tokenB.token && tokenA.token < .end {
            let result = compareTokens(tokenA, tokenB)
            if result != .orderedSame { return result }
            next(&tokenA, &cursorA)
            next(&tokenB, &cursorB)
        }

        if tokenA.token == tokenB.token { return .orderedSame }
        // Equal so far: the longer version wins unless it continues with a
        // pre-release suffix (1.0_rc1 < 1.0).
        if tokenA.token == .suffix && tokenA.suffix < noSuffixRank { return .orderedAscending }
        if tokenB.token == .suffix && tokenB.suffix < noSuffixRank { return .orderedDescending }
        if tokenA.token > tokenB.token { return .orderedAscending }
        if tokenB.token > tokenA.token { return .orderedDescending }
        return .orderedSame
    }

    private static func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        isDigit(byte) || (byte >= 0x61 && byte <= 0x66) || (byte >= 0x41 && byte <= 0x46)
    }

    private static func isLowercaseLetter(_ byte: UInt8) -> Bool { byte >= 0x61 && byte <= 0x7A }

    private static func parseDigits(_ state: inout State, _ cursor: inout Cursor) {
        state.value = cursor.span(while: isDigit)
        state.number = state.value.reduce(0) { $0 &* 10 &+ UInt64($1 - 0x30) }
        if state.value.isEmpty { state.token = .invalid }
    }

    private static func next(_ state: inout State, _ cursor: inout Cursor) {
        guard let byte = cursor.peek else {
            state.token = .end
            return
        }
        switch byte {
        case 0x61...0x7A:  // a-z
            guard state.token <= .digit else { return state.token = .invalid }
            state.value = cursor.bytes[cursor.pos..<cursor.pos + 1]
            state.token = .letter
            cursor.pos += 1
        case 0x2E, 0x30...0x39:  // '.', 0-9
            if byte == 0x2E {
                guard state.token <= .digit else { return state.token = .invalid }
                cursor.pos += 1
            }
            switch state.token {
            case .initialDigit, .digit: state.token = .digit
            case .suffix: state.token = .suffixNumber
            default: return state.token = .invalid
            }
            parseDigits(&state, &cursor)
        case 0x5F:  // '_'
            guard state.token <= .suffixNumber else { return state.token = .invalid }
            cursor.pos += 1
            state.value = cursor.span(while: isLowercaseLetter)
            guard let rank = suffixRanks[String(decoding: state.value, as: UTF8.self)] else {
                return state.token = .invalid
            }
            state.suffix = rank
            state.token = .suffix
        case 0x7E:  // '~'
            guard state.token < .commitHash else { return state.token = .invalid }
            cursor.pos += 1
            state.value = cursor.span(while: isHexDigit)
            guard !state.value.isEmpty else { return state.token = .invalid }
            state.token = .commitHash
        case 0x2D:  // '-'
            guard state.token < .revision, cursor.pos + 1 < cursor.bytes.count,
                cursor.bytes[cursor.pos + 1] == 0x72  // 'r'
            else { return state.token = .invalid }
            cursor.pos += 2
            state.token = .revision
            parseDigits(&state, &cursor)
        default:
            state.token = .invalid
        }
    }

    private static func compareTokens(_ a: State, _ b: State) -> ComparisonResult {
        switch a.token {
        case .digit where a.value.first == 0x30 || b.value.first == 0x30:
            // A leading zero switches to string ordering (Gentoo rule).
            return compareBytes(a.value, b.value)
        case .digit, .initialDigit, .suffixNumber, .revision:
            return compareNumbers(a.number, b.number)
        case .letter:
            return compareNumbers(UInt64(a.value.first ?? 0), UInt64(b.value.first ?? 0))
        case .suffix:
            return compareNumbers(UInt64(a.suffix), UInt64(b.suffix))
        default:
            return compareBytes(a.value, b.value)
        }
    }

    private static func compareNumbers(_ a: UInt64, _ b: UInt64) -> ComparisonResult {
        a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
    }

    private static func compareBytes(_ a: ArraySlice<UInt8>, _ b: ArraySlice<UInt8>)
        -> ComparisonResult
    {
        if a.elementsEqual(b) { return .orderedSame }
        return a.lexicographicallyPrecedes(b) ? .orderedAscending : .orderedDescending
    }
}

// MARK: - Package lists and upgrade planning

/// An installed package that has a newer version in the configured feeds.
struct PackageUpgrade: Identifiable, Hashable, Sendable {
    let name: String
    let installedVersion: String
    let availableVersion: String

    var id: String { name }
}

enum PackageCatalogError: Error, LocalizedError {
    /// The package list wasn't apk's JSON — an opkg router.
    case notApk

    var errorDescription: String? {
        switch self {
        case .notApk:
            return "This router lists packages in opkg format. Package updates in Lucinate "
                + "need an apk-based router (OpenWrt 25.12 or newer)."
        }
    }
}

enum PackageCatalog {
    /// The fields the update flow needs from one `apk query --format json`
    /// record (what `package-manager-call list-installed|list-available`
    /// prints). Everything else in the record is skipped while decoding.
    struct Entry: Decodable, Sendable, Equatable {
        let name: String
        let version: String
    }

    /// Decodes a `package-manager-call list-*` reply. An empty reply (no
    /// package index yet) is an empty list; anything other than a JSON array
    /// means the router runs opkg.
    static func decode(_ data: Data) throws -> [Entry] {
        guard let first = data.first(where: { !$0.isWhitespaceByte }) else { return [] }
        guard first == UInt8(ascii: "[") else { throw PackageCatalogError.notApk }
        return try JSONDecoder().decode([Entry].self, from: data)
    }

    /// Installed packages whose newest available version is newer, in the
    /// order they should be installed (see `installTier`).
    static func upgrades(installed: [Entry], available: [Entry]) -> [PackageUpgrade] {
        var newest: [String: String] = [:]
        for entry in available {
            if let current = newest[entry.name],
                ApkVersion.compare(entry.version, current) != .orderedDescending
            {
                continue
            }
            newest[entry.name] = entry.version
        }

        var seen = Set<String>()
        var result: [PackageUpgrade] = []
        for entry in installed where seen.insert(entry.name).inserted {
            guard let candidate = newest[entry.name],
                ApkVersion.compare(candidate, entry.version) == .orderedDescending
            else { continue }
            result.append(
                PackageUpgrade(
                    name: entry.name, installedVersion: entry.version, availableVersion: candidate))
        }
        return result.sorted {
            let tiers = (installTier($0.name), installTier($1.name))
            return tiers.0 != tiers.1 ? tiers.0 < tiers.1 : $0.name < $1.name
        }
    }

    /// 0 = ordinary package. 1 = the stack this app talks through (web
    /// server, rpcd, LuCI, ucode, ubus). 2 = packages that can drop the
    /// network itself (interfaces, DHCP, firewall, Wi-Fi, VPNs, kernel
    /// modules). Higher tiers install last so a service restart can't strand
    /// the rest of the queue.
    static func installTier(_ name: String) -> Int {
        let network = [
            "netifd", "odhcp", "dnsmasq", "firewall", "nftables", "iptables", "wpad", "hostapd",
            "iw", "wireless-", "kmod-", "ppp", "tailscale", "wireguard", "travelmate", "mwan",
        ]
        let webStack = [
            "luci", "rpcd", "uhttpd", "cgi-io", "ucode", "libucode", "ubus", "libubus", "libubox",
            "procd",
        ]
        if network.contains(where: { name.hasPrefix($0) }) { return 2 }
        if webStack.contains(where: { name.hasPrefix($0) }) { return 1 }
        return 0
    }

    /// Package name → new version for every "Upgrading <name> (<old> -> <new>)"
    /// line in apk output, including dependencies apk pulled in.
    static func upgradedPackages(in output: String) -> [String: String] {
        var result: [String: String] = [:]
        for match in output.matches(of: #/Upgrading (\S+) \((\S+) -> (\S+)\)/#) {
            result[String(match.output.1)] = String(match.output.3)
        }
        return result
    }

    /// Shortens a version for display by dropping the `~commit` hash
    /// ("26.187.49110~99464ec" → "26.187.49110"); ordering is unaffected.
    static func displayVersion(_ version: String) -> String {
        version.replacing(#/~[0-9a-fA-F]+/#, with: "")
    }
}

private extension UInt8 {
    var isWhitespaceByte: Bool { self == 0x20 || self == 0x0A || self == 0x0D || self == 0x09 }
}
