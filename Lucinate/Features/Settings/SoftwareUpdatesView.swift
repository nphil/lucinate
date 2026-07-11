import Observation
import SwiftUI
import UIKit

// MARK: - Controller

/// Drives the apk (OpenWrt package manager) update flow: check availability,
/// refresh the index, preview upgradable packages, and perform the upgrade.
/// All command output is accumulated into `log` for a terminal-style view.
@MainActor
@Observable
final class SoftwareUpdatesController {
    enum Stage {
        case idle          // connected, no check run yet
        case checking      // running `apk update` + `apk upgrade --simulate`
        case ready         // preview finished (see upgradeCount / previewPackages)
        case upgrading     // running `apk upgrade`
        case done          // upgrade completed
        case unavailable   // apk not present / ACL denies it
    }

    /// nil = not yet checked; true/false = apk usable on this router.
    private(set) var available: Bool?
    private(set) var stage: Stage = .idle
    private(set) var isBusy = false
    private(set) var error: String?

    /// Number of packages the preview reports as upgradable.
    private(set) var upgradeCount = 0
    /// Human-readable "name (old -> new)" lines parsed from the preview.
    private(set) var previewPackages: [String] = []
    /// Accumulated command output shown in the monospaced Output card.
    private(set) var log = ""
    private(set) var didUpgrade = false

    /// Index of the active progress step (0 refresh, 1 check, 2 install); steps
    /// before it render as completed, the step at it spins, later ones are idle.
    private(set) var activeStep = 0
    /// Caption describing the current long-running activity.
    private(set) var activity = ""

    // MARK: Availability

    func checkAvailability(service: RouterService) async {
        let ok = await service.apkAvailable()
        available = ok
        if !ok { stage = .unavailable }
    }

    // MARK: Check for updates

    func check(service: RouterService) async {
        guard !isBusy else { return }
        isBusy = true
        error = nil
        upgradeCount = 0
        previewPackages = []
        didUpgrade = false
        stage = .checking
        defer { isBusy = false }

        // Step 1: refresh the package index.
        activeStep = 0
        activity = "Refreshing package index…"
        appendLog("$ apk update")
        do {
            let update = try await service.apkUpdate()
            appendLog(update.combinedOutput)
            if !update.succeeded {
                error = Self.failureMessage(update, fallback: "apk update failed.")
                stage = .idle
                return
            }
        } catch {
            self.error = Self.permissionMessage(error)
            stage = .idle
            return
        }

        // Step 2: simulate the upgrade to preview upgradable packages.
        activeStep = 1
        activity = "Checking for upgrades…"
        appendLog("$ apk upgrade --simulate")
        do {
            let preview = try await service.apkUpgradePreview()
            appendLog(preview.combinedOutput)
            if !preview.succeeded {
                error = Self.failureMessage(preview, fallback: "apk upgrade --simulate failed.")
                stage = .ready
                return
            }
            parsePreview(preview)
            stage = .ready
        } catch {
            self.error = Self.permissionMessage(error)
            stage = .ready
        }
    }

    // MARK: Perform the upgrade

    func upgrade(service: RouterService) async {
        guard !isBusy else { return }
        isBusy = true
        error = nil
        stage = .upgrading
        activeStep = 2
        activity = "Installing updates — this can take a few minutes and the connection may briefly drop…"
        defer { isBusy = false }

        appendLog("$ apk upgrade")
        do {
            let result = try await service.apkUpgrade()
            appendLog(result.combinedOutput)
            if result.succeeded {
                didUpgrade = true
                stage = .done
            } else {
                error = Self.failureMessage(result, fallback: "apk upgrade failed.")
                stage = .ready
            }
        } catch {
            self.error = Self.permissionMessage(error)
            stage = .ready
        }
    }

    /// Marks the feature unavailable (e.g. no active connection).
    func markUnavailable() {
        available = false
        stage = .unavailable
    }

    // MARK: - Parsing

    /// Parses the simulate output into readable package lines. Keeps lines that
    /// describe a version change ("… -> …") or a numbered progress step
    /// ("(1/3) Upgrading …"); falls back to all non-empty lines if that yields
    /// nothing. Sets upgradeCount to 0 when the output reports no packages.
    private func parsePreview(_ preview: RouterService.ExecResult) {
        let combined = preview.combinedOutput
        let rawLines = preview.stdout.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        if combined.isEmpty || combined.localizedCaseInsensitiveContains("0 packages") {
            upgradeCount = 0
            previewPackages = []
            return
        }

        var parsed: [String] = []
        for raw in rawLines {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.contains(" -> ") || trimmed.hasPrefix("(") else { continue }
            if let cleaned = Self.cleanPreviewLine(raw) { parsed.append(cleaned) }
        }

        if parsed.isEmpty {
            // Defensive fallback: show whatever non-empty lines we got.
            parsed = rawLines
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }

        previewPackages = parsed
        upgradeCount = parsed.count
    }

