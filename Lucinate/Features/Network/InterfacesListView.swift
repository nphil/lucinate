import SwiftUI
import UIKit

/// Interfaces segment of the Network hub: Wired then Wireless sections of
/// expandable cards (parity with interfaces_screen.dart), with auto-scroll
/// support driven by AppState.networkScrollTarget.
struct InterfacesListView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    var controller: InterfacesController
    @Binding var searchText: String

    @State private var expandedIDs: Set<String> = []

    var body: some View {
        let wiredShown = filteredWired
        let wirelessShown = filteredWireless
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: Spacing.sm) {
                    SearchField(text: $searchText, prompt: "Search interfaces…")
                    if controller.isLoading {
                        skeletonRows
                    } else if let error = controller.error, controller.isEmpty {
                        ErrorStateView(message: error) {
                            Task { await reload() }
                        }
                    } else if wiredShown.isEmpty && wirelessShown.isEmpty {
                        EmptyStateView(
                            systemImage: "point.3.connected.trianglepath.dotted",
                            title: "No interfaces found",
                            message: searchText.isEmpty
                                ? "Pull down to refresh."
                                : "No interfaces match your search."
                        )
                    } else {
                        if !wiredShown.isEmpty {
                            sectionHeader("Wired")
                            ForEach(wiredShown) { iface in
                                WiredInterfaceCard(
                                    iface: iface,
                                    peers: controller.wireGuardPeers[iface.name],
                                    isExpanded: expandedIDs.contains(wiredRowID(iface)),
                                    onToggle: { toggle(wiredRowID(iface)) }
                                )
                                .id(wiredRowID(iface))
                            }
                        }
                        if !wirelessShown.isEmpty {
                            sectionHeader("Wireless")
                            ForEach(wirelessShown) { network in
                                WirelessInterfaceCard(
                                    network: network,
                                    isExpanded: expandedIDs.contains(wirelessRowID(network)),
                                    onToggle: { toggle(wirelessRowID(network)) }
                                )
                                .id(wirelessRowID(network))
                            }
                        }
                    }
                }
                .padding(.horizontal, Spacing.md)
                .padding(.top, Spacing.sm)
                .padding(.bottom, Spacing.xxl)
            }
            .contentMargins(.top, 68, for: .scrollContent)
            .background(theme.background)
            .refreshable {
                Haptics.impact(.medium)
                await reload()
            }
            .task(id: appState.selectedRouterID) {
                await reload()
                consumeScrollTarget(proxy: proxy)
            }
            .onChange(of: appState.networkScrollTarget) {
                consumeScrollTarget(proxy: proxy)
            }
        }
    }

    private func reload() async {
        await controller.load(service: appState.service)
    }

    private func toggle(_ id: String) {
        Haptics.impact(.light)
        withAnimation(.snappy) {
            if expandedIDs.contains(id) {
                expandedIDs.remove(id)
            } else {
                expandedIDs.insert(id)
            }
        }
    }

    private func wiredRowID(_ iface: NetworkInterface) -> String { "wired-\(iface.name)" }
    private func wirelessRowID(_ network: WirelessNetwork) -> String { "wireless-\(network.id)" }

    // MARK: - Filtering

    private var filteredWired: [NetworkInterface] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return controller.wired }
        return controller.wired.filter { iface in
            if iface.name.lowercased().contains(query) { return true }
            if iface.device.lowercased().contains(query) { return true }
            if iface.protocolName.lowercased().contains(query) { return true }
            if let ip = iface.ipAddress, ip.lowercased().contains(query) { return true }
            return false
        }
    }

    private var filteredWireless: [WirelessNetwork] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return controller.wireless }
        return controller.wireless.filter { network in
            if network.ssid.lowercased().contains(query) { return true }
            if network.device.lowercased().contains(query) { return true }
            if network.radio.lowercased().contains(query) { return true }
            if let attached = network.network, attached.lowercased().contains(query) { return true }
            return false
        }
    }

    // MARK: - Auto-scroll (consume AppState.networkScrollTarget)

    private func consumeScrollTarget(proxy: ScrollViewProxy) {
        guard let target = appState.networkScrollTarget else { return }
        let lower = target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else {
            appState.networkScrollTarget = nil
            return
        }

        var rowID: String?
        if let iface = controller.wired.first(where: {
            $0.name.lowercased() == lower || $0.device.lowercased() == lower
        }) {
            rowID = wiredRowID(iface)
        } else if let network = controller.wireless.first(where: {
            $0.ssid.lowercased() == lower
                || $0.device.lowercased() == lower
                || $0.id.lowercased() == lower
        }) {
            rowID = wirelessRowID(network)
        }

        // No match yet: keep the target so the post-load pass can retry.
        guard let rowID else { return }

        appState.networkScrollTarget = nil
        withAnimation(.snappy) {
            _ = expandedIDs.insert(rowID)
        }
        // Let the expansion lay out before scrolling to the card.
        Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            withAnimation(.snappy) {
                proxy.scrollTo(rowID, anchor: .top)
            }
        }
    }

    // MARK: - Section header / skeletons

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.cardTitle)
            .foregroundStyle(theme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, Spacing.sm)
            .padding(.horizontal, Spacing.xs)
    }

    private var skeletonRows: some View {
        ForEach(0..<4, id: \.self) { _ in
            SkeletonBlock(height: 88, cornerRadius: CornerRadius.card)
        }
    }
}

