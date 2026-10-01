import Observation
import SwiftUI
import UIKit

// MARK: - Controller

/// Drives the OpenWrt package update flow through LuCI's package-manager
/// wrapper: check support, refresh the index, compare installed against
/// available versions, then upgrade one package at a time so the screen can
/// show live per-package progress. All command output is accumulated into
/// `log` for a terminal-style view.
@MainActor
@Observable
final class SoftwareUpdatesController {
    enum Stage {
        case idle          // connected, no check run yet
        case checking      // refreshing the index + comparing package lists
        case ready         // check finished (see `upgrades`)
        case upgrading     // installing `installItems` one by one, then verifying
        case done          // install pass finished (see `installItems` states)
        case unavailable   // no connection, opkg router, or no permission
    }

    enum InstallState: Equatable {
        case pending
        case installing
        case upgraded
        /// No complete reply (connection dropped or the 60 s CGI limit hit);
        /// resolved by the final version check when it can run.
        case unconfirmed
        /// Never attempted because the run stopped early.
        case skipped
        case failed(String)

        var isFinished: Bool { self != .pending && self != .installing }
    }

    struct InstallItem: Identifiable {
        let upgrade: PackageUpgrade
        var state: InstallState

        var id: String { upgrade.id }
    }

    /// nil = not yet checked.
    private(set) var support: RouterService.PackageManagerSupport?
    private(set) var stage: Stage = .idle
    private(set) var isBusy = false
    private(set) var error: String?

    /// Packages with a newer version available, in install order.
    private(set) var upgrades: [PackageUpgrade] = []
    /// Per-package progress of the current/last install run.
    private(set) var installItems: [InstallItem] = []
    private(set) var currentInstallIndex: Int?
    private(set) var isVerifying = false

    /// Accumulated command output shown in the monospaced Output card.
    private(set) var log = ""

    /// Index of the active check step (0 refresh, 1 download lists, 2 compare);
    /// steps before it render as completed, the step at it spins.
    private(set) var activeStep = 0
    /// Caption describing the current long-running activity.
    private(set) var activity = ""

    var finishedCount: Int { installItems.filter { $0.state.isFinished }.count }
    var upgradedCount: Int { installItems.filter { $0.state == .upgraded }.count }

    var installProgress: Double {
        installItems.isEmpty ? 0 : Double(finishedCount) / Double(installItems.count)
    }

    var currentItem: InstallItem? {
        guard let index = currentInstallIndex, installItems.indices.contains(index) else {
            return nil
        }
        return installItems[index]
    }

    // MARK: Availability

    func checkAvailability(service: RouterService) async {
        let result = await service.packageManagerSupport()
        support = result
        if result != .available { stage = .unavailable }
    }

    /// Marks the feature unavailable (e.g. no active connection).
    func markUnavailable() {
        support = .notPermitted
        stage = .unavailable
    }

    // MARK: Check for updates

    func check(service: RouterService) async {
        guard !isBusy else { return }
        isBusy = true
        error = nil
        upgrades = []
        installItems = []
        stage = .checking
        defer { isBusy = false }

        do {
            activeStep = 0
            activity = "Refreshing package index…"
            appendLog("$ apk update")
            let update = try await service.packageIndexUpdate()
            appendLog(update.combinedOutput)
            guard update.succeeded else {
                error = Self.failureMessage(update, fallback: "apk update failed.")
                stage = .idle
                return
            }

            activeStep = 1
            activity = "Downloading installed and available package lists…"
            appendLog("$ apk query --installed / --available")
            async let installedList = service.installedPackages()
            async let availableList = service.availablePackages()
            let (installed, available) = try await (installedList, availableList)
            appendLog("\(installed.count) installed, \(available.count) available in feeds")

            activeStep = 2
            activity = "Comparing versions…"
            upgrades = PackageCatalog.upgrades(installed: installed, available: available)
            appendLog(
                upgrades.isEmpty
                    ? "Everything is up to date."
                    : upgrades.map { "  \($0.name) \($0.installedVersion) -> \($0.availableVersion)" }
                        .joined(separator: "\n"))
            stage = .ready
        } catch {
            self.error = Self.message(for: error)
            stage = .idle
        }
    }

