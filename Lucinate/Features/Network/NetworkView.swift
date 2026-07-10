import SwiftUI

/// Network hub: a segmented Clients | Interfaces switcher with a shared search
/// field, plus a "more" menu for the secondary tools (Wi-Fi, Static Leases,
/// Firewall, Diagnostics). Controls live in-content — flush against the top
/// safe area, no navigation bar.
struct NetworkView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    @State private var searchText = ""
    @State private var clientsController = ClientsController()
    @State private var interfacesController = InterfacesController()

    var body: some View {
        @Bindable var state = appState
        VStack(spacing: 0) {
            VStack(spacing: Spacing.sm) {
                HStack(spacing: Spacing.sm) {
                    Picker("Section", selection: $state.networkSegment) {
                        ForEach(AppState.NetworkSegment.allCases, id: \.self) { segment in
                            Text(segment.rawValue).tag(segment)
                        }
                    }
                    .pickerStyle(.segmented)

                    Menu {
                        NavigationLink {
                            WifiSettingsView()
                        } label: {
                            Label("Wi-Fi Settings", systemImage: "wifi")
                        }
                        NavigationLink {
                            StaticLeasesView()
                        } label: {
                            Label("Static Leases", systemImage: "pin")
                        }
                        NavigationLink {
                            FirewallView()
                        } label: {
                            Label("Firewall", systemImage: "shield.lefthalf.filled")
                        }
                        NavigationLink {
                            DiagnosticsView()
                        } label: {
                            Label("Diagnostics", systemImage: "stethoscope")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.title3)
                            .foregroundStyle(theme.accent)
                            .frame(width: 32, height: 32)
                    }
                }

                SearchField(text: $searchText, prompt: "Search by name, IP, MAC…")
            }
            .padding(.horizontal, Spacing.md)
            .padding(.top, Spacing.sm)
            .padding(.bottom, Spacing.xs)

            switch appState.networkSegment {
            case .clients:
                ClientsListView(controller: clientsController, searchText: searchText)
            case .interfaces:
                InterfacesListView(controller: interfacesController, searchText: searchText)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
        .onAppear { redirectToScrollTargetIfNeeded() }
        .onChange(of: appState.networkScrollTarget) { redirectToScrollTargetIfNeeded() }
        .onChange(of: appState.networkSegment) {
            Haptics.selection()
        }
    }

    /// A pending scroll target always lives in the Interfaces segment; switch
    /// there so InterfacesListView can expand + scroll to it (and consume it).
    private func redirectToScrollTargetIfNeeded() {
        if appState.networkScrollTarget != nil, appState.networkSegment != .interfaces {
            appState.networkSegment = .interfaces
        }
    }
}

/// Lightweight in-content search field (the nav-bar `.searchable` isn't
/// available once the bar is hidden).
struct SearchField: View {
    @Binding var text: String
    var prompt: String

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(theme.textSecondary)
            TextField(prompt, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(theme.textPrimary)
                .submitLabel(.search)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(theme.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.subheadline)
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 9)
        .background(theme.surface, in: .capsule)
    }
}
