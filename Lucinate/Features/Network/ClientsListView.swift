import SwiftUI
import UIKit

/// Clients segment of the Network hub: expandable client cards with an
/// All Routers / This Router scope switch (parity with clients_screen.dart).
struct ClientsListView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    var controller: ClientsController
    @Binding var searchText: String

    @State private var expandedIDs: Set<String> = []
    @State private var reserveClient: Client?
    @State private var blockCandidate: Client?
    @State private var showBlockConfirm = false
    @State private var speeds = ClientSpeedsController()

    var body: some View {
        let filtered = controller.filtered(query: searchText)
        ScrollView {
            LazyVStack(spacing: Spacing.sm) {
                SearchField(text: $searchText, prompt: "Search by name, IP, MAC…")
                if controller.isLoading {
                    skeletonRows
                } else if let error = controller.error, controller.clients.isEmpty {
                    ErrorStateView(message: error) {
                        Task { await reload() }
                    }
                } else {
                    headerRow(count: filtered.count)
                    if filtered.isEmpty {
                        EmptyStateView(
                            systemImage: "person.2.slash",
                            title: "No clients found",
                            message: searchText.isEmpty
                                ? "No clients are currently connected. Pull down to refresh."
                                : "No clients match your search. Try a different term."
                        )
                    } else {
                        ForEach(filtered) { client in
                            ClientCard(
                                client: client,
                                speeds: speeds,
                                isExpanded: expandedIDs.contains(client.id),
                                isBlocked: controller.blockedMACs.contains(
                                    client.macAddress.uppercased()),
                                canAct: canAct(on: client),
                                wolAvailable: controller.wolAvailable,
                                onToggle: { toggle(client.id) },
                                onReserve: { reserveClient = client },
                                onWake: { wake(client) },
                                onBlockToggle: { toggleBlock(client) }
                            )
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
            speeds.stop()
            await reload()
            await startSpeedPolling()
        }
        .onDisappear { speeds.stop() }
        .sheet(item: $reserveClient) { client in
            NavigationStack {
                StaticLeasesView(
                    prefillMAC: client.macAddress,
                    prefillIP: client.ipAddress == "N/A" ? nil : client.ipAddress,
                    prefillName: client.hostname == "Unknown" ? nil : client.hostname
                )
            }
        }
        .confirmationDialog(
            "Block \(blockCandidate?.hostname ?? "Client")?",
            isPresented: $showBlockConfirm,
            titleVisibility: .visible,
            presenting: blockCandidate
        ) { client in
            Button("Block Internet", role: .destructive) {
                Haptics.warning()
                block(client)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This device will lose internet access (LAN still works).")
        }
    }

    private func reload() async {
        await controller.load(service: appState.service, routers: appState.routers)
    }

    /// Starts live speed polling against the ACTIVE router's wireless
    /// ifnames. Aggregate-mode clients from other routers simply never get a
    /// rate published (no badge). Tolerates failures silently.
    private func startSpeedPolling() async {
        guard let service = appState.service else { return }
        guard let json = try? await service.wirelessDevices() else { return }
        let devices = Set(
            WirelessNetwork.fromWirelessDevices(json)
                .map(\.device)
                .filter { !$0.isEmpty }
        )
        guard !devices.isEmpty, !Task.isCancelled else { return }
        speeds.start(service: service, devices: Array(devices))
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

    // MARK: - Client quick actions (selected-router mode only)

    /// In aggregate mode the actions would hit the ACTIVE router, which may
    /// not be the one the client belongs to — hide them there.
    private func canAct(on client: Client) -> Bool {
        !controller.aggregateAll && appState.service != nil && client.macAddress != "N/A"
    }

    private func wake(_ client: Client) {
        guard let service = appState.service else { return }
        Task {
            do {
                try await service.wakeOnLan(mac: client.macAddress)
                Haptics.success()
                appState.showToast("Magic packet sent to \(client.hostname)")
            } catch {
                Haptics.warning()
                appState.showToast(error.localizedDescription)
            }
        }
    }

    private func toggleBlock(_ client: Client) {
        if controller.blockedMACs.contains(client.macAddress.uppercased()) {
            unblock(client)
        } else {
            // Destructive-ish: confirm before cutting the device off.
            blockCandidate = client
            showBlockConfirm = true
        }
    }

    private func block(_ client: Client) {
        guard let service = appState.service else { return }
        Task {
            do {
                try await service.blockClient(mac: client.macAddress)
                controller.markBlocked(mac: client.macAddress, blocked: true)
                Haptics.success()
                appState.showToast("\(client.hostname) blocked")
            } catch {
                Haptics.warning()
                appState.showToast(error.localizedDescription)
            }
        }
    }

    private func unblock(_ client: Client) {
        guard let service = appState.service else { return }
        Task {
            do {
                try await service.unblockClient(mac: client.macAddress)
                controller.markBlocked(mac: client.macAddress, blocked: false)
                Haptics.success()
                appState.showToast("\(client.hostname) unblocked")
            } catch {
                Haptics.warning()
                appState.showToast(error.localizedDescription)
            }
        }
    }

    // MARK: - Header (count + scope switch)

    private func headerRow(count: Int) -> some View {
        HStack {
            Text("\(count) client\(count == 1 ? "" : "s")")
                .font(.statLabel)
                .foregroundStyle(theme.textSecondary)
            Spacer()
            Menu {
                Picker("Scope", selection: scopeBinding) {
                    Label("All Routers", systemImage: "building.2").tag(true)
                    Label("This Router", systemImage: "wifi.router").tag(false)
                }
            } label: {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: controller.aggregateAll ? "building.2" : "wifi.router")
                        .font(.caption)
                    Text(controller.aggregateAll ? "All Routers" : "This Router")
                        .font(.caption.weight(.medium))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                }
                .foregroundStyle(theme.accent)
                .padding(.vertical, Spacing.xs)
                .padding(.horizontal, Spacing.sm)
                .background(theme.accent.opacity(0.15), in: .capsule)
            }
        }
        .padding(.horizontal, Spacing.xs)
    }

    private var scopeBinding: Binding<Bool> {
        Binding(
            get: { controller.aggregateAll },
            set: { newValue in
                guard newValue != controller.aggregateAll else { return }
                Haptics.selection()
                controller.setAggregateAll(newValue)
                Task { await reload() }
            }
        )
    }

    // MARK: - Skeletons

    private var skeletonRows: some View {
        ForEach(0..<6, id: \.self) { _ in
            SkeletonBlock(height: 76, cornerRadius: CornerRadius.card)
        }
    }
}

// MARK: - Client card

private struct ClientCard: View {
    @Environment(\.theme) private var theme

    let client: Client
    /// Held only to hand to ClientSpeedBadge — this view's body never reads
    /// `speeds.rates`, so the 3s tick re-renders badges alone, not rows.
    let speeds: ClientSpeedsController
    let isExpanded: Bool
    let isBlocked: Bool
    /// False in aggregate (All Routers) mode — quick actions are hidden there.
    let canAct: Bool
    let wolAvailable: Bool
    let onToggle: () -> Void
    let onReserve: () -> Void
    let onWake: () -> Void
    let onBlockToggle: () -> Void

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
            // Stale entries (lingering leases) visually recede but stay
            // listed — an "offline" device may just be asleep.
            .opacity(client.presence == .offline ? 0.55 : 1)
        }
        .contextMenu {
            if canAct {
                Button {
                    onReserve()
                } label: {
                    Label("Reserve IP", systemImage: "pin")
                }
                if wolAvailable {
                    Button {
                        onWake()
                    } label: {
                        Label("Wake on LAN", systemImage: "power")
                    }
                }
                if isBlocked {
                    Button {
                        onBlockToggle()
                    } label: {
                        Label("Unblock Internet", systemImage: "checkmark.circle")
                    }
                } else {
                    Button(role: .destructive) {
                        onBlockToggle()
                    } label: {
                        Label("Block Internet", systemImage: "nosign")
                    }
                }
                Divider()
            }
            Button {
                copy(client.ipAddress)
            } label: {
                Label("Copy IP", systemImage: "doc.on.doc")
            }
            Button {
                copy(client.macAddress)
            } label: {
                Label("Copy MAC", systemImage: "doc.on.doc")
            }
            Button {
                copy(client.hostname)
            } label: {
                Label("Copy Hostname", systemImage: "doc.on.doc")
            }
        }
    }

    private func copy(_ value: String) {
        UIPasteboard.general.string = value
        Haptics.success()
    }

    // MARK: Header row

    private var header: some View {
        HStack(spacing: Spacing.sm) {
            StatusDot(
                color: presenceColor,
                glows: client.presence == .online
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(client.hostname)
                    .font(.cardTitle)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: Spacing.xs) {
                    Text(primaryAddress)
                        .font(.subheadline)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if extraAddressCount > 0 {
                        Text("+\(extraAddressCount)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(theme.textSecondary)
                            .padding(.horizontal, Spacing.xs)
                            .padding(.vertical, 1)
                            .background(theme.separator.opacity(0.5), in: .capsule)
                    }
                }
                if let vendor = client.vendor, !vendor.isEmpty {
                    Text(vendor)
                        .font(.caption)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Spacing.sm)
            if isBlocked {
                blockedChip
            }
            ClientSpeedBadge(mac: client.macAddress, speeds: speeds)
            if client.presence == .offline {
                offlineChip
            }
            connectionChip
            Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.textSecondary)
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
        }
    }

    /// Mirrors _buildMinimalClientSubtitle: prefer IPv4, fall back to IPv6,
    /// and count the leftover addresses as "+N".
    private var primaryAddress: String {
        if client.ipAddress != "N/A" { return client.ipAddress }
        if let firstV6 = client.ipv6Addresses.first { return firstV6 }
        return "N/A"
    }

    private var extraAddressCount: Int {
        if client.ipAddress != "N/A" {
            return client.ipv6Addresses.isEmpty ? 0 : 1
        }
        return 0
    }

    private var connectionChip: some View {
        let label: String
        let foreground: Color
        let background: Color
        switch client.connectionType {
        case .wireless:
            label = "Wi-Fi"
            foreground = theme.accent
            background = theme.accent.opacity(0.15)
        case .wired:
            label = "Wired"
            foreground = theme.accent2
            background = theme.accent2.opacity(0.15)
        case .unknown:
            label = "Unknown"
            foreground = theme.textSecondary
            background = theme.separator.opacity(0.15)
        }
        return Text(label)
            .font(.caption.weight(.medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(background, in: .capsule)
    }

    private var presenceColor: Color {
        switch client.presence {
        case .online: return theme.success
        case .idle: return theme.warning
        case .offline: return theme.separator
        }
    }

    private var presenceLabel: String {
        switch client.presence {
        case .online: return "Online"
        case .idle: return "Idle (sleeping)"
        case .offline: return "Offline"
        }
    }

    /// Detail-row text color: the separator token is too faint for text, so
    /// offline reads as secondary text instead.
    private var presenceStatusColor: Color {
        switch client.presence {
        case .online: return theme.success
        case .idle: return theme.warning
        case .offline: return theme.textSecondary
        }
    }

    private var offlineChip: some View {
        Text("Offline")
            .font(.caption2.weight(.medium))
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(theme.separator.opacity(0.5), in: .capsule)
    }

    private var blockedChip: some View {
        Text("Blocked")
            .font(.caption.weight(.medium))
            .foregroundStyle(theme.error)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(theme.error.opacity(0.15), in: .capsule)
    }

    // MARK: Expanded details

    private var details: some View {
        VStack(spacing: 0) {
            ClientDetailRow(
                label: "IP Address", value: client.ipAddress, copyable: true, monospaced: true)
            ForEach(client.ipv6Addresses, id: \.self) { ipv6 in
                ClientDetailRow(
                    label: "IPv6 Address", value: ipv6, copyable: true, monospaced: true)
            }
            ClientDetailRow(
                label: "MAC Address", value: client.macAddress, copyable: true, monospaced: true)
            if let vendor = client.vendor, !vendor.isEmpty {
                ClientDetailRow(label: "Vendor", value: vendor)
            }
            if let dnsName = client.dnsName, !dnsName.isEmpty {
                ClientDetailRow(label: "DNS Name", value: dnsName)
            }
            Divider()
                .padding(.vertical, Spacing.xs)
            ClientDetailRow(
                label: "Status",
                value: presenceLabel,
                valueColor: presenceStatusColor
            )
            ClientDetailRow(
                label: "Lease Time Remaining",
                value: client.formattedLeaseTime,
                valueColor: client.isLeaseExpired ? theme.error : nil
            )
            if canAct {
                Divider()
                    .padding(.vertical, Spacing.xs)
                actionRow
            }
        }
    }

    // MARK: Quick action row

    private var actionRow: some View {
        HStack(spacing: Spacing.sm) {
            actionChip("Reserve IP", systemImage: "pin", tint: theme.accent, action: onReserve)
            if wolAvailable {
                actionChip("Wake", systemImage: "power", tint: theme.accent2, action: onWake)
            }
            if isBlocked {
                actionChip(
                    "Unblock", systemImage: "checkmark.circle", tint: theme.success,
                    action: onBlockToggle)
            } else {
                actionChip("Block", systemImage: "nosign", tint: theme.error, action: onBlockToggle)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, Spacing.xs)
    }

    private func actionChip(
        _ title: String, systemImage: String, tint: Color, action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptics.impact(.light)
            action()
        } label: {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.medium))
                .foregroundStyle(tint)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xs + 2)
                .background(tint.opacity(0.15), in: .capsule)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Live speed badge

/// The ONLY view that reads `speeds.rates`, so the 3s polling tick
/// re-renders these tiny badges and nothing else. Renders nothing when no
/// rate is known for the MAC (wired clients, other routers, or an iwinfo
/// build without byte counters).
private struct ClientSpeedBadge: View {
    let mac: String
    let speeds: ClientSpeedsController

    @Environment(\.theme) private var theme

    var body: some View {
        if let rate = speeds.rates[mac.uppercased()] {
            Text(
                "↓ \(Self.compact(rate.rxBytesPerSecond)) ↑ \(Self.compact(rate.txBytesPerSecond))"
            )
            .font(.caption2.monospacedDigit())
            .foregroundStyle(theme.textSecondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(theme.separator.opacity(0.4), in: .capsule)
            .contentTransition(.numericText())
        }
    }

    /// Compact bits-per-second: "2.1M" / "340K" / "12" (same bit-based
    /// convention as ThroughputCalculator.formatRate, shortened).
    private static func compact(_ bytesPerSecond: Double) -> String {
        let bits = max(0, bytesPerSecond) * 8
        if bits >= 1_000_000 {
            return String(format: "%.1fM", bits / 1_000_000)
        }
        if bits >= 1_000 {
            return String(format: "%.0fK", bits / 1_000)
        }
        return String(format: "%.0f", bits)
    }
}

// MARK: - Detail row (tap-to-copy)

private struct ClientDetailRow: View {
    @Environment(\.theme) private var theme

    let label: String
    let value: String
    var valueColor: Color? = nil
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
                .foregroundStyle(valueColor ?? theme.textPrimary)
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
