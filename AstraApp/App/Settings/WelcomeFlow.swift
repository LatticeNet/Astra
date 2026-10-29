import SwiftUI
import UIKit

/// F-02: first run (section 7.1). A full-screen cover with its own stack and
/// no permission prompts. Each step's primary action is a bottom-bar button.
struct WelcomeFlow: View {
    @State private var path: [WelcomeStep] = []

    var body: some View {
        NavigationStack(path: $path) {
            WelcomeStepView(path: $path)
                .navigationDestination(for: WelcomeStep.self) { step in
                    switch step {
                    case .server:
                        ServerStepView(path: $path)
                    case .credential(let server, let build):
                        CredentialStepView(server: server, build: build, path: $path)
                    case .scopes(let server):
                        ScopeStepView(server: server)
                    }
                }
        }
        .interactiveDismissDisabled()
    }
}

enum WelcomeStep: Hashable {
    case server
    case credential(server: URL, build: String)
    case scopes(server: URL)
}

// MARK: Welcome

private struct WelcomeStepView: View {
    @Binding var path: [WelcomeStep]
    @Environment(SessionStore.self) private var session
    @Environment(AppState.self) private var appState
    @ScaledMetric(relativeTo: .largeTitle) private var markSize: CGFloat = 52

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                    .font(.system(size: markSize))
                    .foregroundStyle(Color.accentText)
                    .accessibilityHidden(true)
                    .padding(.bottom, Spacing.s)
                Text("Lattice")
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                Text("The phone for your Lattice control plane: triage, decide, investigate.")
                    .font(.title3)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Every approval is hashed on this iPhone before you decide, and Face ID confirms it. Nothing is sent when you cancel.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Explore with demo data") {
                    session.enterDemo(scenario: .normal)
                    appState.welcomePresented = false
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .padding(.top, Spacing.s)
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(.horizontal, Spacing.xl)
            .padding(.top, Spacing.xxl * 2)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                Button("Connect to a server") { path.append(.server) }
                    .prominentAction()
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

// MARK: Server

private struct ServerStepView: View {
    @Binding var path: [WelcomeStep]
    @Environment(SessionStore.self) private var session
    @AppStorage("session.serverURL") private var lastServer = ""
    @State private var address = ""
    @State private var working = false
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                TextField("lattice.example.net", text: $address)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.continue)
                    .onSubmit { Task { await probe() } }
            } header: {
                Text("Server address")
            } footer: {
                if let message {
                    Text(message).foregroundStyle(Color.statusFailText)
                } else {
                    Text("The address you use for the Lattice console. HTTPS is assumed when you leave out the scheme.")
                }
            }
        }
        .navigationTitle("Server")
        .announcing(message)
        .onAppear { if address.isEmpty { address = lastServer } }
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                Button {
                    Task { await probe() }
                } label: {
                    HStack(spacing: Spacing.s) {
                        if working { ProgressView() }
                        Text("Continue")
                    }
                }
                .prominentAction()
                .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || working)
            }
        }
    }

    private func probe() async {
        working = true
        message = nil
        defer { working = false }
        do {
            let (url, version) = try await session.probeServer(address)
            message = nil
            path.append(.credential(server: url, build: version.version.isEmpty ? version.shortCommit : version.version))
        } catch {
            message = Self.describe(LatticeAPIError(error), address: address)
        }
    }

    static func describe(_ error: LatticeAPIError, address: String) -> String {
        switch error {
        case .invalidURL where address.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("http://"):
            return "Plain http is allowed only for a server on your local network, because the token would travel unencrypted. Use https."
        case .invalidURL:
            return "Enter a server address like lattice.example.net."
        case .transport(let code):
            switch code {
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
                return "The TLS connection to \(address) failed. Check the certificate."
            default:
                return "Cannot reach \(address)."
            }
        case .notFound, .invalidResponse:
            return "\(address) answered, but it does not look like a Lattice server."
        default:
            return error.localizedDescription
        }
    }
}

// MARK: Credential

