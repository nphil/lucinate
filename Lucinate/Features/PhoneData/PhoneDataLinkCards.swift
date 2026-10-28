import SwiftUI

// MARK: - Shared pieces

/// Icon, name and (when there is one) a state at the end: the top of a link card.
struct PhoneDataLinkHeader<Trailing: View>: View {
    let systemImage: String
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: Spacing.sm + 2) {
            PhoneDataIconBadge(systemImage: systemImage)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.cardTitle)
                    .foregroundStyle(theme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
    }
}

/// A short state word on a tinted capsule ("In use", "Ready"), in the style of the tags on the
/// TravelMate saved networks.
struct PhoneDataStatePill: View {
    enum Tone: Equatable {
        case success
        case warning
        case neutral
    }

    let text: String
    let tone: Tone

    @Environment(\.theme) private var theme

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(labelColor)
            .fixedSize()
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, 3)
            .background(fillColor, in: .capsule)
    }

    private var labelColor: Color {
        switch tone {
        case .success: theme.success
        case .warning: theme.warning
        case .neutral: theme.textSecondary
        }
    }

    private var fillColor: Color {
        switch tone {
        case .success: theme.success.opacity(0.15)
        case .warning: theme.warning.opacity(0.15)
        case .neutral: theme.separator.opacity(0.5)
        }
    }
}

/// The quiet "Remove" at the foot of a link card: a separator, then a red text button, or the
/// progress of the removal while it runs.
struct PhoneDataRemoveRow: View {
    let title: String
    /// Non-nil while this link is being removed: what the router is doing.
    let workingText: String?
    /// Something else is running, so nothing new can start.
    let isDisabled: Bool
    let action: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().overlay(theme.separator)
            if let workingText {
                HStack(spacing: Spacing.sm) {
                    ProgressView()
                        .controlSize(.small)
                    Text(workingText)
                        .font(.subheadline)
                        .foregroundStyle(theme.textSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .accessibilityElement(children: .combine)
            } else {
                Button(role: .destructive) {
                    Haptics.warning()
                    action()
                } label: {
                    Label(title, systemImage: "trash")
                        .font(.subheadline)
                        .foregroundStyle(isDisabled ? theme.textSecondary : theme.error)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
            }
        }
    }
}

// MARK: - USB

/// USB once it is set up: one compact card with its state, instead of the three-step checklist.
/// Reads which links the iPhone sees as connected itself, so only this card follows that.
struct PhoneDataUSBCard: View {
    let routerID: String?
    /// The router's last answer; says whether the iPhone is plugged into the router right now.
    let routerState: PhoneDataRouterState?
    /// The router's link belongs to another iPhone (or this one lost its half); the banner above
    /// the card has the Fix.
    let needsRepair: Bool
    /// Something is running, so nothing new can start.
    let isBusy: Bool
    /// Non-nil while this link is being removed: what the router is doing.
    let removalMessage: String?
    let onRemove: () -> Void

    @Environment(\.theme) private var theme

    private struct Look {
        let state: String
        let tone: PhoneDataStatePill.Tone
        let message: String
    }

    var body: some View {
        let look = currentLook()
        Card {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    PhoneDataLinkHeader(systemImage: "cable.connector", title: "USB cable") {
                        PhoneDataStatePill(text: look.state, tone: look.tone)
                    }
                    Text(look.message)
                        .font(.subheadline)
                        .foregroundStyle(theme.textSecondary)
                }
                .accessibilityElement(children: .combine)
                PhoneDataRemoveRow(
                    title: "Remove USB Setup", workingText: removalMessage, isDisabled: isBusy,
                    action: onRemove)
            }
        }
    }

    /// "In use" is the iPhone's own word that the router is connected over the cable. Until then
    /// the router's view says how far along plugging in is.
    private func currentLook() -> Look {
        if needsRepair {
            return Look(
                state: "Needs repair", tone: .warning,
                message: "Tap Fix above to link the router and this iPhone again.")
        }
        let inUse =
            routerID.map { PhoneDataController.shared.connectedLinks(for: $0).contains(.usb) }
            ?? false
        if inUse {
            return Look(
                state: "In use", tone: .success,
                message: "Your iPhone is sharing its data over the cable.")
        }
        guard routerState?.usbDevice != nil else {
            return Look(
                state: "Ready", tone: .neutral,
                message: "Plug in your iPhone and turn on Personal Hotspot.")
        }
        let linkUp = routerState?.usbLinkUp == true
        return Look(
            state: "Plugged in", tone: .neutral,
            message: linkUp
                ? "Connecting to your iPhone…" : "Turn on Personal Hotspot to start sharing.")
    }
}

