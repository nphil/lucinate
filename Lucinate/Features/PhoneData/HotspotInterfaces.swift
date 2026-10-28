import Foundation

/// Finds the iPhone's own address on its Personal Hotspot network, which is where Phone Data listens.
enum HotspotInterfaces {
    struct Address: Equatable, Sendable {
        let interface: String
        let ip: String
    }

    /// iOS Personal Hotspot always gives the iPhone 172.20.10.1, on a bridge interface that exists
    /// only while a device is on the hotspot (a USB cable counts). Matching the subnet, not only the
    /// name, keeps other bridges out. Nil when the hotspot isn't there.
    static func hotspotAddress() -> String? {
        hotspotAddress(among: ipv4())
    }

    static func hotspotAddress(among addresses: [Address]) -> String? {
        addresses.first { $0.interface.hasPrefix("bridge") && $0.ip.hasPrefix("172.20.10.") }?.ip
    }

    /// Every IPv4 address on this iPhone except loopback.
    static func ipv4() -> [Address] {
        var out: [Address] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return out }
        defer { freeifaddrs(head) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = entry.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            if name == "lo0" { continue }
            // Network byte order, so the first octet is the top byte once swapped.
            let raw = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            let ip = "\((raw >> 24) & 0xFF).\((raw >> 16) & 0xFF).\((raw >> 8) & 0xFF).\(raw & 0xFF)"
            out.append(Address(interface: name, ip: ip))
        }
        return out
    }
}
