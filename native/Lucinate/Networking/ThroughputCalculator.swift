import Foundation

/// Pure throughput math (§3.6). Feed it `luci-rpc getNetworkDevices` payloads
/// every ~2s; it tracks per-device byte counters and produces smoothed
/// rx/tx rates plus a 50-point ring buffer for the chart.
struct ThroughputCalculator: Sendable {
    struct Point: Sendable, Equatable, Identifiable {
        let id: Int
        let rxBytesPerSecond: Double
        let txBytesPerSecond: Double
        let timestamp: TimeInterval
    }

    static let historyLimit = 50
    static let maxRate: Double = 1000 * 1024 * 1024  // clamp: 1000 MiB/s

    private struct DeviceSnapshot {
        var rxBytes: Double
        var txBytes: Double
        var timestamp: TimeInterval
    }

    private var lastSnapshots: [String: DeviceSnapshot] = [:]
    private var nextPointID = 0
    private(set) var history: [Point] = []
    private(set) var perDeviceRates: [String: (rx: Double, tx: Double)] = [:]

    var currentRx: Double { history.last?.rxBytesPerSecond ?? 0 }
    var currentTx: Double { history.last?.txBytesPerSecond ?? 0 }

    /// - Parameters:
    ///   - devices: the `getNetworkDevices` result (object keyed by device name).
    ///   - includedDevices: devices to aggregate (non-loopback, from the
    ///     interface dump). Empty set = include everything except loopback.
    ///   - now: sample timestamp (injectable for tests).
    mutating func ingest(
        devices: JSONValue, includedDevices: Set<String>, now: TimeInterval
    ) {
        guard let deviceMap = devices.objectValue else { return }

        var totalRx = 0.0
        var totalTx = 0.0
        var sawAny = false
        var newRates: [String: (rx: Double, tx: Double)] = [:]

        for (name, info) in deviceMap {
            let lower = name.lowercased()
            if lower == "lo" || lower == "loopback" { continue }
            if !includedDevices.isEmpty && !includedDevices.contains(name) { continue }

            let stats = info["stats"]
            let rxBytes = stats["rx_bytes"].doubleValue ?? info["rx_bytes"].doubleValue ?? 0
            let txBytes = stats["tx_bytes"].doubleValue ?? info["tx_bytes"].doubleValue ?? 0

            if let last = lastSnapshots[name] {
                let elapsed = now - last.timestamp
                if elapsed >= 0.1 {
                    let rx = min(max(0, (rxBytes - last.rxBytes) / elapsed), Self.maxRate)
                    let tx = min(max(0, (txBytes - last.txBytes) / elapsed), Self.maxRate)
                    totalRx += rx
                    totalTx += tx
                    newRates[name] = (rx, tx)
                    sawAny = true
                }
            }
            lastSnapshots[name] = DeviceSnapshot(rxBytes: rxBytes, txBytes: txBytes, timestamp: now)
        }

        perDeviceRates = newRates

        // First sample (no baselines yet) emits an explicit zero point.
        let point = Point(
            id: nextPointID,
            rxBytesPerSecond: sawAny ? totalRx : 0,
            txBytesPerSecond: sawAny ? totalTx : 0,
            timestamp: now
        )
        nextPointID += 1
        history.append(point)
        if history.count > Self.historyLimit {
            history.removeFirst(history.count - Self.historyLimit)
        }
    }

    mutating func reset() {
        lastSnapshots.removeAll()
        history.removeAll()
        perDeviceRates.removeAll()
        nextPointID = 0
    }

    /// Devices to aggregate, derived from a `network.interface dump` result:
    /// every interface's `device` and `l3_device`, excluding loopback.
    static func aggregateDevices(fromInterfaceDump dump: JSONValue) -> Set<String> {
        var names: Set<String> = []
        for iface in dump["interface"].arrayValue ?? [] {
            for key in ["device", "l3_device"] {
                if let device = iface[key].stringValue, !device.isEmpty {
                    let lower = device.lowercased()
                    if lower != "lo" && lower != "loopback" {
                        names.insert(device)
                    }
                }
            }
        }
        return names
    }

    /// "SSID (device)" preference strings map to a device via the
    /// parenthesised suffix; wired prefs are the plain device name.
    static func device(fromPreference pref: String) -> String {
        if let open = pref.lastIndex(of: "("), let close = pref.lastIndex(of: ")"),
            open < close
        {
            return String(pref[pref.index(after: open)..<close])
        }
        return pref
    }

    /// Formats bytes/sec as the Flutter app did: bits with bps/Kbps/Mbps units.
    static func formatRate(bytesPerSecond: Double) -> String {
        let bits = bytesPerSecond * 8
        if bits >= 1_000_000 {
            return String(format: "%.1f Mbps", bits / 1_000_000)
        } else if bits >= 1_000 {
            return String(format: "%.1f Kbps", bits / 1_000)
        }
        return String(format: "%.0f bps", bits)
    }
}
