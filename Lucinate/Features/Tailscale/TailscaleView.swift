import SwiftUI
import UIKit

/// Tailscale management: connection status, exit-node routing, DNS/security
/// flags, and the peer list. Mirrors `lib/screens/tailscale_screen.dart`.
struct TailscaleView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    @State private var controller = TailscaleController()
    @State private var lastRouterID: String?
    @State private var showMagicDnsConfirm = false
    @State private var showShieldsUpConfirm = false

    var body: some View {
        ScrollView {
            if controller.notInstalled {
                EmptyStateView(
                    systemImage: "lock.shield",
                    title: "Tailscale Not Available",
                    message:
                        "Install the Tailscale package and LuCI app on the router to manage it here."
                )
                .containerRelativeFrame(.vertical)
            } else if !controller.loaded, let error = controller.error {
                ErrorStateView(message: error) {
                    Task { await reload() }
                }
                .containerRelativeFrame(.vertical)
            } else if !controller.loaded {
                loadingSkeleton
            } else {
                content
            }
        }
        .background(theme.background)
        .navigationTitle("Tailscale")
        .refreshable {
            Haptics.impact(.medium)
            await reload()
        }
        .task(id: appState.selectedRouterID) {
            if lastRouterID != appState.selectedRouterID {
                lastRouterID = appState.selectedRouterID
                controller.reset()
            }
            await reload()
        }
        .alert("Enable MagicDNS?", isPresented: $showMagicDnsConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Enable anyway", role: .destructive) {
                setFlag("disable_magic_dns", false)
            }
        } message: {
            Text(
                "Enabling Accept DNS points this router's DNS at Tailscale "
                    + "(100.100.100.100). On this router there is no route to it, so "
                    + "package updates (apk / LuCI) will fail with \"Operation not "
                    + "permitted\".\n\nOnly enable if you know what you're doing."
            )
        }
        .alert("Enable Shields Up?", isPresented: $showShieldsUpConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Enable anyway", role: .destructive) {
                setFlag("shields_up", true)
            }
        } message: {
            Text(
                "Shields Up blocks ALL inbound tailnet connections to this router "
                    + "— including SSH and this app over Tailscale. If you're connected "
                    + "via Tailscale right now, you may lose access until you re-enable "
                    + "it from the router's own Wi-Fi (192.168.10.1)."
            )
        }
    }

    // MARK: - Actions

    private func reload() async {
        guard let service = appState.service else { return }
        await controller.load(service: service)
    }

    private func setFlag(_ key: String, _ value: Bool) {
        guard let service = appState.service else { return }
        Task {
            let ok = await controller.setFlag(key, value: value, service: service)
            if !ok {
                Haptics.error()
                appState.showToast(controller.error ?? "Action failed")
            }
        }
    }

    private func selectExitNode(_ ip: String?) {
        guard let service = appState.service else { return }
        Haptics.selection()
        Task {
            let ok = await controller.setExitNode(ip: ip, service: service)
            if !ok {
                Haptics.error()
                appState.showToast(controller.error ?? "Action failed")
            }
        }
    }

    // MARK: - Content

    private var content: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            statusCard
            sectionHeader("Routing")
            routingCard
            sectionHeader("DNS & Security")
            dnsSecurityCard
            if !controller.status.peers.isEmpty {
                sectionHeader("Peers")
                peersCard
            }
        }
        .padding(Spacing.md)
    }

    private var loadingSkeleton: some View {
        VStack(spacing: Spacing.md) {
            SkeletonBlock(height: 170, cornerRadius: CornerRadius.card)
            SkeletonBlock(height: 190, cornerRadius: CornerRadius.card)
            SkeletonBlock(height: 130, cornerRadius: CornerRadius.card)
            SkeletonBlock(height: 150, cornerRadius: CornerRadius.card)
        }
        .padding(Spacing.md)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(theme.textSecondary)
            .padding(.top, Spacing.sm)
            .padding(.leading, Spacing.xs)
    }

    // MARK: Status card

    private var statusCard: some View {
        let s = controller.status
        let label: String
        let color: Color
        if s.isRunning {
            label = "Connected"
            color = theme.success
        } else if s.needsLogin {
            label = "Needs Login"
            color = theme.warning
        } else {
            label = "Disconnected"
            color = theme.error
        }
        return ElevatedCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack(spacing: Spacing.sm) {
                    StatusDot(color: color, size: 12, glows: s.isRunning)
                    Text(label)
                        .font(.cardTitle)
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                    if controller.isBusy {
                        ProgressView()
                            .controlSize(.small)
                            .tint(theme.textSecondary)
                    }
                }
                VStack(spacing: Spacing.sm) {
                    tailnetIPRow
                    if let name = s.tailnetName {
                        infoRow("Tailnet", name)
                    }
                    infoRow("Peers online", "\(s.peersOnline) of \(s.peers.count)")
                    infoRow("Exit node", s.exitNodeName ?? "None")
                }
            }
        }
    }

    private var tailnetIPRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Tailnet IP")
                .font(.subheadline)
                .foregroundStyle(theme.textSecondary)
            Spacer()
            if let ip = controller.status.tailnetIP {
                Button {
                    UIPasteboard.general.string = ip
                    Haptics.success()
                    appState.showToast("Tailnet IP copied")
                } label: {
                    HStack(spacing: Spacing.xs) {
                        Text(ip)
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundStyle(theme.textPrimary)
                        Image(systemName: "doc.on.doc")
                            .font(.caption2)
                            .foregroundStyle(theme.textSecondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Tailnet IP \(ip). Double tap to copy.")
            } else {
                Text("—")
                    .font(.subheadline)
                    .foregroundStyle(theme.textPrimary)
            }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(theme.textSecondary)
            Spacer()
            Text(value)
                .font(.subheadline)
                .foregroundStyle(theme.textPrimary)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: Routing card

    private var routingCard: some View {
        Card {
            VStack(spacing: Spacing.md) {
                exitNodeRow
                Divider().overlay(theme.separator)
                toggleRow(
                    title: "Accept Routes",
                    subtitle: "Reach subnets advertised by other nodes (e.g. home LAN)",
                    isOn: acceptRoutesBinding
                )
                Divider().overlay(theme.separator)
                toggleRow(
                    title: "Advertise Exit Node",
                    subtitle: "Offer this router as an exit node to your tailnet",
                    isOn: advertiseExitNodeBinding,
                    disabled: controller.status.currentExitNode != nil
                )
            }
        }
    }

    private var exitNodeRow: some View {
        let current = controller.status.currentExitNode
        let candidates = controller.status.exitNodeCandidates
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Exit Node")
                    .font(.body)
                    .foregroundStyle(theme.textPrimary)
                Text("Route all traffic through a peer")
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
            }
            Spacer()
            Menu {
                Button {
                    selectExitNode(nil)
                } label: {
                    if current == nil {
                        Label("None", systemImage: "checkmark")
                    } else {
                        Text("None")
                    }
                }
                if candidates.isEmpty {
                    Text("No peers are offering an exit node.")
                }
                ForEach(candidates) { peer in
                    Button {
                        selectExitNode(peer.ip)
                    } label: {
                        if current?.id == peer.id {
                            Label {
                                Text(peer.hostname)
                                Text(peer.ip)
                            } icon: {
                                Image(systemName: "checkmark")
                            }
                        } else {
                            Text(peer.hostname)
                            Text(peer.ip)
                        }
                    }
                    .disabled(!peer.online)
                }
            } label: {
                HStack(spacing: Spacing.xs) {
                    Text(current?.hostname ?? "None")
                        .font(.subheadline)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                }
                .foregroundStyle(theme.accent)
            }
            .disabled(controller.isBusy)
        }
    }

    // MARK: DNS & Security card

    private var dnsSecurityCard: some View {
        Card {
            VStack(spacing: Spacing.md) {
                toggleRow(
                    title: "MagicDNS (Accept DNS)",
                    subtitle: "Use Tailscale DNS. Warning: breaks package updates on this router",
                    isOn: magicDnsBinding
                )
                Divider().overlay(theme.separator)
                toggleRow(
                    title: "Shields Up",
                    subtitle: "Block all inbound tailnet connections to this router",
                    isOn: shieldsUpBinding
                )
            }
        }
    }

    // MARK: Peers card

    private var peersCard: some View {
        let peers = controller.status.peers
        return Card(padding: 0) {
            VStack(spacing: 0) {
                ForEach(Array(peers.enumerated()), id: \.element.id) { index, peer in
                    peerRow(peer)
                    if index < peers.count - 1 {
                        Divider()
                            .overlay(theme.separator)
                            .padding(.leading, Spacing.md)
                    }
                }
            }
        }
    }

    private func peerRow(_ peer: TailscalePeer) -> some View {
        HStack(spacing: Spacing.sm) {
            StatusDot(color: peer.online ? theme.success : theme.separator)
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.hostname.isEmpty ? peer.id : peer.hostname)
                    .font(.subheadline)
                    .foregroundStyle(theme.textPrimary)
                HStack(spacing: Spacing.xs) {
                    Text(peer.ip)
                        .font(.system(.caption, design: .monospaced))
                    if !peer.os.isEmpty {
                        Text("·")
                            .font(.caption)
                        Text(peer.os)
                            .font(.caption)
                    }
                }
                .foregroundStyle(theme.textSecondary)
            }
            Spacer()
            if peer.isExitNode {
                badge("Exit Node", color: theme.info)
            } else if peer.offersExitNode {
                badge("Offers Exit", color: theme.textSecondary)
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm + 2)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: .capsule)
    }

    // MARK: - Shared rows & bindings

    private func toggleRow(
        title: String,
        subtitle: String,
        isOn: Binding<Bool>,
        disabled: Bool = false
    ) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(theme.textPrimary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .tint(theme.accent)
        .disabled(disabled || controller.isBusy)
    }

    private var acceptRoutesBinding: Binding<Bool> {
        Binding(
            get: { controller.settings.acceptRoutes },
            set: { setFlag("accept_routes", $0) }
        )
    }

    private var advertiseExitNodeBinding: Binding<Bool> {
        Binding(
            get: { controller.settings.advertiseExitNode },
            set: { setFlag("advertise_exit_node", $0) }
        )
    }

    /// User-facing "Accept DNS" is the inverse of `disable_magic_dns`. Only
    /// the ON direction is dangerous (it breaks apk/package updates on this
    /// router), so only enabling asks for confirmation.
    private var magicDnsBinding: Binding<Bool> {
        Binding(
            get: { controller.settings.acceptDns },
            set: { newValue in
                if newValue {
                    showMagicDnsConfirm = true
                } else {
                    setFlag("disable_magic_dns", true)
                }
            }
        )
    }

    /// Enabling Shields Up can lock the user out over Tailscale — confirm
    /// before enabling; disabling is always safe.
    private var shieldsUpBinding: Binding<Bool> {
        Binding(
            get: { controller.settings.shieldsUp },
            set: { newValue in
                if newValue {
                    showShieldsUpConfirm = true
                } else {
                    setFlag("shields_up", false)
                }
            }
        )
    }
}
