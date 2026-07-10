import XCTest

@testable import Lucinate

final class ThroughputCalculatorTests: XCTestCase {

    // MARK: - Payload helpers

    private func devicePayload(_ counters: [String: (rx: Double, tx: Double)]) -> JSONValue {
        var devices: [String: JSONValue] = [:]
        for (name, bytes) in counters {
            devices[name] = .object([
                "stats": .object([
                    "rx_bytes": .number(bytes.rx),
                    "tx_bytes": .number(bytes.tx),
                ])
            ])
        }
        return .object(devices)
    }

    // MARK: - Ingest

    func testFirstIngestEmitsZeroPoint() {
        var calc = ThroughputCalculator()
        calc.ingest(
            devices: devicePayload(["eth0": (rx: 1000, tx: 500)]),
            includedDevices: [],
            now: 100
        )
        XCTAssertEqual(calc.history.count, 1)
        XCTAssertEqual(calc.currentRx, 0)
        XCTAssertEqual(calc.currentTx, 0)
    }

    func testSecondIngestComputesRate() {
        var calc = ThroughputCalculator()
        calc.ingest(
            devices: devicePayload(["eth0": (rx: 1000, tx: 500)]),
            includedDevices: [],
            now: 100
        )
        calc.ingest(
            devices: devicePayload(["eth0": (rx: 3000, tx: 1500)]),
            includedDevices: [],
            now: 102
        )
        XCTAssertEqual(calc.history.count, 2)
        // +2000 rx bytes over 2 seconds -> 1000 B/s.
        XCTAssertEqual(calc.currentRx, 1000, accuracy: 0.001)
        XCTAssertEqual(calc.currentTx, 500, accuracy: 0.001)
    }

    func testLoopbackIsExcluded() {
        var calc = ThroughputCalculator()
        calc.ingest(
            devices: devicePayload([
                "eth0": (rx: 1000, tx: 500),
                "lo": (rx: 0, tx: 0),
            ]),
            includedDevices: [],
            now: 100
        )
        calc.ingest(
            devices: devicePayload([
                "eth0": (rx: 3000, tx: 1500),
                "lo": (rx: 100_000_000, tx: 100_000_000),
            ]),
            includedDevices: [],
            now: 102
        )
        // Loopback's huge deltas must not appear in the totals.
        XCTAssertEqual(calc.currentRx, 1000, accuracy: 0.001)
        XCTAssertEqual(calc.currentTx, 500, accuracy: 0.001)
        XCTAssertNil(calc.perDeviceRates["lo"])
        XCTAssertNotNil(calc.perDeviceRates["eth0"])
    }

    func testAbsurdDeltaClampsToMaxRate() {
        var calc = ThroughputCalculator()
        calc.ingest(
            devices: devicePayload(["eth0": (rx: 0, tx: 0)]),
            includedDevices: [],
            now: 100
        )
        // 10x the clamp over 2 seconds.
        let absurd = ThroughputCalculator.maxRate * 10 * 2
        calc.ingest(
            devices: devicePayload(["eth0": (rx: absurd, tx: absurd)]),
            includedDevices: [],
            now: 102
        )
        XCTAssertEqual(calc.currentRx, ThroughputCalculator.maxRate, accuracy: 0.001)
        XCTAssertEqual(calc.currentTx, ThroughputCalculator.maxRate, accuracy: 0.001)
    }

    func testHistoryCapsAtLimit() {
        var calc = ThroughputCalculator()
        for i in 0..<60 {
            calc.ingest(
                devices: devicePayload(["eth0": (rx: Double(i) * 1000, tx: Double(i) * 500)]),
                includedDevices: [],
                now: TimeInterval(100 + i * 2)
            )
        }
        XCTAssertEqual(calc.history.count, ThroughputCalculator.historyLimit)
        XCTAssertEqual(ThroughputCalculator.historyLimit, 50)
    }

    // MARK: - aggregateDevices

    func testAggregateDevicesExcludesLoopback() {
        let dump: JSONValue = .object([
            "interface": .array([
                .object([
                    "interface": .string("lan"),
                    "device": .string("br-lan"),
                    "l3_device": .string("br-lan"),
                ]),
                .object([
                    "interface": .string("loopback"),
                    "device": .string("lo"),
                    "l3_device": .string("lo"),
                ]),
                .object([
                    "interface": .string("wan"),
                    "device": .string("eth0"),
                    "l3_device": .string("pppoe-wan"),
                ]),
            ])
        ])
        let devices = ThroughputCalculator.aggregateDevices(fromInterfaceDump: dump)
        XCTAssertEqual(devices, ["br-lan", "eth0", "pppoe-wan"])
        XCTAssertFalse(devices.contains("lo"))
    }

    // MARK: - device(fromPreference:)

    func testDeviceFromWirelessPreference() {
        XCTAssertEqual(
            ThroughputCalculator.device(fromPreference: "MySSID (phy0-ap0)"),
            "phy0-ap0"
        )
    }

    func testDeviceFromWiredPreferenceIsPassthrough() {
        XCTAssertEqual(ThroughputCalculator.device(fromPreference: "eth0"), "eth0")
    }

    // MARK: - formatRate

    func testFormatRateMbps() {
        // 125,000 B/s == 1,000,000 bits/s == 1.0 Mbps.
        XCTAssertEqual(ThroughputCalculator.formatRate(bytesPerSecond: 125_000), "1.0 Mbps")
    }
}
