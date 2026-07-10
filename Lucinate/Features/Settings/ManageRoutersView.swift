import SwiftUI

/// Saved-router management: switch, add, edit, remove, and log out.
struct ManageRoutersView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    @State private var formTarget: RouterFormTarget?
    @State private var routerPendingSwitch: Router?
    @State private var routerPendingRemoval: Router?
    @State private var showLogoutConfirm = false

    var body: some View {
        List {
            Section {
                if appState.routers.isEmpty {
                    Text("No saved routers")
                        .foregroundStyle(theme.textSecondary)
                        .listRowBackground(theme.surface)
                } else {
                    ForEach(appState.routers) { router in
                        routerRow(router)
                            .listRowBackground(theme.surface)
                    }
                }
            }

            Section {
                Button(role: .destructive) {
                    showLogoutConfirm = true
                } label: {
                    Text("Log Out")
                        .foregroundStyle(theme.error)
                        .frame(maxWidth: .infinity)
                }
                .listRowBackground(theme.surface)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.background)
        .navigationTitle("Manage Routers")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    formTarget = RouterFormTarget(router: nil)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add Router")
            }
        }
        .sheet(item: $formTarget) { target in
            RouterFormView(existing: target.router)
        }
        .confirmationDialog(
            "Switch Router?",
            isPresented: switchConfirmBinding,
            titleVisibility: .visible,
            presenting: routerPendingSwitch
        ) { router in
            Button("Switch to \(router.displayName)") {
                Haptics.selection()
                Task { await appState.switchRouter(id: router.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { router in
            Text("Disconnect and connect to \(router.displayName)?")
        }
        .confirmationDialog(
            "Remove Router?",
            isPresented: removeConfirmBinding,
            titleVisibility: .visible,
            presenting: routerPendingRemoval
        ) { router in
            Button("Remove", role: .destructive) {
                Haptics.warning()
                appState.removeRouter(id: router.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: { router in
            Text("This removes the saved credentials for \(router.displayName).")
        }
        .confirmationDialog(
            "Log out?",
            isPresented: $showLogoutConfirm,
            titleVisibility: .visible
        ) {
            Button("Log Out", role: .destructive) {
                Haptics.warning()
                appState.logout()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears saved credentials and accepted certificates.")
        }
    }

    // MARK: - Row

    private func routerRow(_ router: Router) -> some View {
        let isActive = router.id == appState.selectedRouterID
        return HStack(spacing: Spacing.md) {
            Button {
                if !isActive {
                    routerPendingSwitch = router
                }
            } label: {
                HStack(spacing: Spacing.md) {
                    StatusDot(
                        color: isActive ? theme.accent : theme.separator,
                        glows: isActive
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(router.displayName)
                            .font(.body)
                            .foregroundStyle(theme.textPrimary)
                        Text("\(router.username)@\(router.ipAddress)")
                            .font(.caption)
                            .foregroundStyle(theme.textSecondary)
                    }
                    Spacer(minLength: Spacing.sm)
                    if isActive {
                        Text("Active")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(theme.accent)
                            .padding(.horizontal, Spacing.sm)
                            .padding(.vertical, Spacing.xs)
                            .background(
                                Capsule().fill(theme.accent.opacity(0.15))
                            )
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)

            Button {
                formTarget = RouterFormTarget(router: router)
            } label: {
                Image(systemName: "info.circle")
                    .foregroundStyle(theme.accent)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Edit \(router.displayName)")
        }
        .contextMenu {
            Button {
                formTarget = RouterFormTarget(router: router)
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            Button(role: .destructive) {
                routerPendingRemoval = router
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                routerPendingRemoval = router
            } label: {
                Label("Remove", systemImage: "trash")
            }
            .tint(theme.error)
        }
    }

    // MARK: - Dialog bindings

    private var switchConfirmBinding: Binding<Bool> {
        Binding(
            get: { routerPendingSwitch != nil },
            set: { if !$0 { routerPendingSwitch = nil } }
        )
    }

    private var removeConfirmBinding: Binding<Bool> {
        Binding(
            get: { routerPendingRemoval != nil },
            set: { if !$0 { routerPendingRemoval = nil } }
        )
    }
}

/// Identifiable wrapper so a single sheet handles both add (nil) and edit.
private struct RouterFormTarget: Identifiable {
    let router: Router?
    var id: String { router?.id ?? "new-router" }
}

/// Add/Edit form for a saved router, presented as its own sheet.
private struct RouterFormView: View {
    let existing: Router?

    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var address: String
    @State private var username: String
    @State private var password: String
    @State private var useHttps: Bool
    @State private var errorMessage: String?

    init(existing: Router?) {
        self.existing = existing
        _address = State(initialValue: existing?.ipAddress ?? "")
        _username = State(initialValue: existing?.username ?? "root")
        _password = State(initialValue: existing?.password ?? "")
        _useHttps = State(initialValue: existing?.useHttps ?? false)
    }

    private var trimmedAddress: String {
        address.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedUsername: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedAddress.isEmpty && !trimmedUsername.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    TextField("Address", text: $address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .listRowBackground(theme.surface)
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .listRowBackground(theme.surface)
                    SecureField("Password", text: $password)
                        .listRowBackground(theme.surface)
                    Toggle("Use HTTPS", isOn: $useHttps)
                        .listRowBackground(theme.surface)
                        .onChange(of: useHttps) { _, _ in
                            Haptics.selection()
                        }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(theme.error)
                            .listRowBackground(theme.surface)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.background)
            .foregroundStyle(theme.textPrimary)
            .navigationTitle(existing == nil ? "Add Router" : "Edit Router")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        save()
                    }
                    .disabled(!canSave)
                }
            }
        }
        .tint(theme.accent)
    }

    private func save() {
        errorMessage = nil
        let newID = Router.makeID(ipAddress: trimmedAddress, username: trimmedUsername)

        if let existing {
            if newID == existing.id {
                // Same identity: in-place update, keep the known hostname.
                let updated = Router(
                    id: newID,
                    ipAddress: trimmedAddress,
                    username: trimmedUsername,
                    password: password,
                    useHttps: useHttps,
                    lastKnownHostname: existing.lastKnownHostname
                )
                appState.updateRouter(updated)
            } else {
                // Identity changed: make sure the new id is free before
                // dropping the old entry, so a failed save loses nothing.
                if appState.routers.contains(where: { $0.id == newID }) {
                    errorMessage = "This router is already saved"
                    Haptics.error()
                    return
                }
                let replacement = Router(
                    id: newID,
                    ipAddress: trimmedAddress,
                    username: trimmedUsername,
                    password: password,
                    useHttps: useHttps,
                    lastKnownHostname: nil
                )
                appState.removeRouter(id: existing.id)
                guard appState.addRouter(replacement) else {
                    errorMessage = "This router is already saved"
                    Haptics.error()
                    return
                }
            }
        } else {
            let router = Router(
                id: newID,
                ipAddress: trimmedAddress,
                username: trimmedUsername,
                password: password,
                useHttps: useHttps,
                lastKnownHostname: nil
            )
            guard appState.addRouter(router) else {
                errorMessage = "This router is already saved"
                Haptics.error()
                return
            }
        }

        Haptics.success()
        dismiss()
    }
}
