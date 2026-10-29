import SwiftUI

/// F-06: the optional signed-in session that reveals and passkey changes need,
/// because the server refuses step-up for API tokens.
struct SessionForRevealsScreen: View {
    @Environment(SessionStore.self) private var session
    @Environment(StepUpCoordinator.self) private var stepUp
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale
    @State private var confirmingSignOut = false

    var body: some View {
        @Bindable var session = session
        List {
            Section {
                Text("Revealing a secret (a knock sequence, a share URL, a provider console link) needs a signed-in session and your authenticator code. The server refuses step-up for API tokens.")
                    .foregroundStyle(.secondary)
            }
            Section("State") {
                if session.sessionExpired {
                    Label("Session expired. Sign in again for reveals.", systemImage: "clock.badge.exclamationmark")
                        .foregroundStyle(Color.statusWarnText)
                } else if let identity = session.sessionIdentity {
                    Label(stateText(identity), systemImage: "person.badge.shield.checkmark")
                } else if session.revealClient != nil {
                    Label("Signed in", systemImage: "person.badge.shield.checkmark")
                } else {
                    Label("Not signed in", systemImage: "person.badge.clock")
                        .foregroundStyle(.secondary)
                }
            }
            if session.revealClient == nil || session.sessionExpired {
                Section("Sign in for reveals") {
                    SessionSignInForm {}
                }
            }
            Section {
                Toggle("Keep the session on this iPhone", isOn: $session.keepSession)
                Toggle("End session after each reveal", isOn: $session.endSessionAfterReveal)
            } footer: {
                Text("A kept session is stored behind Face ID and never read in the background. Ending the session after each reveal signs it out on the server when the reveal closes.")
            }
            if session.revealClient != nil, session.credentialKind == .token {
                Section {
                    Button("Sign out of the session", role: .destructive) { confirmingSignOut = true }
                }
            }
        }
        .navigationTitle("Session for reveals")
        .confirmationDialog("Sign out of the session?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
            Button("Sign out of the session", role: .destructive) {
                stepUp.reset()
                Task { await session.endRevealSession() }
            }
        } message: {
            Text("Reveals will need you to sign in again. The API token stays on this iPhone.")
        }
    }

    private func stateText(_ identity: LatticeIdentity) -> String {
        if let expires = session.revealSession?.expiresAt {
            return "Signed in as \(identity.displayName) until \(TimeDisplay.dateTime(expires, mode: mode, locale: locale))"
        }
        return "Signed in as \(identity.displayName)"
    }
}

/// Username, password and authenticator code against `/api/login` and
/// `/api/login/totp`. Used here, in RevealFlow and in WelcomeFlow.
struct SessionSignInForm: View {
    /// Called after the session is adopted.
    let onSignedIn: () -> Void
    var server: URL?

    @Environment(SessionStore.self) private var session
    @State private var username = ""
    @State private var password = ""
    @State private var challengeID: String?
    @State private var code = ""
    @State private var recoveryCode = ""
    @State private var usingRecovery = false
    @State private var working = false
    @State private var message: String?

    var body: some View {
        Group {
            if challengeID == nil {
                TextField("Username", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                    .textContentType(.password)
                Button {
                    Task { await signIn() }
                } label: {
                    HStack {
                        Text("Sign in")
                        if working { Spacer(); ProgressView() }
                    }
                }
                .disabled(username.isEmpty || password.isEmpty || working)
            } else if usingRecovery {
                TextField("Recovery code", text: $recoveryCode)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(TextRole.identifierInDetail.font)
                Button("Continue") { Task { await submitCode() } }
                    .disabled(recoveryCode.isEmpty || working)
                Button("Use an authenticator code") { usingRecovery = false }
            } else {
                TextField("6-digit code", text: $code)
                    .textContentType(.oneTimeCode)
                    .keyboardType(.numberPad)
                    .font(.title3.monospacedDigit())
                    .onChange(of: code) { _, new in
                        let digits = String(new.filter(\.isNumber).prefix(6))
                        if digits != new { code = digits }
                        if digits.count == 6 { Task { await submitCode() } }
                    }
                Button("Use a recovery code") { usingRecovery = true }
            }
            if let message {
                Text(message).foregroundStyle(Color.statusFailText)
            }
        }
        .announcing(message)
    }

    private func signIn() async {
        working = true
        message = nil
        defer { working = false }
        do {
            switch try await session.beginPasswordSignIn(server: server, username: username, password: password) {
            case .signedIn(let login):
                try await session.adopt(login, server: server)
                password = ""
                onSignedIn()
            case .needsTOTP(let id):
                challengeID = id
                message = nil
            }
        } catch {
            message = Self.describe(LatticeAPIError(error))
        }
    }

    private func submitCode() async {
        guard let challengeID, !working else { return }
        working = true
        message = nil
        defer { working = false }
        do {
            let login = try await session.completeTOTP(server: server, challengeID: challengeID, code: usingRecovery ? "" : code, recoveryCode: usingRecovery ? recoveryCode : "")
            try await session.adopt(login, server: server)
            password = ""
            onSignedIn()
        } catch {
            code = ""
            message = Self.describe(LatticeAPIError(error))
        }
    }

    /// The explicit states of F-06.
    static func describe(_ error: LatticeAPIError) -> String {
        switch error {
        case .forbidden(let code, _) where code == "mfa_required":
            return "Two-factor enrollment is required. Enroll on the web first."
        case .forbidden(_, let message) where message.isEmpty:
            return "This account has no authenticator code. Set one up on the web first."
        case .unauthorized:
            return "Wrong username, password or code."
        default:
            return error.localizedDescription
        }
    }
}