// MARK: - Wi-Fi

/// Wi-Fi sharing as one card: an invitation to set it up, or, once it is, the hotspot the router
/// joins, its state, the one thing worth knowing, and Remove.
struct PhoneDataWifiCard: View {
    let routerState: PhoneDataRouterState
    /// The router's link no longer matches this iPhone.
    let needsRepair: Bool
    /// There is something to remove: the router has the setup, or this iPhone remembers it.
    let canRemove: Bool
    /// Something is running, so nothing new can start.
    let isBusy: Bool
    /// Non-nil while this link is being removed: what the router is doing.
    let removalMessage: String?
    let onSetUp: () -> Void
    let onFix: () -> Void
    let onRemove: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Card {
            if routerState.wifiConfigured {
                setUp
            } else {
                invitation
            }
        }
    }

    private var removeRow: some View {
        PhoneDataRemoveRow(
            title: "Remove Wi-Fi Setup", workingText: removalMessage, isDisabled: isBusy,
            action: onRemove)
    }

    // MARK: Not set up

    /// Without TravelMate there is nothing to join the hotspot with, so the card says so rather
    /// than offering a setup that can't work.
    private var invitation: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            PhoneDataLinkHeader(systemImage: "wifi", title: "Wi-Fi") {
                if routerState.travelmateInstalled {
                    setUpButton
                }
            }
            Text(
                routerState.travelmateInstalled
                    ? "Share without a cable: the router joins your iPhone's hotspot."
                    : "Wi-Fi sharing needs TravelMate on the router. "
                        + "Install the travelmate package, then pull down to refresh."
            )
            .font(.subheadline)
            .foregroundStyle(theme.textSecondary)
            if canRemove {
                removeRow
            }
        }
    }

    /// Same look as the "Set Up" tag on the Phone Data card, with a 44 pt target around it.
    private var setUpButton: some View {
        Button {
            Haptics.impact(.light)
            onSetUp()
        } label: {
            Text("Set Up")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.accent)
                .padding(.horizontal, Spacing.sm + 4)
                .padding(.vertical, Spacing.xs)
                .background(theme.accent.opacity(0.15), in: .capsule)
                .frame(minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .accessibilityLabel("Set up Wi-Fi sharing")
    }

    // MARK: Set up

    /// The router is on the iPhone's hotspot and its tunnel is up.
    private var inUse: Bool {
        routerState.wifiUplinkActive && routerState.wifiTunnelUp
    }

    private var setUp: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                PhoneDataLinkHeader(
                    systemImage: "wifi", title: "Wi-Fi",
                    subtitle: routerState.wifiSSID.map { "Hotspot: \($0)" }
                ) {
                    PhoneDataStatePill(
                        text: needsRepair ? "Needs repair" : (inUse ? "In use" : "Ready"),
                        tone: needsRepair ? .warning : (inUse ? .success : .neutral))
                }
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(theme.textSecondary)
                if !needsRepair {
                    settingsNote
                }
            }
            .accessibilityElement(children: .combine)
            if needsRepair {
                fixButton
            }
            removeRow
        }
    }

    private var message: String {
        if needsRepair {
            return "The router was set up with a different iPhone, or the link was lost."
        }
        if inUse {
            return "The router is using this iPhone's data over Wi-Fi."
        }
        if routerState.wifiUplinkActive {
            return "The router has joined your hotspot. Connecting…"
        }
        if case .waitingForHotspot = PhoneDataController.shared.status {
            return "Turn on Personal Hotspot and the router will join it."
        }
        return "The router will join your hotspot in a moment."
    }

    /// While the router uses the hotspot this iPhone isn't on the router's Wi-Fi, so the app can't
    /// reach the router. That is expected, and says nothing about sharing.
    private var settingsNote: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: "info.circle")
                .font(.footnote)
                .foregroundStyle(theme.info)
                .accessibilityHidden(true)
            Text(
                "While the router uses your hotspot, this iPhone can't open the router's "
                    + "settings, because it isn't on the router's Wi-Fi. Phone Data keeps working."
            )
            .font(.footnote)
            .foregroundStyle(theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var fixButton: some View {
        Button {
            Haptics.impact(.light)
            onFix()
        } label: {
            Label("Fix", systemImage: "arrow.triangle.2.circlepath")
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .tint(theme.warning)
        .disabled(isBusy)
        .accessibilityLabel("Fix the Wi-Fi link")
    }
}