    // MARK: Perform the upgrade

    /// Upgrades each package in its own call (the wrapper only replies after
    /// apk exits, so per-package calls are what makes progress live), then
    /// re-reads installed versions so every row reports a confirmed result.
    func upgrade(service: RouterService) async {
        guard !isBusy, !upgrades.isEmpty else { return }
        isBusy = true
        error = nil
        stage = .upgrading
        installItems = upgrades.map { InstallItem(upgrade: $0, state: .pending) }
        defer {
            isBusy = false
            currentInstallIndex = nil
            isVerifying = false
        }

        var consecutiveErrors = 0
        var stoppedEarly = false
        for index in installItems.indices {
            // Already upgraded as a dependency of an earlier package.
            guard installItems[index].state == .pending else { continue }
            let package = installItems[index].upgrade
            currentInstallIndex = index
            installItems[index].state = .installing
            activity = "Upgrading \(package.name)…"
            appendLog("$ apk upgrade \(package.name)")
            do {
                let result = try await service.upgradePackage(package.name)
                consecutiveErrors = 0
                appendLog(result.combinedOutput)
                markUpgraded(in: result.stdout)
                if installItems[index].state == .installing {
                    installItems[index].state =
                        result.succeeded
                        ? .upgraded
                        : .failed(Self.firstLine(of: result.combinedOutput)
                            ?? "apk exited with code \(result.code)")
                }
            } catch {
                consecutiveErrors += 1
                installItems[index].state = .unconfirmed
                appendLog("! \(error.localizedDescription)")
                // Two misses in a row: the router is restarting services or
                // unreachable. Stop rather than fail the whole queue.
                if consecutiveErrors >= 2 {
                    stoppedEarly = true
                    break
                }
            }
        }
        currentInstallIndex = nil

        isVerifying = true
        activity = "Confirming installed versions…"
        appendLog("$ apk query --installed")
        var verifyFailure: String?
        do {
            verify(against: try await service.installedPackages())
        } catch {
            verifyFailure = Self.message(for: error)
        }

        for index in installItems.indices where installItems[index].state == .pending {
            installItems[index].state = .skipped
        }

        if stoppedEarly {
            error = "Lost contact with the router partway through, so the rest were skipped. "
                + "Reconnect, then tap Check Again to finish."
        } else if let verifyFailure {
            error = "Couldn't re-read installed versions (\(verifyFailure)). Reconnect, then "
                + "tap Check Again to see where things stand."
        }
        let allUpgraded = upgradedCount == installItems.count
        appendLog("Upgraded \(upgradedCount) of \(installItems.count) packages.")
        stage = .done
        if allUpgraded { Haptics.success() } else { Haptics.warning() }
    }

    // MARK: - Helpers

    /// Marks every package apk reported upgrading (the requested one plus any
    /// dependencies it pulled in) as upgraded.
    private func markUpgraded(in output: String) {
        let upgraded = PackageCatalog.upgradedPackages(in: output)
        for index in installItems.indices where upgraded[installItems[index].upgrade.name] != nil {
            if !installItems[index].state.isFinished || installItems[index].state == .unconfirmed {
                installItems[index].state = .upgraded
            }
        }
    }

    /// Settles every row against what is actually installed now.
    private func verify(against installed: [PackageCatalog.Entry]) {
        var versions: [String: String] = [:]
        for entry in installed where versions[entry.name] == nil {
            versions[entry.name] = entry.version
        }
        for index in installItems.indices {
            let item = installItems[index]
            let now = versions[item.upgrade.name]
            if let now, ApkVersion.compare(now, item.upgrade.availableVersion) != .orderedAscending {
                installItems[index].state = .upgraded
                continue
            }
            switch item.state {
            case .failed, .pending:
                break
            default:
                installItems[index].state = .failed(
                    now.map { "Still at \(PackageCatalog.displayVersion($0))" }
                        ?? "No longer installed")
            }
        }
    }