// MARK: - Protocol display names

/// Human-readable label for a uci interface proto. Notably, proto "none" is
/// a valid unmanaged interface (e.g. Tailscale), not an error — show
/// "Unmanaged" instead of the raw token.
private func protocolDisplayName(_ raw: String) -> String {
    switch raw.lowercased() {
    case "", "none": return "Unmanaged"
    case "dhcp": return "DHCP"
    case "dhcpv6": return "DHCPv6"
    case "static": return "Static"
    case "pppoe": return "PPPoE"
    case "wireguard": return "WireGuard"
    default: return raw.capitalized
    }
}

// MARK: - Wired interface card

private struct WiredInterfaceCard: View {
    @Environment(\.theme) private var theme

    let iface: NetworkInterface
    let peers: [WireGuardPeer]?
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        Card {
            VStack(spacing: 0) {
                header
                    .contentShape(Rectangle())
                    .onTapGesture { onToggle() }
                if isExpanded {
                    Divider()
                        .padding(.vertical, Spacing.sm)
                    details
                }
            }
        }
        .grayscale(iface.isUp ? 0 : 1)
    }

    private var header: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: protoIcon)
                .font(.subheadline)
                .foregroundStyle(iface.isUp ? theme.accent : theme.textSecondary)
                .frame(width: 34, height: 34)
                .background(theme.accent.opacity(0.15), in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(iface.name.uppercased())
                    .font(.cardTitle)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: Spacing.sm)
            statusChip
            Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.textSecondary)
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
        }
    }

    /// "proto • ip (+N)" — mirrors _buildMinimalInterfaceSubtitle.
    private var subtitle: String {
        let proto = protocolDisplayName(iface.protocolName)
        var shown: String?
        var extra = 0
        if let ipv4 = iface.ipAddress, !ipv4.isEmpty {
            shown = ipv4
            if !iface.ipv6Addresses.isEmpty { extra = 1 }
        } else if let firstV6 = iface.ipv6Addresses.first {
            shown = firstV6
        }
        guard let shown else { return proto }
        if extra > 0 { return "\(proto) • \(shown)  +\(extra)" }
        return "\(proto) • \(shown)"
    }

    private var protoIcon: String {
        switch iface.protocolName.lowercased() {
        case "wireguard": return "shield"
        case "static": return "cable.connector"
        case "dhcp": return "network"
        default: return "point.3.connected.trianglepath.dotted"
        }
    }

    private var statusChip: some View {
        Text(iface.isUp ? "UP" : "OFF")
            .font(.caption2.weight(.bold))
            .foregroundStyle(iface.isUp ? theme.success : theme.textSecondary)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(
                iface.isUp ? theme.success.opacity(0.15) : theme.separator.opacity(0.5),
                in: .capsule
            )
    }

    private var details: some View {
        VStack(spacing: 0) {
            IfaceDetailRow(label: "Device", value: iface.device, monospaced: true)
            IfaceDetailRow(label: "Protocol", value: protocolDisplayName(iface.protocolName))
            IfaceDetailRow(label: "Uptime", value: iface.formattedUptime)
            if let ip = iface.ipAddress, !ip.isEmpty {
                IfaceDetailRow(label: "IP Address", value: ip, copyable: true, monospaced: true)
            }
            ForEach(iface.ipv6Addresses, id: \.self) { ipv6 in
                IfaceDetailRow(
                    label: "IPv6 Address", value: ipv6, copyable: true, monospaced: true)
            }
            if let gateway = iface.gateway {
                IfaceDetailRow(label: "Gateway", value: gateway, copyable: true, monospaced: true)
            }
            if !iface.dnsServers.isEmpty {
                IfaceDetailRow(
                    label: "DNS",
                    value: iface.dnsServers.joined(separator: ", "),
                    copyable: true,
                    monospaced: true
                )
            }
            if let peers, !peers.isEmpty {
                wireGuardSection(peers)
            }
            Divider()
                .padding(.vertical, Spacing.sm)
            trafficFooter
        }
    }

    private func wireGuardSection(_ peers: [WireGuardPeer]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Divider()
            Text("WireGuard Peers")
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.textSecondary)
            ForEach(peers) { peer in
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "key.fill")
                            .font(.caption)
                            .foregroundStyle(theme.accent)
                        Text(peer.truncatedKey)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                        if let name = peer.name {
                            Text(name)
                                .font(.caption)
                                .foregroundStyle(theme.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    HStack(spacing: Spacing.md) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Last Handshake")
                                .font(.caption2)
                                .foregroundStyle(theme.textSecondary)
                            Text(peer.handshakeDescription())
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(theme.textPrimary)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Endpoint")
                                .font(.caption2)
                                .foregroundStyle(theme.textSecondary)
                            Text(peer.endpoint ?? "N/A")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(theme.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .padding(.vertical, Spacing.xs)
            }
        }
        .padding(.top, Spacing.xs)
    }

    private var trafficFooter: some View {
        HStack(spacing: Spacing.lg) {
            Label(Format.bytes(Double(iface.rxBytes)), systemImage: "arrow.down")
                .font(.caption.weight(.medium))
                .foregroundStyle(theme.success)
            Label(Format.bytes(Double(iface.txBytes)), systemImage: "arrow.up")
                .font(.caption.weight(.medium))
                .foregroundStyle(theme.info)
            Spacer()
        }
    }
}

