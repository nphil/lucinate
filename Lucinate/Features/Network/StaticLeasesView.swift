import SwiftUI
import Observation

// MARK: - Controller

/// Loads and mutates DHCP static leases (`uci dhcp` host sections) via the
/// Tier A RouterService helpers.
@MainActor
@Observable
final class StaticLeasesController {
    struct Lease: Identifiable, Equatable, Sendable {
        let section: String
        /// Taken as-is from UCI — may contain several space-separated MACs.
        let mac: String
        let ip: String
        let name: String

        var id: String { section }
    }

    private(set) var leases: [Lease] = []
    /// True only while loading with nothing cached (cached-first UX).
    private(set) var isLoading = false
    private(set) var error: String?

    // MARK: Loading

    func load(service: RouterService?) async {
        guard let service else {
            leases = []
            error = nil
            return
        }
        if leases.isEmpty { isLoading = true }
        defer { isLoading = false }
        do {
            let sections = try await service.staticLeases()
            leases = sections.map { entry in
                let values = entry.values
                let macValue = values["mac"]
                // MAC is usually a string, but UCI lists arrive as arrays.
                let mac = macValue.coercedString
                    ?? macValue.arrayValue?
                        .compactMap { $0.coercedString }
                        .joined(separator: " ")
                    ?? ""
                return Lease(
                    section: entry.section,
                    mac: mac,
                    ip: values["ip"].coercedString ?? "",
                    name: values["name"].coercedString ?? ""
                )
            }
            .sorted(by: StaticLeasesController.orderedBefore)
            error = nil
        } catch {
            if leases.isEmpty {
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: CRUD (return success; capture the error for toasts)

    func add(mac: String, ip: String, name: String?, service: RouterService) async -> Bool {
        do {
            try await service.addStaticLease(mac: mac, ip: ip, name: name)
            error = nil
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func update(
        section: String, mac: String, ip: String, name: String?, service: RouterService
    ) async -> Bool {
        do {
            try await service.updateStaticLease(section: section, mac: mac, ip: ip, name: name)
            error = nil
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func delete(section: String, service: RouterService) async -> Bool {
        do {
            try await service.deleteStaticLease(section: section)
            leases.removeAll { $0.section == section }
            error = nil
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    // MARK: Sorting (numeric by IP, unparseable IPs last, then by name)

    private nonisolated static func octets(_ ip: String) -> [Int]? {
        let parts = ip.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var result: [Int] = []
        for part in parts {
            guard let value = Int(part), (0...255).contains(value) else { return nil }
            result.append(value)
        }
        return result
    }

    private nonisolated static func orderedBefore(_ a: Lease, _ b: Lease) -> Bool {
        switch (octets(a.ip), octets(b.ip)) {
        case let (octetsA?, octetsB?):
            if octetsA != octetsB {
                return octetsA.lexicographicallyPrecedes(octetsB)
            }
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        case (nil, nil):
            break
        }
        let nameA = a.name.isEmpty ? "Unnamed" : a.name
        let nameB = b.name.isEmpty ? "Unnamed" : b.name
        let comparison = nameA.localizedCaseInsensitiveCompare(nameB)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return a.section < b.section
    }
}

// MARK: - View

/// DHCP reservation manager, pushed from the Network tab. Also presented as a
/// sheet by the clients list ("Reserve IP"), in which case the add form opens
/// pre-filled on appear.
struct StaticLeasesView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    private let prefillMAC: String?
    private let prefillIP: String?
    private let prefillName: String?

    @State private var controller = StaticLeasesController()
    @State private var activeSheet: LeaseSheet?
    @State private var pendingDelete: StaticLeasesController.Lease?
    @State private var showDeleteConfirm = false
    @State private var didHandlePrefill = false

    init(prefillMAC: String? = nil, prefillIP: String? = nil, prefillName: String? = nil) {
        self.prefillMAC = prefillMAC
        self.prefillIP = prefillIP
        self.prefillName = prefillName
    }

    private enum LeaseSheet: Identifiable {
        case add(mac: String?, ip: String?, name: String?)
        case edit(StaticLeasesController.Lease)

        var id: String {
            switch self {
            case .add: return "add"
            case .edit(let lease): return "edit-\(lease.section)"
            }
        }
    }

    var body: some View {
        content
            .background(theme.background)
            .navigationTitle("Static Leases")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.impact(.light)
                        activeSheet = .add(mac: nil, ip: nil, name: nil)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add Reservation")
                }
            }
            .task {
                if !didHandlePrefill, let prefillMAC {
                    didHandlePrefill = true
                    activeSheet = .add(mac: prefillMAC, ip: prefillIP, name: prefillName)
                }
                await reload()
            }
            .sheet(item: $activeSheet) { sheet in
                formSheet(for: sheet)
            }
            .confirmationDialog(
                "Remove Reservation?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { lease in
                Button("Remove", role: .destructive) {
                    Haptics.warning()
                    Task { await performDelete(lease) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("This device will get a dynamic address on its next lease renewal.")
            }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if controller.isLoading && controller.leases.isEmpty {
            ScrollView {
                VStack(spacing: Spacing.sm) {
                    ForEach(0..<6, id: \.self) { _ in
                        SkeletonBlock(height: 72, cornerRadius: CornerRadius.card)
                    }
                }
                .padding(.horizontal, Spacing.md)
                .padding(.top, Spacing.sm)
            }
        } else if let error = controller.error, controller.leases.isEmpty {
            ScrollView {
                ErrorStateView(message: error) {
                    Task { await reload() }
                }
                .padding(.top, Spacing.xxl)
            }
            .refreshable { await reload() }
        } else if controller.leases.isEmpty {
            ScrollView {
                EmptyStateView(
                    systemImage: "pin.slash",
                    title: "No static leases",
                    message: "Reserve an IP for a device to always get the same address."
                )
                .padding(.top, Spacing.xxl)
            }
            .refreshable { await reload() }
        } else {
            List {
                ForEach(controller.leases) { lease in
                    leaseRow(lease)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .refreshable {
                Haptics.impact(.medium)
                await reload()
            }
        }
    }

    private func leaseRow(_ lease: StaticLeasesController.Lease) -> some View {
        Button {
            Haptics.selection()
            activeSheet = .edit(lease)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(lease.name.isEmpty ? "Unnamed" : lease.name)
                    .font(.cardTitle)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Text(lease.ip.isEmpty ? "No IP" : lease.ip)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                Text(lease.mac.isEmpty ? "No MAC" : lease.mac)
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowBackground(theme.surface)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                pendingDelete = lease
                showDeleteConfirm = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: Sheets

    @ViewBuilder
    private func formSheet(for sheet: LeaseSheet) -> some View {
        switch sheet {
        case .add(let mac, let ip, let name):
            LeaseFormSheet(
                title: "Add Reservation",
                initialName: name ?? "",
                initialMAC: mac ?? "",
                initialIP: ip ?? ""
            ) { mac, ip, name in
                await saveLease(section: nil, mac: mac, ip: ip, name: name)
            }
        case .edit(let lease):
            LeaseFormSheet(
                title: "Edit Reservation",
                initialName: lease.name,
                initialMAC: lease.mac,
                initialIP: lease.ip
            ) { mac, ip, name in
                await saveLease(section: lease.section, mac: mac, ip: ip, name: name)
            }
        }
    }

    // MARK: Actions

    private func reload() async {
        await controller.load(service: appState.service)
    }

    /// Adds (section == nil) or updates a reservation. Returns success so the
    /// form sheet knows whether to dismiss.
    private func saveLease(section: String?, mac: String, ip: String, name: String?) async -> Bool {
        guard let service = appState.service else {
            appState.showToast("Not connected to a router")
            return false
        }
        let ok: Bool
        if let section {
            ok = await controller.update(
                section: section, mac: mac, ip: ip, name: name, service: service)
        } else {
            ok = await controller.add(mac: mac, ip: ip, name: name, service: service)
        }
        if ok {
            Haptics.success()
            appState.showToast("Reservation saved")
            await reload()
        } else {
            Haptics.warning()
            appState.showToast(controller.error ?? "Could not save the reservation")
        }
        return ok
    }

    private func performDelete(_ lease: StaticLeasesController.Lease) async {
        guard let service = appState.service else {
            appState.showToast("Not connected to a router")
            return
        }
        if await controller.delete(section: lease.section, service: service) {
            Haptics.success()
            appState.showToast("Reservation removed")
            await reload()
        } else {
            Haptics.warning()
            appState.showToast(controller.error ?? "Could not remove the reservation")
        }
    }
}

// MARK: - Add/Edit form sheet

private struct LeaseFormSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let title: String
    /// Returns true on success (the sheet then dismisses itself).
    let onSave: @MainActor (_ mac: String, _ ip: String, _ name: String?) async -> Bool

    @State private var name: String
    @State private var mac: String
    @State private var ip: String
    @State private var isSaving = false

    init(
        title: String,
        initialName: String,
        initialMAC: String,
        initialIP: String,
        onSave: @escaping @MainActor (_ mac: String, _ ip: String, _ name: String?) async -> Bool
    ) {
        self.title = title
        self.onSave = onSave
        _name = State(initialValue: initialName)
        _mac = State(initialValue: initialMAC)
        _ip = State(initialValue: initialIP)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Hostname (optional)", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("MAC Address", text: $mac)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                    TextField("IP Address", text: $ip)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .keyboardType(.numbersAndPunctuation)
                } footer: {
                    validationFooter
                }
                .listRowBackground(theme.surface)
            }
            .scrollContentBackground(.hidden)
            .background(theme.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { save() }
                            .disabled(!canSave)
                    }
                }
            }
            .interactiveDismissDisabled(isSaving)
        }
    }

    @ViewBuilder
    private var validationFooter: some View {
        if !trimmedMAC.isEmpty && !macIsValid {
            Text("MAC must look like AA:BB:CC:DD:EE:FF.")
                .foregroundStyle(theme.error)
        } else if !trimmedIP.isEmpty && !ipIsValid {
            Text("IP must be four numbers 0–255, like 192.168.1.50.")
                .foregroundStyle(theme.error)
        } else {
            Text("The device will always receive this address from DHCP.")
        }
    }

    // MARK: Validation

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedMAC: String {
        mac.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedIP: String {
        ip.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Every space-separated token must be a full MAC (UCI hosts may bind
    /// several MACs to one reservation).
    private var macIsValid: Bool {
        let pattern = "^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$"
        let tokens = trimmedMAC.split(separator: " ")
        guard !tokens.isEmpty else { return false }
        return tokens.allSatisfy {
            String($0).range(of: pattern, options: .regularExpression) != nil
        }
    }

    private var ipIsValid: Bool {
        let parts = trimmedIP.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty, part.count <= 3, let value = Int(part) else { return false }
            return (0...255).contains(value)
        }
    }

    private var canSave: Bool {
        macIsValid && ipIsValid && !isSaving
    }

    // MARK: Save

    private func save() {
        guard canSave else { return }
        isSaving = true
        let savedMAC = trimmedMAC.uppercased()
        let savedIP = trimmedIP
        let savedName = trimmedName.isEmpty ? nil : trimmedName
        Task {
            let ok = await onSave(savedMAC, savedIP, savedName)
            isSaving = false
            if ok { dismiss() }
        }
    }
}
