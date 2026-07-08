import SwiftUI

/// Firewall management, pushed from the Network tab: DNAT port forwards
/// (full CRUD) and traffic rules (list + enable/disable with a lockout guard
/// rail on "Allow" rules).
struct FirewallView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    @State private var controller = FirewallController()
    @State private var activeSheet: ForwardSheet?
    @State private var pendingDelete: FirewallController.PortForward?
    @State private var pendingRuleDisable: FirewallController.FirewallRule?

    private enum ForwardSheet: Identifiable {
        case add
        case edit(FirewallController.PortForward)

        var id: String {
            switch self {
            case .add: return "add"
            case .edit(let forward): return "edit-\(forward.section)"
            }
        }
    }

    var body: some View {
        content
            .background(theme.background)
            .navigationTitle("Firewall")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.impact(.light)
                        activeSheet = .add
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add Port Forward")
                }
            }
            .task(id: appState.selectedRouterID) {
                await reload()
            }
            .sheet(item: $activeSheet) { sheet in
                formSheet(for: sheet)
            }
            .confirmationDialog(
                "Delete Port Forward?",
                isPresented: deleteConfirmBinding,
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { forward in
                Button("Delete", role: .destructive) {
                    Haptics.warning()
                    Task { await performDelete(forward) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { forward in
                Text("External traffic will no longer reach \(forwardTarget(forward)).")
            }
            .confirmationDialog(
                "Disable Rule?",
                isPresented: ruleDisableConfirmBinding,
                titleVisibility: .visible,
                presenting: pendingRuleDisable
            ) { rule in
                Button("Disable", role: .destructive) {
                    Haptics.warning()
                    Task {
                        await controller.setEnabled(
                            false, section: rule.section, service: appState.service)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Disabling this rule may lock you out. Continue?")
            }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if controller.isLoading && controller.isEmpty {
            ScrollView {
                VStack(spacing: Spacing.sm) {
                    ForEach(0..<6, id: \.self) { _ in
                        SkeletonBlock(height: 72, cornerRadius: CornerRadius.card)
                    }
                }
                .padding(.horizontal, Spacing.md)
                .padding(.top, Spacing.sm)
            }
        } else if let error = controller.error, controller.isEmpty {
            ScrollView {
                ErrorStateView(message: error) {
                    Task { await reload() }
                }
                .padding(.top, Spacing.xxl)
            }
            .refreshable { await reload() }
        } else if controller.isEmpty {
            ScrollView {
                EmptyStateView(
                    systemImage: "shield.slash",
                    title: "No firewall entries",
                    message: "Add a port forward to expose an internal service."
                )
                .padding(.top, Spacing.xxl)
            }
            .refreshable { await reload() }
        } else {
            List {
                Section("Port Forwards") {
                    if controller.forwards.isEmpty {
                        inlineEmptyText("No port forwards yet")
                    } else {
                        ForEach(controller.forwards) { forward in
                            forwardRow(forward)
                        }
                    }
                }

                Section("Traffic Rules") {
                    if controller.rules.isEmpty {
                        inlineEmptyText("No traffic rules")
                    } else {
                        ForEach(controller.rules) { rule in
                            ruleRow(rule)
                        }
                    }
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

    private func inlineEmptyText(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(theme.textSecondary)
            .listRowBackground(theme.surface)
    }

    // MARK: - Rows

    private func forwardRow(_ forward: FirewallController.PortForward) -> some View {
        HStack(spacing: Spacing.md) {
            Button {
                Haptics.selection()
                activeSheet = .edit(forward)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(forward.name.isEmpty ? "(unnamed)" : forward.name)
                        .font(.cardTitle)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    Text(forwardSummary(forward))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Edit \(forward.name.isEmpty ? "port forward" : forward.name)")

            Spacer(minLength: Spacing.sm)

            Toggle("", isOn: forwardEnabledBinding(for: forward))
                .labelsHidden()
                .tint(theme.accent)
                .disabled(controller.isBusy)
                .accessibilityLabel(
                    "Enable \(forward.name.isEmpty ? "port forward" : forward.name)")
        }
        .listRowBackground(theme.surface)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                pendingDelete = forward
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func forwardSummary(_ forward: FirewallController.PortForward) -> String {
        let proto = forward.proto.isEmpty ? "tcp udp" : forward.proto
        return "\(proto) :\(forward.srcDPort) → \(forwardTarget(forward))"
    }

    private func forwardTarget(_ forward: FirewallController.PortForward) -> String {
        let ip = forward.destIP.isEmpty ? "?" : forward.destIP
        return forward.destPort.isEmpty ? ip : "\(ip):\(forward.destPort)"
    }

    private func ruleRow(_ rule: FirewallController.FirewallRule) -> some View {
        HStack(spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name.isEmpty ? "(unnamed)" : rule.name)
                    .font(.cardTitle)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Text(ruleSummary(rule))
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: Spacing.sm)

            Toggle("", isOn: ruleEnabledBinding(for: rule))
                .labelsHidden()
                .tint(theme.accent)
                .disabled(controller.isBusy)
                .accessibilityLabel("Enable \(rule.name.isEmpty ? "rule" : rule.name)")
        }
        .listRowBackground(theme.surface)
    }

    private func ruleSummary(_ rule: FirewallController.FirewallRule) -> String {
        let src = rule.src.isEmpty ? "any" : rule.src
        let dest = rule.dest.isEmpty ? "device" : rule.dest
        let proto = rule.proto.isEmpty ? "all" : rule.proto
        var parts = ["\(src) → \(dest)", proto]
        if !rule.target.isEmpty { parts.append(rule.target) }
        return parts.joined(separator: " • ")
    }

    // MARK: - Toggle bindings

    private func forwardEnabledBinding(
        for forward: FirewallController.PortForward
    ) -> Binding<Bool> {
        Binding(
            get: {
                controller.forwards
                    .first { $0.section == forward.section }?
                    .enabled ?? forward.enabled
            },
            set: { newValue in
                Haptics.selection()
                Task {
                    await controller.setEnabled(
                        newValue, section: forward.section, service: appState.service)
                }
            }
        )
    }

    private func ruleEnabledBinding(for rule: FirewallController.FirewallRule) -> Binding<Bool> {
        Binding(
            get: {
                controller.rules
                    .first { $0.section == rule.section }?
                    .enabled ?? rule.enabled
            },
            set: { newValue in
                if !newValue, rule.name.localizedCaseInsensitiveContains("Allow") {
                    // Guard rail: disabling an Allow-* rule can cut off access.
                    pendingRuleDisable = rule
                } else {
                    Haptics.selection()
                    Task {
                        await controller.setEnabled(
                            newValue, section: rule.section, service: appState.service)
                    }
                }
            }
        )
    }

    // MARK: - Sheets

    @ViewBuilder
    private func formSheet(for sheet: ForwardSheet) -> some View {
        switch sheet {
        case .add:
            ForwardFormSheet(title: "Add Port Forward", forward: nil) { draft in
                await saveForward(section: nil, draft: draft)
            }
        case .edit(let forward):
            ForwardFormSheet(title: "Edit Port Forward", forward: forward) { draft in
                await saveForward(section: forward.section, draft: draft)
            }
        }
    }

    // MARK: - Actions

    private func reload() async {
        await controller.load(service: appState.service)
    }

    /// Adds (section == nil) or updates a port forward. Returns success so the
    /// form sheet knows whether to dismiss.
    private func saveForward(section: String?, draft: ForwardDraft) async -> Bool {
        guard let service = appState.service else {
            appState.showToast("Not connected to a router")
            return false
        }
        let ok: Bool
        if let section {
            ok = await controller.updateForward(
                section: section, name: draft.name, proto: draft.proto,
                srcDPort: draft.srcDPort, destIP: draft.destIP, destPort: draft.destPort,
                service: service)
        } else {
            ok = await controller.addForward(
                name: draft.name, proto: draft.proto, srcDPort: draft.srcDPort,
                destIP: draft.destIP, destPort: draft.destPort, service: service)
        }
        if ok {
            Haptics.success()
            appState.showToast("Port forward saved")
        } else {
            Haptics.warning()
            appState.showToast(controller.error ?? "Could not save the port forward")
        }
        return ok
    }

    private func performDelete(_ forward: FirewallController.PortForward) async {
        guard let service = appState.service else {
            appState.showToast("Not connected to a router")
            return
        }
        if await controller.deleteForward(section: forward.section, service: service) {
            Haptics.success()
            appState.showToast("Port forward deleted")
        } else {
            Haptics.warning()
            appState.showToast(controller.error ?? "Could not delete the port forward")
        }
    }

    // MARK: - Dialog plumbing

    private var deleteConfirmBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    private var ruleDisableConfirmBinding: Binding<Bool> {
        Binding(
            get: { pendingRuleDisable != nil },
            set: { if !$0 { pendingRuleDisable = nil } }
        )
    }
}

// MARK: - Form draft

/// Validated values handed from the form sheet to the save action.
private struct ForwardDraft {
    let name: String
    /// "tcp", "udp", or "tcp udp".
    let proto: String
    let srcDPort: String
    let destIP: String
    let destPort: String
}

// MARK: - Add/Edit form sheet

private struct ForwardFormSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    private enum ForwardProtocol: String, CaseIterable, Identifiable {
        case tcp = "tcp"
        case udp = "udp"
        case both = "tcp udp"

        var id: String { rawValue }

        var label: String {
            switch self {
            case .tcp: return "TCP"
            case .udp: return "UDP"
            case .both: return "TCP+UDP"
            }
        }

        init(uciValue: String) {
            switch uciValue.lowercased() {
            case "tcp": self = .tcp
            case "udp": self = .udp
            default: self = .both
            }
        }
    }

    let title: String
    /// Returns true on success (the sheet then dismisses itself).
    let onSave: @MainActor (ForwardDraft) async -> Bool

    @State private var name: String
    @State private var proto: ForwardProtocol
    @State private var srcDPort: String
    @State private var destIP: String
    @State private var destPort: String
    @State private var isSaving = false

    init(
        title: String,
        forward: FirewallController.PortForward?,
        onSave: @escaping @MainActor (ForwardDraft) async -> Bool
    ) {
        self.title = title
        self.onSave = onSave
        _name = State(initialValue: forward?.name ?? "")
        _proto = State(initialValue: ForwardProtocol(uciValue: forward?.proto ?? "tcp"))
        _srcDPort = State(initialValue: forward?.srcDPort ?? "")
        _destIP = State(initialValue: forward?.destIP ?? "")
        _destPort = State(initialValue: forward?.destPort ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker("Protocol", selection: $proto) {
                        ForEach(ForwardProtocol.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    TextField("External Port (e.g. 8080 or 8000-8010)", text: $srcDPort)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .keyboardType(.numbersAndPunctuation)
                    TextField("Internal IP", text: $destIP)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .keyboardType(.numbersAndPunctuation)
                    TextField("Internal Port", text: $destPort)
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
        .tint(theme.accent)
    }

    @ViewBuilder
    private var validationFooter: some View {
        if !trimmedSrcDPort.isEmpty && !ForwardFormSheet.isValidPort(trimmedSrcDPort) {
            Text("External port must be 1–65535, or a range like 8000-8010.")
                .foregroundStyle(theme.error)
        } else if !trimmedDestIP.isEmpty && !ForwardFormSheet.isValidIP(trimmedDestIP) {
            Text("Internal IP must be four numbers 0–255, like 192.168.1.50.")
                .foregroundStyle(theme.error)
        } else if !trimmedDestPort.isEmpty && !ForwardFormSheet.isValidPort(trimmedDestPort) {
            Text("Internal port must be 1–65535, or a range like 8000-8010.")
                .foregroundStyle(theme.error)
        } else {
            Text("WAN traffic on the external port is forwarded to the internal address.")
        }
    }

    // MARK: Validation

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedSrcDPort: String {
        srcDPort.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedDestIP: String {
        destIP.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedDestPort: String {
        destPort.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A single port (1–65535) or an ascending "start-end" range of two.
    private static func isValidPort(_ text: String) -> Bool {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        func portNumber(_ part: Substring) -> Int? {
            guard !part.isEmpty, part.count <= 5, part.allSatisfy(\.isNumber),
                let value = Int(part), (1...65535).contains(value)
            else { return nil }
            return value
        }
        switch parts.count {
        case 1:
            return portNumber(parts[0]) != nil
        case 2:
            guard let start = portNumber(parts[0]), let end = portNumber(parts[1])
            else { return false }
            return start < end
        default:
            return false
        }
    }

    private static func isValidIP(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isNumber),
                let value = Int(part)
            else { return false }
            return (0...255).contains(value)
        }
    }

    private var canSave: Bool {
        !trimmedName.isEmpty
            && ForwardFormSheet.isValidPort(trimmedSrcDPort)
            && ForwardFormSheet.isValidIP(trimmedDestIP)
            && ForwardFormSheet.isValidPort(trimmedDestPort)
            && !isSaving
    }

    // MARK: Save

    private func save() {
        guard canSave else { return }
        isSaving = true
        let draft = ForwardDraft(
            name: trimmedName,
            proto: proto.rawValue,
            srcDPort: trimmedSrcDPort,
            destIP: trimmedDestIP,
            destPort: trimmedDestPort
        )
        Task {
            let ok = await onSave(draft)
            isSaving = false
            if ok { dismiss() }
        }
    }
}
