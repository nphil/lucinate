import Foundation
import SwiftUI

// MARK: - Phone Data in words

/// What Phone Data is doing right now, in the words the owner sees. Built from the iPhone's own
/// status narrowed to the selected router, so the card and the screen always agree.
enum PhoneDataPresentation: Equatable {
    /// This router has no saved link to this iPhone.
    case notSetUp
    /// Set up, but Personal Hotspot is off, so there is no link yet. `setUp` is how this router
    /// was set up to reach the iPhone (USB, Wi-Fi or both), which decides what to ask for.
    case waitingForPhone(setUp: Set<PhoneDataLink>)
    /// The iPhone is ready and listening; this router hasn't connected yet.
    case waitingForRouter
    /// This router is using the iPhone's data, over these links.
    case sharing(links: Set<PhoneDataLink>)
    /// The phone side failed; the string is its plain-language reason.
    case problem(String)

    /// A problem on the iPhone's side (its keys can't be read, the engine won't start) is why
    /// nothing works, so it wins whichever router is selected. Otherwise a router with no saved
    /// link to this iPhone is "not set up" even when another router is, and "sharing" only
    /// counts when it is this router that is connected.
    @MainActor
    static func current(phone: PhoneDataController, routerID: String?) -> PhoneDataPresentation {
        if case .problem(let reason) = phone.status { return .problem(reason) }
        guard let routerID, phone.hasPeer(for: routerID) else { return .notSetUp }
        switch phone.status {
        case .notSetUp:
            return .notSetUp
        case .waitingForHotspot:
            let setUp = Set(PhoneDataLink.allCases.filter { phone.hasPeer(for: routerID, link: $0) })
            return .waitingForPhone(setUp: setUp)
        case .waitingForRouter:
            return .waitingForRouter
        case .sharing:
            guard phone.isRouterConnected(routerID) else { return .waitingForRouter }
            return .sharing(links: phone.connectedLinks(for: routerID))
        case .problem(let reason):
            return .problem(reason)
        }
    }

    var isSharing: Bool {
        if case .sharing = self { return true }
        return false
    }

    /// Status dot / accent colour for this state.
    func color(in theme: Theme) -> Color {
        switch self {
        case .notSetUp, .waitingForPhone: theme.textSecondary
        case .waitingForRouter: theme.accent
        case .sharing: theme.success
        case .problem: theme.error
        }
    }

    /// The one line shown on the card (the sharing line adds live speeds on top of "Sharing").
    var summaryLine: String {
        switch self {
        case .notSetUp: "Use this iPhone's data for the router, over USB or Wi-Fi."
        case .waitingForPhone(let setUp):
            setUp.contains(.wifi)
                ? "Turn on Personal Hotspot"
                : "Plug in your iPhone and turn on Personal Hotspot"
        case .waitingForRouter: "Waiting for the router…"
        case .sharing: "Sharing"
        case .problem(let reason): reason
        }
    }

    /// Big title of the status hero. A router that is sharing says how: over the cable, over
    /// Wi-Fi, or both when both links are up at once.
    var title: String {
        switch self {
        case .notSetUp: "Not set up yet"
        case .waitingForPhone: "Waiting for your iPhone"
        case .waitingForRouter: "Waiting for the router"
        case .sharing(let links): Self.sharingTitle(links: links)
        case .problem: "Can't share iPhone data"
        }
    }

    /// An empty set (the router counts as connected but no link says so) gets no link named,
    /// rather than a wrong one.
    static func sharingTitle(links: Set<PhoneDataLink>) -> String {
        switch (links.contains(.usb), links.contains(.wifi)) {
        case (true, true): "Sharing over USB and Wi-Fi"
        case (true, false): "Sharing over USB"
        case (false, true): "Sharing over Wi-Fi"
        case (false, false): "Sharing iPhone data"
        }
    }

