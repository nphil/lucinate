import SwiftUI

/// Network hub: a segmented Clients | Interfaces switcher pinned under the
/// nav title, with one shared search field filtering whichever list is shown.
struct NetworkView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    @State private var searchText = ""
    @State private var clientsController = ClientsController()
    @State private var interfacesController = InterfacesController()

    var body: some View {
        @Bindable var state = appState
        VStack(spacing: 0) {
            Picker("Section", selection: $state.networkSegment) {
                ForEach(AppState.NetworkSegment.allCases, id: \.self) { segment in
                    Text(segment.rawValue).tag(segment)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Spacing.md)
            .padding(.bottom, Spacing.sm)

            switch appState.networkSegment {
            case .clients:
                ClientsListView(controller: clientsController, searchText: searchText)
            case .interfaces:
                InterfacesListView(controller: interfacesController, searchText: searchText)
            }
        }
        .background(theme.background)
        .navigationTitle("Network")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
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
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search by name, IP, MAC…")
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