private struct CredentialStepView: View {
    let server: URL
    let build: String
    @Binding var path: [WelcomeStep]

    enum Method: Hashable { case token, password }

    @Environment(SessionStore.self) private var session
    @State private var method: Method = .token
    @State private var token = ""
    @State private var working = false
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Server", value: server.host() ?? server.absoluteString)
                LabeledContent("Build", value: build.isEmpty ? "unknown" : build)
            } footer: {
                if server.scheme?.lowercased() == "http" {
                    Label("This connection is not encrypted. Anyone on this network can read the credential. Use it only on a network you trust.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.statusWarnText)
                }
            }
            Section {
                Picker("Credential", selection: $method) {
                    Text("API token").tag(Method.token)
                    Text("Password").tag(Method.password)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            switch method {
            case .token: tokenSections
            case .password: passwordSection
            }
        }
        .navigationTitle("Credential")
        .announcing(message)
        .toolbar {
            if method == .token {
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        Task { await connect() }
                    } label: {
                        HStack(spacing: Spacing.s) {
                            if working { ProgressView() }
                            Text("Connect")
                        }
                    }
                    .prominentAction()
                    .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working)
                }
            }
        }
    }

    @ViewBuilder
    private var tokenSections: some View {
        Section {
            PasteButton(payloadType: String.self) { strings in
                if let first = strings.first { token = first.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            .buttonBorderShape(.capsule)
            SecureField("API token", text: $token)
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(TextRole.identifierInDetail.font)
        } header: {
            Text("API token (recommended)")
        } footer: {
            VStack(alignment: .leading, spacing: Spacing.s) {
                if let message {
                    Text(message).foregroundStyle(Color.statusFailText)
                }
                Text("Create a token in the console under Settings > Access > Tokens.")
            }
        }
        Section {
            Button("Open token page", systemImage: "safari") {
                UIApplication.shared.open(LatticeConsolePath.tokens.url(console: server))
            }
            DisclosureGroup("Suggested scopes") {
                ForEach(TokenPresets.all) { preset in
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        HStack {
                            Text(preset.title).font(.headline)
                            Spacer()
                            Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = preset.copyText }
                                .labelStyle(.iconOnly)
                                .frame(minWidth: Spacing.minimumTarget, minHeight: Spacing.minimumTarget)
                                .accessibilityLabel("Copy \(preset.title) scopes")
                        }
                        Text(preset.copyText).textRole(.identifierInRow).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var passwordSection: some View {
        Section {
            SessionSignInForm(onSignedIn: { path.append(.scopes(server: server)) }, server: server)
        } header: {
            Text("Sign in with password")
        } footer: {
            Text("Without an API token, this session is the only credential and lasts until the server ends it.")
        }
    }

    private func connect() async {
        working = true
        message = nil
        defer { working = false }
        do {
            _ = try await session.connect(server: server, token: token)
            token = ""
            message = nil
            path.append(.scopes(server: server))
        } catch {
            message = switch LatticeAPIError(error) {
            case .unauthorized: "The server rejected this token."
            case let other: other.localizedDescription
            }
        }
    }
}

// MARK: Scope summary

private struct ScopeStepView: View {
    let server: URL
    @Environment(SessionStore.self) private var session
    @Environment(AppState.self) private var appState

    var body: some View {
        List {
            ScopeSummaryContent()
            if session.credentialKind == .token {
                Section {
                    NavigationLink("Also sign in for reveals") {
                        List {
                            Section {
                                SessionSignInForm(onSignedIn: {}, server: server)
                            } footer: {
                                Text("Held in memory unless you turn on Keep the session on this iPhone in Settings.")
                            }
                        }
                        .navigationTitle("Sign in for reveals")
                    }
                } footer: {
                    Text("Reveals (knock sequences, share URLs, console links) need a signed-in session.")
                }
            }
        }
        .navigationTitle("What this credential can do")
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                Button("Done") { appState.welcomePresented = false }
                    .prominentAction()
            }
        }
    }
}
