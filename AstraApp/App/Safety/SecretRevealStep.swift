import SafariServices
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The one-time value step (F-14), shared by RevealFlow and by ConfirmSheet
/// results that return a credential. The value is masked until Show, cleared
/// after 60 s, on the scene's inactive transition and when the step closes,
/// and kept masked while the screen is recorded or mirrored. It is never
/// logged, cached, restored or put in diagnostics.
struct SecretRevealStep: View {
    let secret: RevealedSecret
    let shareable: Bool
    let onClose: () -> Void

    @State private var value: String?
    @State private var shown = false
    @State private var deadline = Date.now.addingTimeInterval(60)
    @State private var captured = false
    @State private var safariURL: URL?
    @Environment(\.scenePhase) private var scenePhase

    init(secret: RevealedSecret, shareable: Bool, onClose: @escaping () -> Void) {
        self.secret = secret
        self.shareable = shareable
        self.onClose = onClose
        _value = State(initialValue: secret.value)
    }

    var body: some View {
        List {
            Section {
                if let value {
                    valueRow(value)
                } else {
                    Label("Cleared from this iPhone", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("iOS cannot block screenshots. This value is not stored on this iPhone.")
            }
            if let value {
                Section {
                    Button("Copy", systemImage: "doc.on.doc") { copy(value) }
                    if shareable && secret.kind == .shareableLink {
                        ShareLink(item: value) { Label("Share", systemImage: "square.and.arrow.up") }
                    }
                    // SFSafariViewController raises for any scheme but http and https.
                    if secret.kind == .consoleLink, let url = URL(string: value), ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                        Button("Open", systemImage: "safari") { safariURL = url }
                    }
                } footer: {
                    HStack(spacing: Spacing.xs) {
                        Text("Clears in")
                        Text(timerInterval: Date.now...deadline, countsDown: true)
                            .monospacedDigit()
                    }
                }
            }
            if let followUp = secret.followUp {
                Section {
                    WebLinkRow(title: followUp.title, path: followUp.path)
                }
            }
        }
        .navigationTitle(secret.title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button {
                clear()
                onClose()
            } label: {
                Text("Done").fontWeight(.semibold).frame(maxWidth: .infinity, minHeight: Spacing.minimumTarget - 8)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.s)
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .background(Color(uiColor: .systemGroupedBackground))
        }
        .background { SceneCaptureObserver(captured: $captured) }
        .task {
            try? await Task.sleep(until: .now + .seconds(60), clock: .continuous)
            clear()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { clear() }
        }
        .onDisappear(perform: clear)
        .sheet(item: $safariURL) { url in
            SafariView(url: url).ignoresSafeArea()
        }
    }

    @ViewBuilder
    private func valueRow(_ value: String) -> some View {
        if captured {
            Label("Hidden while the screen is being recorded or mirrored", systemImage: "eye.slash")
                .foregroundStyle(.secondary)
        } else if shown {
            Text(DetailRow.breakable(value))
                .font(TextRole.identifierInDetail.font)
                .textSelection(.disabled)
                .accessibilityLabel(value)
        } else {
            Button {
                shown = true
            } label: {
                HStack {
                    Text(String(repeating: "•", count: 16)).font(TextRole.identifierInDetail.font)
                    Spacer()
                    Text("Show").foregroundStyle(Color.accentText)
                }
            }
            .tint(.primary)
            .accessibilityLabel("Hidden value. Show")
        }
    }

    private func copy(_ value: String) {
        UIPasteboard.general.setItems(
            [[UTType.plainText.identifier: value]],
            options: [.localOnly: true, .expirationDate: Date.now.addingTimeInterval(60)]
        )
    }

    private func clear() {
        value = nil
        shown = false
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

/// A console link opens here, with no shared history, never through `openURL`.
private struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        return SFSafariViewController(url: url, configuration: configuration)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

/// Reports whether the scene is being captured (recording, AirPlay mirroring).
private struct SceneCaptureObserver: UIViewRepresentable {
    @Binding var captured: Bool

    func makeUIView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.onChange = { captured = $0 }
        return view
    }

    func updateUIView(_ view: CaptureView, context: Context) {}

    final class CaptureView: UIView {
        var onChange: ((Bool) -> Void)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            registerForTraitChanges([UITraitSceneCaptureState.self]) { (view: CaptureView, _) in
                view.report()
            }
        }

        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            report()
        }

        private func report() {
            let active = traitCollection.sceneCaptureState == .active
            DispatchQueue.main.async { [onChange] in onChange?(active) }
        }
    }
}