// MARK: - Wireless interface card

private struct WirelessInterfaceCard: View {
    @Environment(\.theme) private var theme

    let network: WirelessNetwork
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        Card {
            VStack(spacing: 0) {
                header
                    .contentShape(Rectangle())
                    .onTapGesture { onToggle() }
                if isExpanded {
                    Divider()
                        .padding(.vertical, Spacing.sm)
                    details
                }
            }
        }
        .grayscale(network.disabled ? 1 : 0)
    }

    private var title: String {
        if !network.ssid.isEmpty { return network.ssid }
        if !network.device.isEmpty { return network.device }
        return "Unnamed"
    }

    private var deviceLabel: String {
        network.device.isEmpty ? network.radio : network.device
    }

    private var channelText: String {
        if let channel = network.channel { return "\(channel)" }
        return "N/A"
    }

    private var header: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "wifi")
                .font(.subheadline)
                .foregroundStyle(network.disabled ? theme.textSecondary : theme.accent)
                .frame(width: 34, height: 34)
                .background(theme.accent.opacity(0.15), in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.cardTitle)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Text(
                    network.disabled
                        ? "\(network.mode.uppercased()) • Disabled"
                        : "\(network.mode.uppercased()) • Ch. \(channelText) • \(deviceLabel)"
                )
                .font(.subheadline)
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
            }
            Spacer(minLength: Spacing.sm)
            statusChip
            Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.textSecondary)
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
        }
    }

    private var statusChip: some View {
        Text(network.disabled ? "OFF" : "UP")
            .font(.caption2.weight(.bold))
            .foregroundStyle(network.disabled ? theme.textSecondary : theme.success)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(
                network.disabled ? theme.separator.opacity(0.5) : theme.success.opacity(0.15),
                in: .capsule
            )
    }

    private var details: some View {
        VStack(spacing: 0) {
            IfaceDetailRow(label: "Device", value: deviceLabel, monospaced: true)
            IfaceDetailRow(label: "Mode", value: network.mode.uppercased())
            IfaceDetailRow(label: "Channel", value: channelText)
            IfaceDetailRow(
                label: "Signal",
                value: network.signal.map { "\($0) dBm" } ?? "-- dBm"
            )
            IfaceDetailRow(label: "Network", value: network.network ?? "N/A")
        }
    }
}

// MARK: - Detail row (tap-to-copy)

private struct IfaceDetailRow: View {
    @Environment(\.theme) private var theme

    let label: String
    let value: String
    var copyable = false
    var monospaced = false

    @State private var showCopied = false

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Text(label)
                .font(.caption)
                .foregroundStyle(theme.textSecondary)
            Spacer(minLength: Spacing.sm)
            if showCopied {
                Text("Copied")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.accent)
                    .transition(.opacity)
            }
            Text(value)
                .font(.system(.footnote, design: monospaced ? .monospaced : .default))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            if copyable {
                Image(systemName: "doc.on.doc")
                    .font(.caption2)
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .padding(.vertical, Spacing.xs + 2)
        .contentShape(Rectangle())
        .onTapGesture {
            guard copyable else { return }
            copyValue()
        }
    }

    private func copyValue() {
        UIPasteboard.general.string = value
        Haptics.success()
        withAnimation(.snappy) { showCopied = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            withAnimation(.easeOut) { showCopied = false }
        }
    }
}
