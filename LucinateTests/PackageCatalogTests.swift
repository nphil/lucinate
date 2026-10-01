import XCTest

@testable import Lucinate

final class PackageCatalogTests: XCTestCase {

    // MARK: - ApkVersion

    /// Expected orderings captured from `apk version -t` on OpenWrt 25.12.5.
    func testCompareMatchesApk() {
        let cases: [(String, ComparisonResult, String)] = [
            ("26.187.49110~99464ec", .orderedAscending, "26.270.72870~a24d1f2"),
            ("2026.01.16~85922056-r1", .orderedAscending, "2026.01.16~85922056-r2"),
            ("2.4.6-r1", .orderedAscending, "2.4.9-r3"),
            ("8.19.0-r2", .orderedAscending, "8.22.0-r1"),
            ("1.0_rc1", .orderedAscending, "1.0"),
            ("1.0", .orderedAscending, "1.0_p1"),
            ("1.0_alpha", .orderedAscending, "1.0_beta"),
            ("1.0a", .orderedDescending, "1.0"),
            ("1.0.01", .orderedAscending, "1.0.1"),
            ("1.0.2", .orderedAscending, "1.0.10"),
            ("1.0", .orderedAscending, "1.0-r0"),
            ("1.0~abc", .orderedDescending, "1.0"),
            ("20260601-r1", .orderedAscending, "20260816-r1"),
            ("1.2.3", .orderedSame, "1.2.3"),
        ]
        for (a, expected, b) in cases {
            XCTAssertEqual(ApkVersion.compare(a, b), expected, "\(a) vs \(b)")
            let mirrored: ComparisonResult =
                expected == .orderedAscending
                ? .orderedDescending : (expected == .orderedDescending ? .orderedAscending : .orderedSame)
            XCTAssertEqual(ApkVersion.compare(b, a), mirrored, "\(b) vs \(a)")
        }
    }

    // MARK: - Upgrade planning

    private func entry(_ name: String, _ version: String) -> PackageCatalog.Entry {
        PackageCatalog.Entry(name: name, version: version)
    }

    func testUpgradesPickNewestAndSkipEqualOrOlder() {
        let installed = [
            entry("curl", "8.19.0-r2"),
            entry("busybox", "1.37.0-r4"),
            entry("custom", "2.0-r1"),
            entry("orphan", "1.0"),
        ]
        let available = [
            entry("curl", "8.22.0-r1"),
            entry("curl", "8.20.0-r1"),
            entry("busybox", "1.37.0-r4"),
            entry("custom", "1.9-r1"),
        ]
        let upgrades = PackageCatalog.upgrades(installed: installed, available: available)
        XCTAssertEqual(upgrades.map(\.name), ["curl"])
        XCTAssertEqual(upgrades.first?.installedVersion, "8.19.0-r2")
        XCTAssertEqual(upgrades.first?.availableVersion, "8.22.0-r1")
    }

    func testConnectionCriticalPackagesInstallLast() {
        let names = ["netifd", "luci-base", "curl", "rpcd", "tailscale", "ca-bundle"]
        let upgrades = PackageCatalog.upgrades(
            installed: names.map { entry($0, "1.0") },
            available: names.map { entry($0, "2.0") })
        XCTAssertEqual(
            upgrades.map(\.name), ["ca-bundle", "curl", "luci-base", "rpcd", "netifd", "tailscale"])
    }

    // MARK: - Parsing

    func testUpgradedPackagesIncludesDependencies() {
        let output = """
            (1/2) Upgrading libcurl4 (8.19.0-r2 -> 8.22.0-r1)
            (2/2) Upgrading curl (8.19.0-r2 -> 8.22.0-r1)
            OK: 214 MiB in 187 packages
            """
        XCTAssertEqual(
            PackageCatalog.upgradedPackages(in: output),
            ["libcurl4": "8.22.0-r1", "curl": "8.22.0-r1"])
    }

    func testDecodeRejectsOpkgAndAcceptsEmpty() throws {
        XCTAssertThrowsError(try PackageCatalog.decode(Data("Package: busybox\n".utf8)))
        XCTAssertEqual(try PackageCatalog.decode(Data("  \n".utf8)), [])
        let json = #"[{"name":"curl","version":"8.22.0-r1","depends":["libc"]}]"#
        XCTAssertEqual(try PackageCatalog.decode(Data(json.utf8)), [entry("curl", "8.22.0-r1")])
    }

    func testDisplayVersionDropsCommitHash() {
        XCTAssertEqual(PackageCatalog.displayVersion("2026.01.16~85922056-r1"), "2026.01.16-r1")
        XCTAssertEqual(PackageCatalog.displayVersion("8.22.0-r1"), "8.22.0-r1")
    }
}