    /// Strips a leading "(1/3)" progress counter so the line reads as
    /// "Upgrading luci-base (25.1.1 -> 25.1.2)". Returns nil for empty lines.
    private static func cleanPreviewLine(_ raw: String) -> String? {
        var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        if let range = line.range(of: "^\\(\\d+/\\d+\\)\\s*", options: .regularExpression) {
            line.removeSubrange(range)
        }
        line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return line.isEmpty ? nil : line
    }

    // MARK: - Helpers

    private func appendLog(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if log.isEmpty {
            log = trimmed
        } else {
            log += "\n" + trimmed
        }
    }

    private static func failureMessage(_ result: RouterService.ExecResult, fallback: String)
        -> String
    {
        let output = result.combinedOutput
        return output.isEmpty ? fallback : output
    }

    private static func permissionMessage(_ error: Error) -> String {
        "Could not run apk on the router (\(error.localizedDescription)). This usually means "
            + "rpcd's ACL doesn't permit package management."
    }
}

// MARK: - View

/// "Software Updates" screen: manage OpenWrt apk package upgrades. Pushed from
/// Settings. Compile-blind safe: no force unwraps, all service access guarded.
struct SoftwareUpdatesView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    @State private var controller = SoftwareUpdatesController()
    @State private var showInstallConfirm = false
    @State private var showRebootConfirm = false

    var body: some View {
        content
            .background(theme.background)
            .foregroundStyle(theme.textPrimary)
            .navigationTitle("Software Updates")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                guard let service = appState.service else {
                    controller.markUnavailable()
                    return
                }
                await controller.checkAvailability(service: service)
            }
            .confirmationDialog(
                "Install Updates?",
                isPresented: $showInstallConfirm,
                titleVisibility: .visible
            ) {
                Button("Install Updates", role: .destructive) {
                    Haptics.warning()
                    guard let service = appState.service else { return }
                    Task { await controller.upgrade(service: service) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "Upgrading packages on a router you're connected to can interrupt "
                        + "Wi-Fi/internet and may require a reboot. Only continue on a stable "
                        + "connection and when you can power-cycle the router if needed."
                )
            }
            .confirmationDialog(
                "Reboot now?",
                isPresented: $showRebootConfirm,
                titleVisibility: .visible
            ) {
                Button("Reboot Router", role: .destructive) {
                    Haptics.warning()
                    Task { await appState.reboot() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("A reboot is often needed after core package upgrades.")
            }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if appState.service == nil {
            EmptyStateView(
                systemImage: "wifi.slash",
                title: "Not connected",
                message: "Connect to a router to manage package updates."
            )
            .padding(.top, Spacing.xxl)
        } else if controller.available == false {
            EmptyStateView(
                systemImage: "shippingbox",
                title: "Package Updates Unavailable",
                message: "This router either doesn't use the apk package manager or its rpcd "
                    + "ACL doesn't permit package management. Installing "
                    + "luci-mod-package-manager on the router enables it."
            )
            .padding(.top, Spacing.xxl)
        } else if controller.available == nil {
            VStack {
                ProgressView("Checking package manager…")
                    .padding(.top, Spacing.xxl)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                VStack(spacing: Spacing.md) {
                    headerCard
                    errorBanner
                    actionArea
                    outputCard
                }
                .padding(Spacing.md)
            }
        }
    }

    // MARK: Header

    private var headerCard: some View {
        Card {
            HStack(spacing: Spacing.md) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("OpenWrt Packages")
                        .font(.cardTitle)
                        .foregroundStyle(theme.textPrimary)
                    Text("Update installed packages via apk")
                        .font(.caption)
                        .foregroundStyle(theme.textSecondary)
                }
                Spacer(minLength: Spacing.sm)
            }
        }
    }

    // MARK: Error banner

    @ViewBuilder
    private var errorBanner: some View {
        if let error = controller.error {
            HStack(alignment: .top, spacing: Spacing.sm) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(theme.error)
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(Spacing.md)
            .background(
                theme.error.opacity(0.15),
                in: .rect(cornerRadius: CornerRadius.card, style: .continuous)
            )
        }
    }

    // MARK: Action area

    @ViewBuilder
    private var actionArea: some View {
        switch controller.stage {
        case .idle:
            Card { checkButton("Check for Updates") }
        case .checking, .upgrading:
            progressCard
        case .ready:
            readyCard
        case .done:
            doneCard
        case .unavailable:
            EmptyView()
        }
    }

    private func checkButton(_ title: String) -> some View {
        Button {
            Haptics.impact(.light)
            guard let service = appState.service else { return }
            Task { await controller.check(service: service) }
        } label: {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.xs)
        }
        .buttonStyle(.glassProminent)
        .tint(theme.accent)
        .disabled(controller.isBusy)
    }

    // MARK: Progress (stepper)

    private var progressCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.md) {
                stepRow(index: 0, title: "Refresh index")
                stepRow(index: 1, title: "Check upgrades")
                stepRow(index: 2, title: "Install")
                if !controller.activity.isEmpty {
                    Text(controller.activity)
                        .font(.caption)
                        .foregroundStyle(theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func stepRow(index: Int, title: String) -> some View {
        HStack(spacing: Spacing.sm) {
            stepIcon(index: index)
                .frame(width: 22, height: 22)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(
                    index <= controller.activeStep ? theme.textPrimary : theme.textSecondary)
            Spacer()
        }
    }

    @ViewBuilder
    private func stepIcon(index: Int) -> some View {
        if index < controller.activeStep {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(theme.success)
        } else if index == controller.activeStep {
            ProgressView()
                .controlSize(.small)
        } else {
            Image(systemName: "circle")
                .foregroundStyle(theme.textSecondary)
        }
    }

    // MARK: Ready (after a check)

    @ViewBuilder
    private var readyCard: some View {
        if controller.upgradeCount == 0 {
            Card {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(theme.success)
                        Text("You're up to date")
                            .font(.cardTitle)
                            .foregroundStyle(theme.textPrimary)
                        Spacer()
                    }
                    checkButton("Check Again")
                }
            }
        } else {
            Card {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    Text(updateCountLabel(controller.upgradeCount) + " available")
                        .font(.cardTitle)
                        .foregroundStyle(theme.textPrimary)

                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        ForEach(Array(controller.previewPackages.enumerated()), id: \.offset) {
                            _, package in
                            Text(package)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(theme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    Button {
                        Haptics.warning()
                        showInstallConfirm = true
                    } label: {
                        Text("Install " + updateCountLabel(controller.upgradeCount))
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Spacing.xs)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(theme.warning)
                    .disabled(controller.isBusy)
                }
            }
        }
    }

    // MARK: Done

    private var doneCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(theme.success)
                    Text("Updated " + packageCountLabel(controller.upgradeCount))
                        .font(.cardTitle)
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                }
                Text("A reboot is often needed after core package upgrades.")
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)

                Button {
                    Haptics.impact(.light)
                    showRebootConfirm = true
                } label: {
                    Label("Reboot Router", systemImage: "arrow.clockwise.circle")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Spacing.xs)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .tint(theme.warning)
                .disabled(appState.isRebooting)

                checkButton("Check Again")
            }
        }
    }

    // MARK: Output log

    @ViewBuilder
    private var outputCard: some View {
        if !controller.log.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    HStack {
                        Text("Output")
                            .font(.cardTitle)
                            .foregroundStyle(theme.textPrimary)
                        Spacer()
                        Button {
                            copyLog()
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .tint(theme.accent)
                        .accessibilityLabel("Copy output")
                    }

                    ScrollView(.horizontal, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(logLines) { line in
                                Text(line.text.isEmpty ? " " : line.text)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(theme.textPrimary)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                        }
                        .textSelection(.enabled)
                    }
                }
            }
        }
    }

    // MARK: Model / helpers

    private struct LogLine: Identifiable {
        let id: Int
        let text: String
    }

    private var logLines: [LogLine] {
        controller.log
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { LogLine(id: $0.offset, text: String($0.element)) }
    }

    private func updateCountLabel(_ count: Int) -> String {
        "\(count) Update" + (count == 1 ? "" : "s")
    }

    private func packageCountLabel(_ count: Int) -> String {
        "\(count) package" + (count == 1 ? "" : "s")
    }

    private func copyLog() {
        UIPasteboard.general.string = controller.log
        Haptics.success()
        appState.showToast("Output copied")
    }
}