    private func appendLog(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if log.isEmpty {
            log = trimmed
        } else {
            log += "\n" + trimmed
        }
    }

    private static func firstLine(of text: String) -> String? {
        text.split(separator: "\n").first.map(String.init)
    }

    private static func failureMessage(_ result: RouterService.ExecResult, fallback: String)
        -> String
    {
        let output = result.combinedOutput
        return output.isEmpty ? fallback : output
    }

    private static func message(for error: Error) -> String {
        if let ubusError = error as? UbusError, case .ubusStatus(6, let detail) = ubusError {
            return "The router refused the package command (\(detail ?? "permission denied")). "
                + "This login needs permission to use luci-app-package-manager."
        }
        return error.localizedDescription
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
        screen
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

    private var screen: some View {
        content
            .background(theme.background)
            .foregroundStyle(theme.textPrimary)
            .navigationTitle("Software Updates")
            .navigationBarTitleDisplayMode(.inline)
            // Leaving mid-install would hide progress of a run that keeps going.
            .navigationBarBackButtonHidden(controller.stage == .upgrading)
            .task {
                guard let service = appState.service else {
                    controller.markUnavailable()
                    return
                }
                await controller.checkAvailability(service: service)
            }
            .onChange(of: controller.stage) { _, stage in
                Self.keepScreenAwake(during: stage)
            }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    /// iOS suspends network work once the screen locks; keep it awake while
    /// the router is being changed.
    private static func keepScreenAwake(during stage: SoftwareUpdatesController.Stage) {
        let busy = stage == .upgrading || stage == .checking
        UIApplication.shared.isIdleTimerDisabled = busy
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
        } else if let support = controller.support, support != .available {
            EmptyStateView(
                systemImage: "shippingbox",
                title: "Package Updates Unavailable",
                message: unavailableMessage(support)
            )
            .padding(.top, Spacing.xxl)
        } else if controller.support == nil {
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

    private func unavailableMessage(_ support: RouterService.PackageManagerSupport) -> String {
        switch support {
        case .opkgRouter:
            return "This router uses opkg (OpenWrt 24.10 or older). Package updates in "
                + "Lucinate need an apk-based router (OpenWrt 25.12 or newer)."
        case .notPermitted, .available:
            return "This login can't manage packages. Install luci-app-package-manager on the "
                + "router (LuCI → System → Software) and sign in as root, or grant this user "
                + "its permissions."
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
        case .checking:
            checkProgressCard
        case .ready:
            readyCard
        case .upgrading:
            installProgressCard
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

    // MARK: Check progress (stepper)

    private var checkProgressCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.md) {
                stepRow(index: 0, title: "Refresh package index")
                stepRow(index: 1, title: "Download package lists")
                stepRow(index: 2, title: "Compare versions")
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
        if controller.upgrades.isEmpty {
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
                    Text(updateCountLabel(controller.upgrades.count) + " available")
                        .font(.cardTitle)
                        .foregroundStyle(theme.textPrimary)

                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        ForEach(controller.upgrades) { upgrade in
                            packageRow(upgrade, detail: versionChange(upgrade)) {
                                Image(systemName: "arrow.up.circle")
                                    .foregroundStyle(theme.accent)
                            }
                        }
                    }

                    Button {
                        Haptics.warning()
                        showInstallConfirm = true
                    } label: {
                        Text("Install " + updateCountLabel(controller.upgrades.count))
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

    // MARK: Install progress (live)

    private var installProgressCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack(alignment: .firstTextBaseline) {
                    Text(controller.isVerifying ? "Confirming versions" : "Installing updates")
                        .font(.cardTitle)
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                    Text("\(controller.finishedCount) of \(controller.installItems.count)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(theme.textSecondary)
                        .contentTransition(.numericText())
                }

                ProgressView(value: controller.installProgress)
                    .tint(theme.accent)
                    .animation(.easeInOut(duration: 0.3), value: controller.installProgress)

                currentActivity

                Text(
                    "Keep Lucinate open until this finishes. Packages install one at a time, "
                        + "and the connection can blip when network services restart."
                )
                .font(.caption)
                .foregroundStyle(theme.textSecondary)

                Divider()
                packageChecklist
            }
        }
    }

    @ViewBuilder
    private var currentActivity: some View {
        if let item = controller.currentItem {
            HStack(alignment: .top, spacing: Spacing.sm) {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Upgrading \(item.upgrade.name)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.textPrimary)
                    Text(versionChange(item.upgrade))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(theme.textSecondary)
                }
                Spacer()
                Text(percentLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(theme.textSecondary)
            }
        } else if controller.isVerifying {
            HStack(spacing: Spacing.sm) {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 22, height: 22)
                Text("Re-reading installed versions…")
                    .font(.subheadline)
                    .foregroundStyle(theme.textPrimary)
            }
        }
    }

    private var packageChecklist: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            ForEach(controller.installItems) { item in
                packageRow(item.upgrade, detail: installDetail(item)) {
                    installIcon(item.state)
                }
            }
        }
    }

