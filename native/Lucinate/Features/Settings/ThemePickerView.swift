import SwiftUI

/// Grid of live palette swatches for either the light or dark theme slot.
struct ThemePickerView: View {
    let isDark: Bool

    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.theme) private var theme

    private var themes: [Theme] {
        isDark ? Themes.dark : Themes.light
    }

    private var selectedID: String {
        isDark ? themeManager.darkThemeID : themeManager.lightThemeID
    }

    private let columns = [
        GridItem(.flexible(), spacing: Spacing.md),
        GridItem(.flexible(), spacing: Spacing.md),
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: Spacing.md) {
                ForEach(themes) { candidate in
                    ThemeSwatch(
                        candidate: candidate,
                        isSelected: candidate.id == selectedID,
                        ringColor: theme.accent
                    ) {
                        Haptics.selection()
                        if isDark {
                            themeManager.darkThemeID = candidate.id
                        } else {
                            themeManager.lightThemeID = candidate.id
                        }
                    }
                }
            }
            .padding(Spacing.md)
        }
        .background(theme.background)
        .navigationTitle(isDark ? "Dark Palette" : "Light Palette")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One tappable palette preview card, rendered in the candidate theme's own colors.
private struct ThemeSwatch: View {
    let candidate: Theme
    let isSelected: Bool
    let ringColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                // Mini "card" preview in the candidate's surface color.
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    HStack(spacing: Spacing.sm) {
                        Circle().fill(candidate.accent)
                            .frame(width: 14, height: 14)
                        Circle().fill(candidate.success)
                            .frame(width: 14, height: 14)
                        Circle().fill(candidate.info)
                            .frame(width: 14, height: 14)
                        Spacer()
                    }
                    RoundedRectangle(cornerRadius: 3)
                        .fill(candidate.textSecondary.opacity(0.5))
                        .frame(height: 6)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(candidate.textSecondary.opacity(0.3))
                        .frame(width: 60, height: 6)
                }
                .padding(Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.small)
                        .fill(candidate.surface)
                )

                Text(candidate.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(candidate.textPrimary)
                    .lineLimit(1)
            }
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.card)
                    .fill(candidate.background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.card)
                    .strokeBorder(
                        isSelected ? ringColor : candidate.separator,
                        lineWidth: isSelected ? 3 : 1
                    )
            )
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(ringColor)
                        .background(
                            Circle().fill(candidate.background)
                        )
                        .padding(Spacing.sm)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(candidate.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