    /// One sentence under the hero title. `routerSeesPhone` is true when the router already
    /// detects the iPhone on its USB port, which narrows down what is still missing.
    func detail(routerSeesPhone: Bool) -> String {
        switch self {
        case .notSetUp:
            "Use this iPhone's data for the router, over USB or Wi-Fi."
        case .waitingForPhone(let setUp):
            Self.waitingDetail(setUp: setUp, routerSeesPhone: routerSeesPhone)
        case .waitingForRouter:
            "Your iPhone is ready. The router will connect in a moment."
        case .sharing:
            "The router is using this iPhone's data."
        case .problem(let reason):
            reason
        }
    }

    /// What is still missing before the router can reach the iPhone: Personal Hotspot always,
    /// and the cable only when USB is the way this router was set up.
    private static func waitingDetail(setUp: Set<PhoneDataLink>, routerSeesPhone: Bool) -> String {
        if routerSeesPhone {
            return "The router can see your iPhone. Turn on Personal Hotspot, and tap Trust if it asks."
        }
        guard setUp.contains(.wifi) else {
            return "Plug it into the router's USB port and turn on Personal Hotspot."
        }
        return setUp.contains(.usb)
            ? "Turn on Personal Hotspot. The router uses the cable if it's plugged in, "
                + "or joins over Wi-Fi."
            : "Turn on Personal Hotspot. The router will join it over Wi-Fi."
    }
}

// MARK: - Formatting

enum PhoneDataFormat {
    /// "1.2 Mbps" from a live bits-per-second reading, in the app's usual rate wording.
    static func rate(bitsPerSecond: Double) -> String {
        ThroughputCalculator.formatRate(bytesPerSecond: max(0, bitsPerSecond) / 8)
    }

    /// The same reading spelled out for VoiceOver ("1.2 megabits per second").
    static func spokenRate(bitsPerSecond: Double) -> String {
        rate(bitsPerSecond: bitsPerSecond)
            .replacingOccurrences(of: "Mbps", with: "megabits per second")
            .replacingOccurrences(of: "Kbps", with: "kilobits per second")
            .replacingOccurrences(of: "bps", with: "bits per second")
    }
}

// MARK: - Shared building blocks

/// Tinted round icon that leads a Phone Data row (same treatment as the Broadcast Wi-Fi rows).
struct PhoneDataIconBadge: View {
    let systemImage: String

    @Environment(\.theme) private var theme
    @ScaledMetric(relativeTo: .headline) private var size: CGFloat = 36

    var body: some View {
        Image(systemName: systemImage)
            .foregroundStyle(theme.accent)
            .frame(width: size, height: size)
            .background(theme.accent.opacity(0.15), in: .circle)
            .accessibilityHidden(true)
    }
}

/// Number circle of a step list: a check when done, accented when current, quiet when upcoming.
struct PhoneDataStepMarker: View {
    enum Mark: Equatable {
        case upcoming
        case current
        case done

        /// What VoiceOver says after the step's name.
        var spokenValue: String {
            switch self {
            case .upcoming: "Not started"
            case .current: "Current step"
            case .done: "Done"
            }
        }
    }

