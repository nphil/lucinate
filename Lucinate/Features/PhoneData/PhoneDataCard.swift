import Foundation
import SwiftUI

// MARK: - Phone Data in words

/// What Phone Data is doing right now, in the words the owner sees. Built from the iPhone's own
/// status narrowed to the selected router, so the card and the screen always agree.
enum PhoneDataPresentation: Equatable {
    /// This router has no saved link to this iPhone.
    case notSetUp
    /// Set up, but there is no hotspot link yet: iPhone unplugged or Personal Hotspot off.
    case waitingForPhone
    /// The iPhone is ready and listening; this router hasn't connected yet.
    case waitingForRouter
    /// This router is using the iPhone's data.
    case sharing
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
            return .waitingForPhone
        case .waitingForRouter:
            return .waitingForRouter
        case .sharing:
            return phone.isRouterConnected(routerID) ? .sharing : .waitingForRouter
        case .problem(let reason):
            return .problem(reason)
        }
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
        case .notSetUp: "Use this iPhone's data for the router, over USB."
        case .waitingForPhone: "Plug in your iPhone and turn on Personal Hotspot"
        case .waitingForRouter: "Waiting for the router…"
        case .sharing: "Sharing"
        case .problem(let reason): reason
        }
    }

    /// Big title of the status hero.
    var title: String {
        switch self {
        case .notSetUp: "Not set up yet"
        case .waitingForPhone: "Waiting for your iPhone"
        case .waitingForRouter: "Waiting for the router"
        case .sharing: "Sharing iPhone data"
        case .problem: "Can't share iPhone data"
        }
    }

    /// One sentence under the hero title. `routerSeesPhone` is true when the router already
    /// detects the iPhone on its USB port, which narrows down what is still missing.
    func detail(routerSeesPhone: Bool) -> String {
        switch self {
        case .notSetUp:
            "Use this iPhone's data for the router, over USB."
        case .waitingForPhone:
            routerSeesPhone
                ? "The router can see your iPhone. Turn on Personal Hotspot, and tap Trust if it asks."
                : "Plug it into the router's USB port and turn on Personal Hotspot."
        case .waitingForRouter:
            "Your iPhone is ready. The router will connect in a moment."
        case .sharing:
            "The router is using this iPhone's data."
        case .problem(let reason):
            reason
        }
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
                    color: presentation.color(in: theme), size: 8, glows: presentation == .sharing)
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
        guard presentation == .sharing else { return Text(presentation.summaryLine) }
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
            return "Sharing. Download \(down). Upload \(up)."
        case .notSetUp:
            return "Not set up. \(presentation.summaryLine)"
        case .waitingForPhone, .waitingForRouter, .problem:
            return presentation.summaryLine
        }
    }
}