    @ViewBuilder
    private func installIcon(_ state: SoftwareUpdatesController.InstallState) -> some View {
        switch state {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(theme.textSecondary)
        case .installing:
            ProgressView()
                .controlSize(.small)
        case .upgraded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(theme.success)
        case .unconfirmed:
            Image(systemName: "questionmark.circle")
                .foregroundStyle(theme.warning)
        case .skipped:
            Image(systemName: "minus.circle")
                .foregroundStyle(theme.textSecondary)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(theme.error)
        }
    }

    private func installDetail(_ item: SoftwareUpdatesController.InstallItem) -> String {
        switch item.state {
        case .failed(let reason): return reason
        case .unconfirmed: return "No reply yet — will be confirmed at the end"
        case .skipped: return "Skipped"
        default: return versionChange(item.upgrade)
        }
    }

    private func packageRow<Icon: View>(
        _ upgrade: PackageUpgrade, detail: String, @ViewBuilder icon: () -> Icon
    ) -> some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            icon()
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(upgrade.name)
                    .font(.subheadline)
                    .foregroundStyle(theme.textPrimary)
                Text(detail)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Done

    private var percentLabel: String {
        let percent = Int((controller.installProgress * 100).rounded())
        return "\(percent)%"
    }

    private var doneTitle: String {
        let total = controller.installItems.count
        let upgraded = controller.upgradedCount
        if upgraded == total { return "Updated " + packageCountLabel(total) }
        return "Updated \(upgraded) of " + packageCountLabel(total)
    }

    private var doneCard: some View {
        let allUpgraded = controller.upgradedCount == controller.installItems.count
        let icon = allUpgraded ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
        let iconColor = allUpgraded ? theme.success : theme.warning
        return VStack(spacing: Spacing.md) {
            Card {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: icon)
                            .foregroundStyle(iconColor)
                        Text(doneTitle)
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
                    .disabled(appState.isRebooting || controller.upgradedCount == 0)

                    checkButton("Check Again")
                }
            }
            Card {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    Text("Packages")
                        .font(.cardTitle)
                        .foregroundStyle(theme.textPrimary)
                    packageChecklist
                }
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

    private func versionChange(_ upgrade: PackageUpgrade) -> String {
        PackageCatalog.displayVersion(upgrade.installedVersion) + " → "
            + PackageCatalog.displayVersion(upgrade.availableVersion)
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