    let number: Int
    let mark: Mark
    /// Pass a `@ScaledMetric` value so the circle grows with Dynamic Type.
    let size: CGFloat

    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            switch mark {
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(theme.success)
            case .current:
                Circle().fill(theme.accent.opacity(0.15))
                Text("\(number)")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(theme.accent)
            case .upcoming:
                Circle().fill(theme.separator.opacity(0.5))
                Text("\(number)")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// One numbered instruction of a how-to list. The text is markdown, so the names of things to
/// tap can be bold; VoiceOver gets it without the asterisks.
struct PhoneDataInstructionRow: View {
    let number: Int
    let text: String

    @Environment(\.theme) private var theme
    @ScaledMetric(relativeTo: .subheadline) private var markerSize: CGFloat = 26

    private var spokenText: String {
        text.replacingOccurrences(of: "**", with: "")
    }

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            PhoneDataStepMarker(number: number, mark: .current, size: markerSize)
            Text(LocalizedStringKey(text))
                .font(.subheadline)
                .foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: markerSize, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(number). \(spokenText)")
    }
}

/// Something went wrong: the reason, in plain words, on a red tint.
struct PhoneDataErrorBanner: View {
    let message: String

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(theme.error)
                .accessibilityHidden(true)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Spacing.md)
        .background(
            theme.error.opacity(0.15),
            in: .rect(cornerRadius: CornerRadius.card, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Card

/// Compact entry to Phone Data at the top of the TravelMate tab: one status line, and a tap
/// anywhere on the card opens the full screen. It only reads the iPhone's own state, so it
/// costs the router nothing and also works when TravelMate isn't installed.
struct PhoneDataCard: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    var body: some View {
        let phone = PhoneDataController.shared
        let presentation = PhoneDataPresentation.current(
            phone: phone, routerID: appState.phoneDataRouterID)
        NavigationLink {
            PhoneDataView()
        } label: {
            Card {
                HStack(spacing: Spacing.sm + 2) {
                    PhoneDataIconBadge(systemImage: "iphone.radiowaves.left.and.right")
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: Spacing.sm) {
                            Text("Phone Data")
                                .font(.cardTitle)
                                .foregroundStyle(theme.textPrimary)
                            Spacer(minLength: Spacing.sm)
                            trailing(for: presentation)
                        }
                        statusLine(for: presentation, phone: phone)
                    }
                }
                .contentShape(.rect)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Phone Data")
        .accessibilityValue(spokenStatus(for: presentation, phone: phone))
        .accessibilityHint(presentation == .notSetUp ? "Opens setup" : "Opens status and setup")
    }

    // MARK: Pieces

    /// "Set Up" while there is nothing to show yet, a chevron once there is a status.
    @ViewBuilder
    private func trailing(for presentation: PhoneDataPresentation) -> some View {
        if presentation == .notSetUp {
            Text("Set Up")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.accent)
                .padding(.horizontal, Spacing.sm + 4)
                .padding(.vertical, Spacing.xs)
                .background(theme.accent.opacity(0.15), in: .capsule)
        } else {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.textSecondary)
        }
    }

    @ViewBuilder
    private func statusLine(for presentation: PhoneDataPresentation, phone: PhoneDataController)
        -> some View
    {
        if presentation == .notSetUp {
            Text(presentation.summaryLine)
                .font(.subheadline)
                .foregroundStyle(theme.textSecondary)
                .lineLimit(2)
        } else {
            // First-text-baseline alignment sits the dot on the line's baseline, which centres
            // it on the lowercase letters.
            HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                StatusDot(
                    color: presentation.color(in: theme), size: 8, glows: presentation.isSharing)
                statusText(for: presentation, phone: phone)
                    .font(.subheadline)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(2)
            }
        }
    }

    private func statusText(for presentation: PhoneDataPresentation, phone: PhoneDataController)
        -> Text
    {
        guard presentation.isSharing else { return Text(presentation.summaryLine) }
        let down = PhoneDataFormat.rate(bitsPerSecond: phone.downBitsPerSecond)
        let up = PhoneDataFormat.rate(bitsPerSecond: phone.upBitsPerSecond)
        return Text(
            "Sharing · \(Image(systemName: "arrow.down")) \(down)  \(Image(systemName: "arrow.up")) \(up)"
        )
    }

    private func spokenStatus(
        for presentation: PhoneDataPresentation, phone: PhoneDataController
    ) -> String {
        switch presentation {
        case .sharing:
            let down = PhoneDataFormat.spokenRate(bitsPerSecond: phone.downBitsPerSecond)
            let up = PhoneDataFormat.spokenRate(bitsPerSecond: phone.upBitsPerSecond)
            return "\(presentation.title). Download \(down). Upload \(up)."
        case .notSetUp:
            return "Not set up. \(presentation.summaryLine)"
        case .waitingForPhone, .waitingForRouter, .problem:
            return presentation.summaryLine
        }
    }
}
