import SwiftUI

/// Root settings screen, designed for `.sheet` presentation.
struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var showExitReviewerConfirm = false

    var body: some View {
        @Bindable var themeManager = themeManager

        NavigationStack {
            List {
                Section("Appearance") {
                    Picker("Theme Mode", selection: $themeManager.mode) {
                        ForEach(ThemeMode.allCases, id: \.self) { mode in
                            Text(mode.displayLabel).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(theme.surface)

                    NavigationLink {
                        ThemePickerView(isDark: false)
                    } label: {
                        LabeledContent("Light Palette") {
                            Text(themeManager.lightTheme.name)
                                .foregroundStyle(theme.textSecondary)
                        }
                    }
                    .listRowBackground(theme.surface)

                    NavigationLink {
                        ThemePickerView(isDark: true)
                    } label: {
                        LabeledContent("Dark Palette") {
                            Text(themeManager.darkTheme.name)
                                .foregroundStyle(theme.textSecondary)
                        }
                    }
                    .listRowBackground(theme.surface)
                }

                Section("Dashboard") {
                    NavigationLink("Customize Dashboard") {
                        DashboardPrefsView()
                    }
                    .listRowBackground(theme.surface)
                }

                Section("Routers") {
                    NavigationLink("Manage Routers") {
                        ManageRoutersView()
                    }
                    .listRowBackground(theme.surface)
                }

                Section("About") {
                    NavigationLink("About Lucinate") {
                        AboutView()
                    }
                    .listRowBackground(theme.surface)
                }

                if appState.isReviewerMode {
                    Section {
                        Button(role: .destructive) {
                            showExitReviewerConfirm = true
                        } label: {
                            Text("Exit Reviewer Mode")
                                .foregroundStyle(theme.error)
                        }
                        .listRowBackground(theme.surface)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.background)
            .foregroundStyle(theme.textPrimary)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .confirmationDialog(
                "Exit Reviewer Mode?",
                isPresented: $showExitReviewerConfirm,
                titleVisibility: .visible
            ) {
                Button("Exit Reviewer Mode", role: .destructive) {
                    Haptics.warning()
                    appState.exitReviewerMode()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You will return to the login screen.")
            }
        }
        .tint(theme.accent)
        .onChange(of: themeManager.mode) { _, _ in
            Haptics.selection()
        }
    }
}

extension ThemeMode {
    fileprivate var displayLabel: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}
