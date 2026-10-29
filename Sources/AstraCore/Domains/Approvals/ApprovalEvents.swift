import Foundation

/// Port of `groupApprovalsIntoEvents` (`views/operations/approvalsModel.ts`), section 6.2.
public enum ApprovalEvents {
    /// One console event group of approvals: same writer, plugin, action
    /// prefix, kind and version transition.
    public struct Event: Sendable, Hashable, Identifiable {
        /// The console's `groupApprovalsIntoEvents` key.
        public var key: String
        public var title: String
        public var approvals: [Approval]

        public var id: String { key }

        public init(key: String, title: String, approvals: [Approval]) {
            self.key = key
            self.title = title
            self.approvals = approvals
        }
    }

    public static func group(_ approvals: [Approval]) -> [Event] {
        // M1: implement the console's key (writer | plugin | actionPrefix | kind | current->target).
        approvals.map { Event(key: $0.id, title: $0.action, approvals: [$0]) }
    }
}
