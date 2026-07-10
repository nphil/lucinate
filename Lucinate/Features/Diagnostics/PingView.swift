import Observation
import SwiftUI

// MARK: - Output parsing

/// Best-effort parsing of BusyBox/iputils ping output. Every helper returns
/// nil when the format is unrecognized — callers must tolerate that.
enum PingOutputParser {
    /// Average latency from the "round-trip min/avg/max = a/b/c ms" line.
    static func averageMs(from stdout: String) -> Double? {
        for line in stdout.split(separator: "\n") {
            guard line.contains("min/avg/max"),
                let equals = line.range(of: "=")
            else { continue }
            let tail = line[equals.upperBound...]
                .replacingOccurrences(of: "ms", with: "")
                .trimmingCharacters(in: .whitespaces)
            let parts = tail.split(separator: "/")
            guard parts.count >= 2 else { continue }
            if let avg = Double(parts[1].trimmingCharacters(in: .whitespaces)) {
                return avg
            }
        }
        return nil
    }

    /// Reply count from the "N packets transmitted, M packets received, …" line.
    static func receivedCount(from stdout: String) -> Int? {
        for line in stdout.split(separator: "\n") where line.contains("received") {
            for segment in line.split(separator: ",") where segment.contains("received") {
                let tokens = segment.split(separator: " ")
                if let first = tokens.first, let value = Int(first) {
                    return value
                }
            }
        }
        return nil
    }
}

// MARK: - Controller

/// Runs `ping -c 4 -W 2 <host>` on the router via `file exec` (argument
/// array — never shell string interpolation) and keeps the last output.
@MainActor
@Observable
final class PingController {
    static let packetCount = 4

    enum Summary: Equatable {
        case success(replies: Int, total: Int, avgMs: Double?)
        case unreachable
    }

    private(set) var isRunning = false
    private(set) var output: String?
    private(set) var summary: Summary?
    private(set) var error: String?

    func ping(host: String, service: RouterService) async {
        isRunning = true
        defer { isRunning = false }
        error = nil
        do {
            let result = try await service.fileExec(
                command: "/bin/ping",
                params: ["-c", "\(Self.packetCount)", "-W", "2", host]
            )
            let stdout = result["stdout"].stringValue ?? ""
            let code = result["code"].intValue ?? 1
            if !stdout.isEmpty {
                output = stdout
            }
            if code == 0 {
                let replies = PingOutputParser.receivedCount(from: stdout) ?? Self.packetCount
                summary = .success(
                    replies: replies,
                    total: Self.packetCount,
                    avgMs: PingOutputParser.averageMs(from: stdout)
                )
                Haptics.success()
            } else {
                summary = .unreachable
                Haptics.error()
            }
        } catch {
            self.error = error.localizedDescription
            summary = nil
            Haptics.error()
        }
    }
}

// MARK: - View

/// Ping tool: host input, run button, parsed summary chip, and the raw
/// output in a monospaced scrollable block. The last output is kept on
/// screen until the next run.
struct PingView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    @State private var controller = PingController()
    @State private var host = "1.1.1.1"

    private static let allowedHostCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.:-")

    var body: some View {
        Group {
            if appState.service == nil {
                EmptyStateView(
                    systemImage: "wifi.slash",
                    title: "Not connected",
                    message: "Connect to a router to run ping."
                )
                .padding(.top, Spacing.xxl)
            } else {
                ScrollView {
                    VStack(spacing: Spacing.sm) {
                        inputCard
                        summaryRow
                        outputCard
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.top, Spacing.sm)
                    .padding(.bottom, Spacing.lg)
                }
            }
        }
        .background(theme.background)
        .navigationTitle("Ping")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Input

    private var inputCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                TextField("Host or IP", text: $host)
                    .font(.monospacedBody)
                    .foregroundStyle(theme.textPrimary)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(Spacing.sm)
                    .background(
                        theme.background,
                        in: .rect(cornerRadius: CornerRadius.small, style: .continuous)
                    )

                if !trimmedHost.isEmpty && !hostIsValid {
                    Text("Only letters, digits, dots, colons, and hyphens are allowed.")
                        .font(.caption)
                        .foregroundStyle(theme.error)
                }

                Button {
                    Haptics.impact(.light)
                    Task { await runPing() }
                } label: {
                    if controller.isRunning {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Spacing.xs)
                    } else {
                        Text("Ping")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Spacing.xs)
                    }
                }
                .buttonStyle(.glassProminent)
                .tint(theme.accent)
                .disabled(controller.isRunning || !hostIsValid)
            }
        }
    }

    private var trimmedHost: String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hostIsValid: Bool {
        !trimmedHost.isEmpty
            && trimmedHost.unicodeScalars.allSatisfy {
                Self.allowedHostCharacters.contains($0)
            }
    }

    // MARK: Summary

    @ViewBuilder
    private var summaryRow: some View {
        switch controller.summary {
        case .success(let replies, let total, let avgMs):
            summaryChip(
                icon: "checkmark.circle.fill",
                text: summaryText(replies: replies, total: total, avgMs: avgMs),
                tint: theme.success
            )
        case .unreachable:
            summaryChip(
                icon: "xmark.circle.fill",
                text: "Host unreachable",
                tint: theme.error
            )
        case nil:
            if let error = controller.error {
                summaryChip(
                    icon: "exclamationmark.triangle.fill",
                    text: error,
                    tint: theme.error
                )
            }
        }
    }

    private func summaryText(replies: Int, total: Int, avgMs: Double?) -> String {
        var text = "\(replies)/\(total) replies"
        if let avgMs {
            text += String(format: " • avg %.1f ms", avgMs)
        }
        return text
    }

    private func summaryChip(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: icon)
            Text(text)
                .font(.subheadline.weight(.medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.xs)
        .background(
            tint.opacity(0.12),
            in: .capsule
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Output

    @ViewBuilder
    private var outputCard: some View {
        if let output = controller.output {
            Card {
                ScrollView {
                    Text(output)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(theme.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 360)
            }
        }
    }

    // MARK: Actions

    private func runPing() async {
        guard let service = appState.service else {
            appState.showToast("Not connected to a router")
            return
        }
        guard hostIsValid else { return }
        await controller.ping(host: trimmedHost, service: service)
    }
}
