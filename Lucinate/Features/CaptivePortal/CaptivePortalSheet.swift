import Network
import Observation
import SwiftUI
import UIKit
import WebKit

/// The hotel's sign-in page, inside the app.
///
/// The page is loaded through a loopback proxy (`WiFiPinnedProxy`) so every connection it makes
/// goes out over Wi-Fi; while iOS considers that Wi-Fi captive it is not the default route, and a
/// plain web view would reach the real internet over cellular instead. The sheet watches the same
/// Wi-Fi-pinned probe the monitor uses and closes itself once the internet works.
struct CaptivePortalSheet: View {
    @Environment(CaptivePortalMonitor.self) private var monitor
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var session = SignInSession()
    @State private var wasInBackground = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusStrip
                if session.routing == .direct {
                    directCaption
                }
                webArea
            }
            .background(theme.background)
            .navigationTitle("Hotel Wi-Fi sign-in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Haptics.impact(.light)
                        session.reload()
                    } label: {
                        if session.isLoading {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(session.routing == .starting)
                    .accessibilityLabel("Reload")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await session.startRouting() }
        .task { await watchForInternet() }
        .onChange(of: scenePhase) { _, phase in handle(phase) }
        .onDisappear { session.stop() }
    }

    // MARK: - Status

    private var statusStrip: some View {
        HStack(spacing: Spacing.sm) {
            if session.connection == .checking {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: statusSymbol)
                    .foregroundStyle(statusTint)
            }
            Text(statusText)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(theme.textPrimary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(statusTint.opacity(0.15))
        .accessibilityElement(children: .combine)
        .animation(.smooth, value: session.connection)
    }

    private var statusText: String {
        switch session.connection {
        case .checking: "Checking your connection…"
        case .needsSignIn: "Not online yet. Finish signing in below."
        case .unreachable: "Can't reach the internet yet. Checking again…"
        case .online: "You're online"
        }
    }

    private var statusSymbol: String {
        switch session.connection {
        case .checking, .needsSignIn: "wifi.exclamationmark"
        case .unreachable: "wifi.slash"
        case .online: "checkmark.circle.fill"
        }
    }

    private var statusTint: Color {
        switch session.connection {
        case .checking, .unreachable: theme.textSecondary
        case .needsSignIn: theme.warning
        case .online: theme.success
        }
    }

    private var directCaption: some View {
        Text("Wi-Fi-only routing isn't available, so this page loads the normal way.")
            .font(.caption)
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Page

    @ViewBuilder
    private var webArea: some View {
        if session.routing == .starting {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            PortalWebView(session: session)
                .overlay {
                    if session.loadFailed {
                        ErrorStateView(
                            message: "Couldn't load the sign-in page. Make sure the router is "
                                + "connected to the hotel Wi-Fi, then try again."
                        ) {
                            session.reload()
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(theme.background)
                    }
                }
                .ignoresSafeArea(.container, edges: .bottom)
        }
    }

    // MARK: - Lifecycle

    /// Closes the sheet shortly after the probe sees the internet, then has the monitor re-read
    /// the router. The banner is cleared first so it never lingers behind the closing sheet.
    private func watchForInternet() async {
        guard await session.waitUntilOnline() else { return }
        Haptics.success()
        monitor.confirmOnline()
        try? await Task.sleep(for: .seconds(1.5))
        dismiss()
        monitor.refreshNow()
    }

    /// iOS takes listening sockets away while the app is suspended, so after a real trip to the
    /// background (not just Control Center) the proxy is replaced instead of trusted.
    private func handle(_ phase: ScenePhase) {
        switch phase {
        case .background:
            wasInBackground = true
        case .active:
            guard wasInBackground else { return }
            wasInBackground = false
            Task { await session.restartRouting() }
        default:
            break
        }
    }
}

// MARK: - Model

@MainActor
@Observable
private final class SignInSession {
    enum Routing {
        /// Proxy still binding; the page waits for it so no request can slip out unpinned.
        case starting
        case pinned
        /// The proxy could not start; the page loads without it.
        case direct
    }

    enum Connection { case checking, needsSignIn, unreachable, online }

    private(set) var routing = Routing.starting
    private(set) var connection = Connection.checking
    private(set) var isLoading = false
    private(set) var loadFailed = false

    /// Non-persistent, so nothing the portal stores outlives the sheet.
    let dataStore = WKWebsiteDataStore.nonPersistent()

    @ObservationIgnored private var proxy = WiFiPinnedProxy()
    @ObservationIgnored private weak var webView: WKWebView?
    @ObservationIgnored private var isStopped = false

    /// `captive.apple.com` makes the portal redirect to its own sign-in page, with whatever
    /// parameters it wants carried along.
    private static var startRequest: URLRequest {
        URLRequest(
            url: WiFiPinnedProbe.url, cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30)
    }

    // MARK: Routing

    func startRouting() async {
        guard routing == .starting else { return }
        await configureProxy()
    }

    func restartRouting() async {
        guard routing == .pinned, !isStopped else { return }
        proxy.stop()
        proxy = WiFiPinnedProxy()
        await configureProxy()
        if routing == .pinned { reload() }
    }

    private func configureProxy() async {
        do {
            let port = try await proxy.start()
            var configuration = ProxyConfiguration(
                httpCONNECTProxy: NWEndpoint.hostPort(host: .ipv4(.loopback), port: port))
            // A dead proxy must fail the page, never send it out over cellular.
            configuration.allowFailover = false
            dataStore.proxyConfigurations = [configuration]
            routing = .pinned
        } catch {
            dataStore.proxyConfigurations = []
            routing = .direct
        }
    }

    // MARK: Connection check

    /// Probes every 3 s. Returns true once the internet works, false if cancelled first.
    func waitUntilOnline() async -> Bool {
        while !Task.isCancelled {
            let outcome = await WiFiPinnedProbe.run()
            if Task.isCancelled { return false }
            switch outcome {
            case .online:
                connection = .online
                return true
            case .captive:
                connection = .needsSignIn
            case .unreachable:
                connection = .unreachable
            }
            try? await Task.sleep(for: .seconds(3))
        }
        return false
    }

    // MARK: Page

    func attach(_ webView: WKWebView) {
        self.webView = webView
        webView.load(Self.startRequest)
    }

    func reload() {
        guard let webView else { return }
        loadFailed = false
        // A first load that never got anywhere has nothing to reload.
        if webView.url == nil {
            webView.load(Self.startRequest)
        } else {
            webView.reload()
        }
    }

    func navigationStarted() {
        isLoading = true
        loadFailed = false
    }

    func navigationFinished() {
        isLoading = webView?.isLoading ?? false
    }

    func navigationFailed(_ error: Error) {
        isLoading = webView?.isLoading ?? false
        let nsError = error as NSError
        // A redirect or a replaced load reports "cancelled" while the next load carries on, and
        // WebKit reports 102 when a policy decision interrupts a frame load.
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 { return }
        loadFailed = true
    }

    func stop() {
        isStopped = true
        proxy.stop()
        webView?.stopLoading()
    }
}

// MARK: - Web view

private struct PortalWebView: UIViewRepresentable {
    let session: SignInSession

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = session.dataStore
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        session.attach(webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.cancelDialog()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let session: SignInSession
        /// The JavaScript dialog on screen, if any. WebKit insists that every dialog is answered,
        /// so a sheet that closes underneath one answers it.
        private var openDialog: (alert: UIAlertController, answer: DialogAnswer)?

        init(session: SignInSession) {
            self.session = session
            super.init()
        }

        // MARK: Navigation

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            session.navigationStarted()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            session.navigationFinished()
        }

        func webView(
            _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error
        ) {
            session.navigationFailed(error)
        }

        func webView(
            _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: any Error
        ) {
            session.navigationFailed(error)
        }

        // MARK: Windows and dialogs

        /// `target="_blank"` and `window.open` stay in this view; a sign-in flow has no use for a
        /// second window.
        func webView(
            _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }

        // A web view silently ignores `alert()` and answers `confirm()` with "cancel" unless the
        // app shows them, and portals use both for terms and error messages.

        func webView(
            _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo
        ) async {
            _ = await ask(message, frame: frame, in: webView, showsCancel: false)
        }

        func webView(
            _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo
        ) async -> Bool {
            await ask(message, frame: frame, in: webView, showsCancel: true)
        }

        private func ask(
            _ message: String, frame: WKFrameInfo, in webView: WKWebView, showsCancel: Bool
        ) async -> Bool {
            guard openDialog == nil, let presenter = topController(above: webView),
                presenter.view.window != nil, !presenter.isBeingDismissed,
                !presenter.isBeingPresented
            else { return false }
            let result = await withCheckedContinuation {
                (continuation: CheckedContinuation<Bool, Never>) in
                let answer = DialogAnswer(continuation)
                let alert = UIAlertController(
                    title: frame.request.url?.host, message: message, preferredStyle: .alert)
                if showsCancel {
                    alert.addAction(
                        UIAlertAction(title: "Cancel", style: .cancel) { _ in answer.resolve(false) })
                }
                alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in answer.resolve(true) })
                openDialog = (alert, answer)
                presenter.present(alert, animated: true)
            }
            openDialog = nil
            return result
        }

        func cancelDialog() {
            guard let dialog = openDialog else { return }
            openDialog = nil
            dialog.alert.dismiss(animated: false)
            dialog.answer.resolve(false)
        }

        private func topController(above view: UIView) -> UIViewController? {
            var responder: UIResponder? = view
            while let current = responder, !(current is UIViewController) {
                responder = current.next
            }
            guard var controller = responder as? UIViewController else { return nil }
            while let presented = controller.presentedViewController {
                controller = presented
            }
            return controller
        }
    }
}

/// Holds the continuation of one JavaScript dialog so it is resumed exactly once, whether the
/// user answers or the sheet closes first.
@MainActor
private final class DialogAnswer {
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resolve(_ value: Bool) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}
