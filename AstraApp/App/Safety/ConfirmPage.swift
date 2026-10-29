import SwiftUI

/// The ConfirmSheet's content pushed on another sheet's stack (F-15), so a
/// write started inside a sheet never opens a second one. Going back cancels.
struct ConfirmPage: View {
    let pending: PendingConfirm
    @State private var model: ConfirmFlowModel

    init(pending: PendingConfirm) {
        self.pending = pending
        _model = State(initialValue: ConfirmFlowModel(pending: pending))
    }

    var body: some View {
        ConfirmFlowView(model: model)
            .interactiveDismissDisabled(model.isSending)
            .onDisappear { model.close() }
    }
}
