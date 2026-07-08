import Combine
import SwiftUI

/// Home dashboard: device info, realtime throughput hero with chart, system
/// vitals, and wireless/interface quick-glance sections. Behavioral parity
/// with the Flutter dashboard screen.
struct HomeView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    @State private var controller = DashboardController()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.md) {
                content
            }
            .padding(Spacing.md)
        }
        .background(theme.background)
        .navigationTitle("Home")
        .refreshable {
            Haptics.impact(.medium)
            await reload()
        }
        .task {
            controller.loadPrefs(routerID: appState.selectedRouterID)
            guard let service = appState.service else { return }
            await controller.load(service: service)
        }
        .onChange(of: appState.selectedRouterID) { _, newID in
            controller.loadPrefs(routerID: newID)
            Task { await reload() }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
        ) { _ in
            // Picks up edits from the Customize Dashboard screen live.
            controller.loadPrefs(routerID: appState.selectedRouterID)
        }
    }

    private func reload() async {
        controller.loadPrefs(routerID: appState.selectedRouterID)
        guard let service = appState.service else { return }
        await controller.load(service: service)
        await appState.refreshBoardInfo()
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if controller.isLoading && !controller.hasData {
            skeletonCards
        } else if let error = controller.error, !controller.hasData {
            ErrorStateView(message: error) {
                Haptics.impact(.light)
                Task { await reload() }
            }
        } else {
            deviceInfoCard
            throughputCard
            vitalsCard
            let wireless = controller.visibleWireless
            if !wireless.isEmpty {
                wirelessSection(wireless)
            }
            let interfaces = controller.visibleInterfaces
            if !interfaces.isEmpty {
                interfacesSection(interfaces)
            }
        }
    }

    @ViewBuilder
    private var skeletonCards: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                SkeletonBlock(height: 20)
                SkeletonBlock(height: 14)
            }
        }
        Card {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                SkeletonBlock(height: 28)
                SkeletonBlock(height: 180)
            }
        }
        Card {
            SkeletonBlock(height: 90)
        }
    }

    // MARK: - Device info

    @ViewBuilder
    private var deviceInfoCard: some View {
        let board = appState.boardInfo
        let channel = releaseChannel
        Card {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack(alignment: .top, spacing: Spacing.sm) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(board["model"].stringValue ?? "OpenWrt Router")
                            .font(.cardTitle)
                            .foregroundStyle(theme.textPrimary)
                        Text(appState.hostname)
                            .font(.subheadline)
                            .foregroundStyle(theme.textSecondary)
                    }
                    Spacer(minLength: Spacing.sm)
                    chip(channel.label, color: channel.color)
                }
                if let description = board["release"]["description"].stringValue {
                    Text(description)
                        .font(.footnote)
                        .foregroundStyle(theme.textSecondary)
                }
            }
        }
    }

    /// Release channel parsed from the firmware description/version.
    private var releaseChannel: (label: String, color: Color) {
        let release = appState.boardInfo["release"]
        let text = [
            release["description"].stringValue ?? "",
            release["version"].stringValue ?? "",
        ].joined(separator: " ").uppercased()

        if text.contains("SNAPSHOT") { return ("SNAPSHOT", theme.warning) }
        if text.contains("BETA") { return ("BETA", theme.accent2) }
        if text.contains("RC") { return ("RC", theme.info) }
        if text.contains("TESTING") { return ("TESTING", theme.warning) }
        return ("STABLE", theme.success)
    }

    // MARK: - Throughput hero

    @ViewBuilder
    private var throughputCard: some View {
        let prefs = controller.prefs
        Card {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Realtime Throughput")
                        .font(.cardTitle)
                        .foregroundStyle(theme.textPrimary)
                    if !prefs.showAllThroughput,
                        let primary = prefs.primaryThroughputInterface, !primary.isEmpty
                    {
                        Text(primary)
                            .font(.caption)
                            .foregroundStyle(theme.textSecondary)
                    }
                }
                HStack(alignment: .top, spacing: Spacing.lg) {
                    throughputStat(
                        label: "Download",
                        systemImage: "arrow.down",
                        bytesPerSecond: appState.throughput.currentRx,
                        color: theme.success
                    )
                    throughputStat(
                        label: "Upload",
                        systemImage: "arrow.up",
                        bytesPerSecond: appState.throughput.currentTx,
                        color: theme.info
                    )
                    Spacer(minLength: 0)
                }
                ThroughputChart(points: appState.throughput.history)
            }
        }
    }

    private func throughputStat(
        label: String, systemImage: String, bytesPerSecond: Double, color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(label, systemImage: systemImage)
                .font(.statLabel)
                .foregroundStyle(color)
            Text(ThroughputCalculator.formatRate(bytesPerSecond: bytesPerSecond))
                .font(.statValue)
                .foregroundStyle(theme.textPrimary)
                .contentTransition(.numericText())
                .animation(.default, value: bytesPerSecond)
        }
    }

    // MARK: - System vitals

    private var vitalsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("System Vitals")
                    .font(.cardTitle)
                    .foregroundStyle(theme.textPrimary)
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 140), spacing: Spacing.md)],
                    alignment: .leading,
                    spacing: Spacing.md
                ) {
                    VitalTile(
                        systemImage: "cpu",
                        label: "CPU Load",
                        value: controller.cpuPercent.map { String(format: "%.0f%%", $0) }
                            ?? "N/A",
                        fraction: controller.cpuPercent.map { $0 / 100 }
                    )
                    VitalTile(
                        systemImage: "memorychip",
                        label: "Memory",
                        value: controller.memoryUsedPercent.map { String(format: "%.0f%%", $0) }
                            ?? "N/A",
                        subtitle: controller.memoryUsedText,
                        fraction: controller.memoryUsedPercent.map { $0 / 100 }
                    )
                    VitalTile(
                        systemImage: "clock",
                        label: "Uptime",
                        value: controller.uptimeText ?? "N/A"
                    )
                }
            }
        }
    }

    // MARK: - Wireless

    private func wirelessSection(_ networks: [WirelessNetwork]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Wireless")
                .font(.cardTitle)
                .foregroundStyle(theme.textPrimary)
            Card(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(networks.enumerated()), id: \.element.id) { index, network in
                        wirelessRow(network)
                        if index < networks.count - 1 {
                            Divider().overlay(theme.separator)
                        }
                    }
                }
            }
        }
    }

    private func wirelessRow(_ network: WirelessNetwork) -> some View {
        Button {
            Haptics.selection()
            appState.openInterface(named: network.device)
        } label: {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "wifi")
                    .foregroundStyle(network.disabled ? theme.textSecondary : theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(network.ssid)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    Text(network.device.isEmpty ? network.radio : network.device)
                        .font(.caption)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: Spacing.sm)
                if network.disabled {
                    chip("Disabled", color: theme.textSecondary)
                } else {
                    if let signal = network.signal {
                        chip("\(signal) dBm", color: theme.accent)
                    }
                    if let channel = network.channel {
                        chip("Ch \(channel)", color: theme.accent2)
                    }
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.textSecondary)
            }
            .padding(Spacing.md)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Interfaces

    private func interfacesSection(_ interfaces: [NetworkInterface]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Interfaces")
                .font(.cardTitle)
                .foregroundStyle(theme.textPrimary)
            Card(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(interfaces.enumerated()), id: \.element.id) { index, iface in
                        interfaceRow(iface)
                        if index < interfaces.count - 1 {
                            Divider().overlay(theme.separator)
                        }
                    }
                }
            }
        }
    }

    private func interfaceRow(_ iface: NetworkInterface) -> some View {
        Button {
            Haptics.selection()
            appState.openInterface(named: iface.name)
        } label: {
            HStack(spacing: Spacing.sm) {
                Image(systemName: Self.interfaceIcon(for: iface))
                    .foregroundStyle(theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(iface.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    Text(iface.protocolName)
                        .font(.caption)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: Spacing.sm)
                chip(
                    iface.isUp ? "UP" : "DOWN",
                    color: iface.isUp ? theme.success : theme.error
                )
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.textSecondary)
            }
            .padding(Spacing.md)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private static func interfaceIcon(for iface: NetworkInterface) -> String {
        switch iface.protocolName.lowercased() {
        case "wireguard", "tailscale": return "lock.shield"
        case "pppoe": return "phone.connection"
        case "dhcp", "static": return "cable.connector"
        case "wwan": return "antenna.radiowaves.left.and.right"
        default: return "network"
        }
    }

    // MARK: - Shared bits

    /// Capsule badge: 0.15-opacity fill of `color` with colored text.
    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: .capsule)
    }
}

/// One stat tile in the System Vitals grid: icon + label, big value, and an
/// optional subtitle plus percentage bar.
private struct VitalTile: View {
    var systemImage: String
    var label: String
    var value: String
    var subtitle: String? = nil
    var fraction: Double? = nil

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Label(label, systemImage: systemImage)
                .font(.statLabel)
                .foregroundStyle(theme.textSecondary)
            Text(value)
                .font(.statValue)
                .foregroundStyle(theme.textPrimary)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }
            if let fraction {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(theme.separator.opacity(0.5))
                        Capsule()
                            .fill(theme.accent)
                            .frame(width: max(4, proxy.size.width * min(max(fraction, 0), 1)))
                    }
                }
                .frame(height: 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
