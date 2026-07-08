import SwiftUI

/// Router login form. Feature parity with the Flutter login screen (§5.1):
/// address/username/password fields, certificate warning dialog, and the
/// hidden reviewer-mode long-press easter egg on the brand header.
struct LoginView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL

    // MARK: Form state

    @State private var address = ""
    @State private var username = "root"
    @State private var password = ""
    @State private var isPasswordVisible = false

    // MARK: Reviewer mode easter egg

    @State private var isHoldingBrand = false
    @State private var showReviewerPrompt = false
    @State private var reviewerConfirmation = ""

    // MARK: Certificate warning

    /// Set synchronously by the "Accept Risk" button so the alert's
    /// isPresented setter does not decline the pending login on dismiss.
    @State private var isAcceptingCertificate = false

    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case address
        case username
        case password
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.xl) {
                header

                fieldsCard

                VStack(spacing: Spacing.md) {
                    if let error = appState.loginError {
                        errorBanner(error)
                    }
                    connectButton
                }

                footer
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.top, Spacing.xxl)
            .padding(.bottom, Spacing.lg)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(theme.background.ignoresSafeArea())
        .onChange(of: appState.loginError) { _, newValue in
            if newValue != nil {
                Haptics.error()
            }
        }
        .alert("Certificate Warning", isPresented: certificateAlertPresented) {
            Button("Cancel", role: .cancel) {
                appState.declinePendingCertificate()
            }
            Button("Accept Risk", role: .destructive) {
                isAcceptingCertificate = true
                Task {
                    await appState.acceptPendingCertificate()
                    isAcceptingCertificate = false
                }
            }
        } message: {
            Text(
                "The certificate for \(appState.pendingCertificate ?? "this router") "
                    + "is not trusted. Only continue if you expect a self-signed "
                    + "certificate on this router."
            )
        }
        .alert("Enable Reviewer Mode", isPresented: $showReviewerPrompt) {
            TextField("Type REVIEWER", text: $reviewerConfirmation)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) {
                reviewerConfirmation = ""
            }
            Button("Enable") {
                let typed = reviewerConfirmation.trimmingCharacters(in: .whitespacesAndNewlines)
                reviewerConfirmation = ""
                if typed == "REVIEWER" {
                    Haptics.success()
                    appState.enterReviewerMode()
                }
            }
        } message: {
            Text(
                "This will enable reviewer mode which bypasses authentication and "
                    + "uses mock data. To confirm, type \"REVIEWER\" below:"
            )
        }
    }

    // MARK: - Header (brand mark + reviewer-mode long press)

    private var header: some View {
        VStack(spacing: Spacing.md) {
            BrandMark(size: 72)

            Text("Lucinate")
                .font(.system(.title, design: .rounded).weight(.bold))
                .foregroundStyle(theme.textPrimary)

            Text("Sign in to your OpenWrt router")
                .font(.subheadline)
                .foregroundStyle(theme.textSecondary)

            if isHoldingBrand {
                Text("Hold to activate reviewer mode...")
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(.rect)
        .onLongPressGesture(minimumDuration: 5) {
            Haptics.success()
            showReviewerPrompt = true
        } onPressingChanged: { pressing in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHoldingBrand = pressing
            }
        }
    }

    // MARK: - Fields

    private var fieldsCard: some View {
        Card(padding: Spacing.lg) {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    fieldLabel("Router Address")
                    TextField("Router Address", text: $address, prompt: Text("192.168.1.1"))
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focusedField, equals: .address)
                        .onSubmit { focusedField = .username }
                        .foregroundStyle(theme.textPrimary)
                    Text("e.g. 192.168.1.1, router.local:8080, https://192.168.1.1")
                        .font(.caption)
                        .foregroundStyle(theme.textSecondary)
                }

                Divider().overlay(theme.separator)

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    fieldLabel("Username")
                    TextField("Username", text: $username, prompt: Text("root"))
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focusedField, equals: .username)
                        .onSubmit { focusedField = .password }
                        .foregroundStyle(theme.textPrimary)
                }

                Divider().overlay(theme.separator)

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    fieldLabel("Password")
                    HStack(spacing: Spacing.sm) {
                        Group {
                            if isPasswordVisible {
                                TextField("Password", text: $password)
                            } else {
                                SecureField("Password", text: $password)
                            }
                        }
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .focused($focusedField, equals: .password)
                        .onSubmit(submit)
                        .foregroundStyle(theme.textPrimary)

                        Button {
                            isPasswordVisible.toggle()
                            Haptics.selection()
                        } label: {
                            Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
                                .foregroundStyle(theme.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isPasswordVisible ? "Hide password" : "Show password")
                    }
                }
            }
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.footnote.weight(.medium))
            .foregroundStyle(theme.textSecondary)
    }

    // MARK: - Error banner

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: "exclamationmark.triangle")
            Text(message)
        }
        .font(.subheadline)
        .foregroundStyle(theme.error)
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            theme.error.opacity(0.15),
            in: .rect(cornerRadius: CornerRadius.small, style: .continuous)
        )
    }

    // MARK: - Connect button

    private var connectButton: some View {
        Button(action: submit) {
            Group {
                if appState.isLoggingIn {
                    ProgressView()
                } else {
                    Text("Connect")
                        .fontWeight(.semibold)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.xs)
        }
        .buttonStyle(.glassProminent)
        .tint(theme.accent)
        .controlSize(.large)
        .disabled(!canSubmit)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: Spacing.sm) {
            Button {
                if let url = URL(string: "https://github.com/nphil/lucinate/issues") {
                    openURL(url)
                }
            } label: {
                Text("Need help?")
                    .font(.subheadline)
                    .foregroundStyle(theme.accent)
            }
            .buttonStyle(.plain)

            Text("v\(appVersion)")
                .font(.caption)
                .foregroundStyle(theme.textSecondary)
        }
        .padding(.top, Spacing.md)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    // MARK: - Submission

    private var trimmedAddress: String {
        address.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        !appState.isLoggingIn && !trimmedAddress.isEmpty && !username.isEmpty
    }

    private func submit() {
        guard canSubmit else { return }
        focusedField = nil
        Haptics.impact(.light)
        let address = trimmedAddress
        let username = username
        let password = password
        Task {
            await appState.login(address: address, username: username, password: password)
        }
    }

    // MARK: - Certificate warning binding

    private var certificateAlertPresented: Binding<Bool> {
        Binding(
            get: { appState.pendingCertificate != nil },
            set: { isPresented in
                if !isPresented, !isAcceptingCertificate, appState.pendingCertificate != nil {
                    appState.declinePendingCertificate()
                }
            }
        )
    }
}

#Preview {
    LoginView()
        .environment(AppState())
}
