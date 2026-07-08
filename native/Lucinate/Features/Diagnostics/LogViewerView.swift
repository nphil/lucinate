import Observation
import SwiftUI
import UIKit

// MARK: - Controller

/// Fetches a router log (logread or dmesg) via `file exec` and exposes it as
/// numbered lines. Falls back to an alternate binary path if the primary one
/// fails (path differs across OpenWrt releases).
@MainActor
@Observable
final class LogViewerController {
    struct Line: Identifiable, Equatable {
        let id: Int
        let text: String
    }

    private(set) var lines: [Line] = []
    /// True only while loading with nothing cached (cached-first UX).
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var hasLoaded = false

    func load(kind: LogViewerView.Kind, service: RouterService?) async {
        guard let service else {
            lines = []
            error = nil
            hasLoaded = true
            return
        }
        if lines.isEmpty { isLoading = true }
        defer { isLoading = false }
        do {
            let stdout = try await fetchOutput(kind: kind, service: service)
            lines = stdout
                .split(separator: "\n", omittingEmptySubsequences: true)
                .enumerated()
                .map { Line(id: $0.offset, text: String($0.element)) }
            error = nil
        } catch {
            if lines.isEmpty {
                self.error = error.localizedDescription
            }
        }
        hasLoaded = true
    }

    /// Tries the primary binary path; on a thrown error, tries the alternate
    /// path once before giving up.
    private func fetchOutput(kind: LogViewerView.Kind, service: RouterService) async throws
        -> String
    {
        do {
            let result = try await service.fileExec(
                command: kind.primaryCommand, params: kind.params)
            return result["stdout"].stringValue ?? ""
        } catch {
            let result = try await service.fileExec(
                command: kind.fallbackCommand, params: kind.params)
            return result["stdout"].stringValue ?? ""
        }
    }
}

// MARK: - View

/// Read-only log viewer for the system (logread) or kernel (dmesg) log.
/// Newest entries are last; the view auto-scrolls to the bottom on load.
struct LogViewerView: View {
    enum Kind {
        case system
        case kernel

        var title: String {
            switch self {
            case .system: return "System Log"
            case .kernel: return "Kernel Log"
            }
        }

        var primaryCommand: String {
            switch self {
            case .system: return "/sbin/logread"
            case .kernel: return "/bin/dmesg"
            }
        }

        var fallbackCommand: String {
            switch self {
            case .system: return "/usr/sbin/logread"
            case .kernel: return "/usr/bin/dmesg"
            }
        }

        var params: [String] {
            switch self {
            case .system: return ["-l", "300"]
            case .kernel: return []
            }
        }
    }

    let kind: Kind

    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    @State private var controller = LogViewerController()
    @State private var searchText = ""

    var body: some View {
        content
            .background(theme.background)
            .navigationTitle(kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Filter log lines")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        copyAll()
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .accessibilityLabel("Copy log")
                    .disabled(controller.lines.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.impact(.light)
                        Task { await reload() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh")
                    .disabled(controller.isLoading)
                }
            }
            .task { await reload() }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if appState.service == nil {
            EmptyStateView(
                systemImage: "wifi.slash",
                title: "Not connected",
                message: "Connect to a router to view its logs."
            )
            .padding(.top, Spacing.xxl)
        } else if controller.isLoading && controller.lines.isEmpty {
            ScrollView {
                VStack(spacing: Spacing.sm) {
                    ForEach(0..<10, id: \.self) { _ in
                        SkeletonBlock(height: 14, cornerRadius: 4)
                    }
                }
                .padding(.horizontal, Spacing.md)
                .padding(.top, Spacing.md)
            }
        } else if let error = controller.error, controller.lines.isEmpty {
            ScrollView {
                ErrorStateView(message: error) {
                    Task { await reload() }
                }
                .padding(.top, Spacing.xxl)
            }
            .refreshable { await reload() }
        } else if controller.hasLoaded && controller.lines.isEmpty {
            ScrollView {
                EmptyStateView(
                    systemImage: "doc.text",
                    title: "No log output"
                )
                .padding(.top, Spacing.xxl)
            }
            .refreshable { await reload() }
        } else {
            logList
        }
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(filteredLines) { line in
                        Text(line.text)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(theme.textPrimary)
                            .lineSpacing(0)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .textSelection(.enabled)
            }
            .refreshable {
                Haptics.impact(.medium)
                await reload()
            }
            .onChange(of: controller.lines) { _, newLines in
                scrollToBottom(proxy: proxy, lines: newLines)
            }
            .onAppear {
                scrollToBottom(proxy: proxy, lines: controller.lines)
            }
        }
    }

    private var filteredLines: [LogViewerController.Line] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return controller.lines }
        return controller.lines.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    // MARK: Actions

    private func reload() async {
        await controller.load(kind: kind, service: appState.service)
    }

    private func scrollToBottom(proxy: ScrollViewProxy, lines: [LogViewerController.Line]) {
        // Only auto-scroll the unfiltered view; a filtered list may not
        // contain the last line's id.
        guard searchText.isEmpty, let last = lines.last else { return }
        proxy.scrollTo(last.id, anchor: .bottom)
    }

    private func copyAll() {
        guard !controller.lines.isEmpty else { return }
        UIPasteboard.general.string = controller.lines.map(\.text).joined(separator: "\n")
        Haptics.success()
        appState.showToast("Log copied")
    }
}
