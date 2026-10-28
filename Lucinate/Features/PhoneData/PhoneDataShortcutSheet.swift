import AppIntents
import Foundation
import SwiftUI

/// How to make a one-tap "Phone Data" shortcut: four short steps in the Shortcuts app, then a
/// button that opens it on a blank shortcut. iOS has no automation for "Personal Hotspot turned
/// on", so one shortcut that turns it on and starts Phone Data is the way to do both at once.
struct PhoneDataShortcutSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @ScaledMetric(relativeTo: .subheadline) private var markerSize: CGFloat = 26

    /// Opens the Shortcuts app on a new, empty shortcut.
    private static let newShortcutURL = URL(string: "shortcuts://create-shortcut")

    private struct Step: Identifiable {
        let id: Int
        /// Markdown: the names of things to tap are bold.
        let text: String

        /// The same sentence without the markdown, for VoiceOver.
        var spokenText: String {
            text.replacingOccurrences(of: "**", with: "")
        }
    }

    private let steps = [
        Step(id: 1, text: "Open the Shortcuts app and tap **+** to make a new shortcut."),
        Step(id: 2, text: "Add **Set Personal Hotspot** and set it to **On**."),
        Step(id: 3, text: "Add Lucinate's **Use Phone Data**."),
        Step(
            id: 4,
            text: "Name it **Phone Data**, then add it to your Action button or Home Screen, "
                + "or just ask Siri."),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    Text(
                        "One shortcut turns on Personal Hotspot and starts Phone Data, "
                            + "so you never have to dig through Settings."
                    )
                    .font(.subheadline)
                    .foregroundStyle(theme.textSecondary)

                    stepsCard
                    openShortcutsButton
                    shortcutsLinkRow
                }
                .padding(Spacing.md)
            }
            .background(theme.background)
            .navigationTitle("Make it one tap")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(theme.accent)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Pieces

    private var stepsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.md) {
                ForEach(steps) { step in
                    stepRow(step)
                }
            }
        }
    }

    private func stepRow(_ step: Step) -> some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            PhoneDataStepMarker(number: step.id, mark: .current, size: markerSize)
            Text(LocalizedStringKey(step.text))
                .font(.subheadline)
                .foregroundStyle(theme.textPrimary)
                .frame(maxWidth: .infinity, minHeight: markerSize, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step.id). \(step.spokenText)")
    }

    private var openShortcutsButton: some View {
        Button {
            Haptics.impact(.light)
            if let url = Self.newShortcutURL {
                openURL(url)
            }
        } label: {
            Text("Open Shortcuts")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.xs)
        }
        .buttonStyle(.glassProminent)
        .tint(theme.accent)
    }

    /// The system's own link to the app's shortcuts, for anyone who would rather start from
    /// the ready-made actions than from a blank shortcut.
    private var shortcutsLinkRow: some View {
        HStack(spacing: Spacing.md) {
            Text("Lucinate's actions are also listed in the Shortcuts app.")
                .font(.footnote)
                .foregroundStyle(theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            ShortcutsLink()
        }
    }
}
