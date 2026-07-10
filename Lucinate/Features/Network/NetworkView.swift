import SwiftUI

/// Network hub: the selected list (Clients | Interfaces) fills the whole
/// screen edge-to-edge, with a floating Liquid Glass segment switcher
/// overlaid at the top — content scrolls visibly underneath it. Search lives
/// inside each list's scrolling content (immersive, Messages-style).
struct NetworkView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    @State private var searchText = ""
    @State private var clientsController = ClientsController()
    @State private var interfacesController = InterfacesController()

    var body: some View {
        Group {
            switch appState.networkSegment {
            case .clients:
                ClientsListView(controller: clientsController, searchText: $searchText)
            case .interfaces:
                InterfacesListView(controller: interfacesController, searchText: $searchText)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
        .overlay(alignment: .top) { segmentSwitcher }
        .onAppear { redirectToScrollTargetIfNeeded() }
        .onChange(of: appState.networkScrollTarget) { redirectToScrollTargetIfNeeded() }
        .onChange(of: appState.networkSegment) {
            Haptics.selection()
        }
    }

    // MARK: - Floating glass segment switcher

    private var segmentSwitcher: some View {
        HStack(spacing: Spacing.xs) {
            ForEach(AppState.NetworkSegment.allCases, id: \.self) { segment in
                segmentButton(segment)
            }
        }
        .padding(4)
        .glassCapsule()
        // The whole capsule (including the rim between/around the buttons)
        // must win hit-testing over list rows scrolling beneath it.
        .contentShape(.capsule)
        .padding(.top, Spacing.xs)
    }

    private func segmentButton(_ segment: AppState.NetworkSegment) -> some View {
        let isSelected = appState.networkSegment == segment
        return Button {
            guard !isSelected else { return }
            withAnimation(.snappy) {
                appState.networkSegment = segment
            }
        } label: {
            Text(segment.rawValue)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? theme.accent : theme.textSecondary)
                .padding(.horizontal, Spacing.lg)
                .frame(minHeight: 44)  // comfortable tap target over scrolling rows
                .background(
                    isSelected ? theme.accent.opacity(0.18) : Color.clear,
                    in: .capsule
                )
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
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
