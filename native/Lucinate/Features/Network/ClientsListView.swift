import SwiftUI
import UIKit

/// Clients segment of the Network hub: expandable client cards with an
/// All Routers / This Router scope switch (parity with clients_screen.dart).
struct ClientsListView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    var controller: ClientsController
    var searchText: String

    @State private var expandedIDs: Set<String> = []

    var body: some View {
        let filtered = controller.filtered(query: searchText)
        ScrollView {
            LazyVStack(spacing: Spacing.sm) {
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
                                isExpanded: expandedIDs.contains(client.id),
                                onToggle: { toggle(client.id) }
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.top, Spacing.sm)
            .padding(.bottom, Spacing.xxl)
        }
        .background(theme.background)
        .refreshable {
            Haptics.impact(.medium)
            await reload()
        }
        .task(id: appState.selectedRouterID) {
            await reload()
        }
    }

    private func reload() async {
        await controller.load(service: appState.service, routers: appState.routers)
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
        .contextMenu {
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
                color: client.connectionType == .unknown ? theme.warning : theme.success,
                glows: true
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
                label: "Lease Time Remaining",
                value: client.formattedLeaseTime,
                valueColor: client.isLeaseExpired ? theme.error : nil
            )
        }
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
