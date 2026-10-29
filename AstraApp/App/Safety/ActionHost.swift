import SwiftUI

extension View {
    /// Makes this view a place where write gates appear (section 8.3).
    /// RootTabs applies `.actionHost()`; every sheet applies
    /// `.actionHost(inSheet: true)` inside its own `NavigationStack`, so a gate
    /// started there pushes a ConfirmPage instead of opening a second sheet.
    func actionHost(inSheet: Bool = false) -> some View {
        modifier(ActionHostModifier(inSheet: inSheet))
    }
}

/// Keeps a host registered for as long as its view lives. A pushed page
/// covers the host without ending it, so registration is tied to the view's
/// state, not to `onDisappear`.
private final class ActionHostToken {
    let id: ActionHostID
    weak var runner: ActionRunner?

    init(id: ActionHostID) {
        self.id = id
    }

    deinit {
        let id = id
        let runner = runner
        Task { @MainActor in runner?.unregister(id) }
    }
}

private struct ActionHostModifier: ViewModifier {
    let inSheet: Bool
    @State private var token: ActionHostToken
    @Environment(ActionRunner.self) private var runner

    init(inSheet: Bool) {
        self.inSheet = inSheet
        _token = State(initialValue: ActionHostToken(id: ActionHostID(isSheet: inSheet)))
    }

    private var host: ActionHostID { token.id }

    func body(content: Content) -> some View {
        content
            .onAppear {
                token.runner = runner
                runner.register(host)
            }
            .confirmationDialog(
                dialog.map { "\($0.intent.title)?" } ?? "",
                isPresented: dialogBinding,
                titleVisibility: .visible,
                presenting: dialog
            ) { pending in
                Button(pending.intent.title) { runner.answerDialog(true) }
                Button("Cancel", role: .cancel) { runner.answerDialog(false) }
            } message: { pending in
                Text("\(pending.intent.consequence) \(pending.intent.scopes.joined(separator: ", ")).")
            }
            .modifier(GatePresentation(inSheet: inSheet, host: host))
            .haptics(inSheet ? nil : runner.haptic)
    }

    private var dialog: PendingDialog? {
        runner.pendingDialog?.host == host ? runner.pendingDialog : nil
    }

    private var dialogBinding: Binding<Bool> {
        Binding(
            get: { dialog != nil },
            set: { shown in if !shown, dialog != nil { runner.answerDialog(false) } }
        )
    }
}

/// At the root, gates are sheets; inside a sheet, they are pages pushed on
/// that sheet's stack (section 6.5, one sheet at a time).
private struct GatePresentation: ViewModifier {
    let inSheet: Bool
    let host: ActionHostID
    @Environment(ActionRunner.self) private var runner

    func body(content: Content) -> some View {
        if inSheet {
            content
                .navigationDestination(isPresented: confirmBinding) {
                    if let pending = confirm { ConfirmPage(pending: pending) }
                }
                .navigationDestination(isPresented: revealBinding) {
                    if let pending = reveal { RevealFlowPage(pending: pending) }
                }
        } else {
            content
                .sheet(item: confirmItem) { pending in
                    ConfirmSheet(pending: pending)
                }
                .sheet(item: revealItem) { pending in
                    RevealFlowSheet(pending: pending)
                }
        }
    }

    private var confirm: PendingConfirm? {
        runner.pendingConfirm?.host == host ? runner.pendingConfirm : nil
    }

    private var reveal: PendingReveal? {
        runner.pendingReveal?.host == host ? runner.pendingReveal : nil
    }

    private var confirmItem: Binding<PendingConfirm?> {
        Binding(get: { confirm }, set: { if $0 == nil, confirm != nil { runner.finishConfirm(nil) } })
    }

    private var revealItem: Binding<PendingReveal?> {
        Binding(get: { reveal }, set: { if $0 == nil, reveal != nil { runner.finishReveal() } })
    }

    private var confirmBinding: Binding<Bool> {
        Binding(get: { confirm != nil }, set: { if !$0, confirm != nil { runner.finishConfirm(nil) } })
    }

    private var revealBinding: Binding<Bool> {
        Binding(get: { reveal != nil }, set: { if !$0, reveal != nil { runner.finishReveal() } })
    }
}
