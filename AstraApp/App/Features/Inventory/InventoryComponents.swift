import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

// Pieces the Inventory screens share: the renewal vocabulary, the machine
// row, the whole-list state, gated menu buttons and the copy helpers.

extension StatusStyle {
    /// A machine's standing against its renewal: symbol, the countdown in
    /// words, and color only for the warning and the overdue states.
    static func inventoryRenewal(_ state: InventoryRenewalState) -> StatusStyle {
        switch state {
        case .overdue: StatusStyle(word: state.word, symbol: "calendar.badge.exclamationmark", tone: .fail)
        case .dueSoon: StatusStyle(word: state.word, symbol: "calendar.badge.clock", tone: .warn)
        case .upcoming: StatusStyle(word: state.word, symbol: "calendar", tone: .ok)
        case .autoRenews: StatusStyle(word: state.word, symbol: "repeat.circle", tone: .ok)
        case .setupIncomplete: StatusStyle(word: state.word, symbol: "exclamationmark.triangle.fill", tone: .warn)
        case .notTracked: StatusStyle(word: state.word, symbol: "calendar.badge.minus", tone: .quiet)
        case .unprofiled: StatusStyle(word: state.word, symbol: "square.dashed", tone: .quiet)
        }
    }

    /// An Upcoming row: the kind's glyph, the due date in words, and the
    /// state's color (overdue fails, due within a week warns).
    static func inventoryUpcoming(_ item: ExpiringItem) -> StatusStyle {
        let symbol = InventoryUpcomingKind(rawValue: item.kind)?.inventorySymbol ?? "calendar"
        let tone: StatusTone = InventoryUpcoming.isOverdue(item) ? .fail : (item.state == "due" ? .warn : (item.state == "auto" ? .ok : .quiet))
        return StatusStyle(word: InventoryUpcoming.dueWords(item), symbol: symbol, tone: tone)
    }
}

extension InventoryUpcomingKind {
    /// "VPN users", for sentences.
    var inventoryPlural: String {
        switch self {
        case .machineRenewal: "machine renewals"
        case .vpnUser: "VPN users"
        case .share: "shares"
        case .tlsCertificate: "TLS certificates"
        }
    }

    var inventorySymbol: String {
        switch self {
        case .machineRenewal: "server.rack"
        case .vpnUser: "person.crop.circle"
        case .share: "link"
        case .tlsCertificate: "lock.doc"
        }
    }
}

/// One machine: its name, the renewal countdown, vendor and region, and the
/// monthly equivalent as the trailing figure.
struct InventoryMachineRow: View {
    let machine: MachineProfile
    let today: InventoryDay
    /// False when the section already names the region.
    var showsRegion = true

    @Environment(\.locale) private var locale

    var body: some View {
        let state = InventoryRenewalState.of(machine, today: today)
        let style = StatusStyle.inventoryRenewal(state)
        let monthly = InventoryCost.monthlyEquivalentCents(machine)
        let money = monthly > 0 ? InventoryCurrency.format(cents: monthly, currency: machine.currency, locale: locale) : nil
        let detail = detailLine
        StatusRow(style: style, title: machine.inventoryName, detail: detail, trailing: money.map { "\($0)/mo" })
            .accessibilityLabel([machine.inventoryName, style.word, detail, money.map { "\($0) a month" }].compactMap { $0 }.joined(separator: ", "))
    }

    private var detailLine: String? {
        guard machine.isProfiled else { return "Node \(machine.nodeName.isEmpty ? machine.nodeID : machine.nodeName)" }
        var parts: [String] = []
        let vendor = machine.vendor.trimmingCharacters(in: .whitespaces)
        parts.append(vendor.isEmpty ? "No vendor" : vendor)
        let region = machine.region.trimmingCharacters(in: .whitespaces)
        if showsRegion, !region.isEmpty { parts.append(region) }
        switch InventoryCost.billing(machine) {
        case .free: parts.append("free")
        case .onetime: parts.append("one-time")
        case .unpriced: parts.append("not priced")
        default: break
        }
        return parts.joined(separator: ", ")
    }
}

/// The whole-list states for Inventory: denied, companion behind, a failed
/// first load, offline before anything loaded, and first-load placeholders.
struct InventoryListState<Value: Sendable, Content: View>: View {
    let state: ResourceState<Value>
    let noun: String
    let retry: () -> Void
    @ViewBuilder let content: (Value) -> Content
    @Environment(NetworkMonitor.self) private var network

    var body: some View {
        // Polling stops offline, so a screen opened offline would otherwise
        // keep its placeholders forever and read as still loading.
        if !network.isSatisfied, state.value == nil, Self.isWaiting(state) {
            WholeScreenState {
                ContentUnavailableView {
                    Label("Offline", systemImage: "wifi.slash")
                } description: {
                    Text("There is no connection, and nothing was loaded here before it dropped. This screen loads when the connection returns.")
                }
            }
        } else {
            ResourceView(state: state, noun: noun, retry: retry, content: content)
        }
    }

    private static func isWaiting(_ state: ResourceState<Value>) -> Bool {
        switch state {
        case .idle, .loading, .failed: true
        case .loaded, .denied, .companionBehind: false
        }
    }
}

/// The error row for a list whose last refresh failed while earlier data stays.
struct InventoryRefreshError<Value: Sendable>: View {
    let state: ResourceState<Value>
    let noun: String
    let retry: () -> Void

    var body: some View {
        if case .failed(let error, let last, _) = state, last != nil {
            ErrorRow(message: "Could not refresh \(noun): \(error.localizedDescription)", retry: retry)
        }
    }
}

/// A menu button that stays in place, disabled, with the missing scope as
/// its subtitle (section 5.0).
struct InventoryGatedButton: View {
    let title: String
    let systemImage: String
    /// "inventory:admin" when the token lacks it; nil when allowed.
    let missing: String?
    var role: ButtonRole?
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            if let missing {
                Text(title)
                Text("Needs \(missing)")
                Image(systemName: systemImage)
            } else {
                Label(title, systemImage: systemImage)
            }
        }
        .disabled(missing != nil)
    }
}

enum InventoryCopy {
    static func copy(_ text: String) {
        UIPasteboard.general.string = text
    }

    static func machineLink(_ id: String) -> String {
        LatticeDeepLink.machine(id: id).customURL?.absoluteString ?? "lattice://machines/\(id)"
    }
}

extension MachineProfile {
    /// The id a route opens this row with: the profile's, or the node's for a node nobody profiled.
    var inventoryRouteID: String { id.isEmpty ? nodeID : id }

    /// A renewal can be recorded once a profile tracks one (a cycle or a date).
    var inventoryCanRenew: Bool { isProfiled && InventoryCost.hasRenewalIntent(self) }
}

/// The active query as the navigation subtitle (section 5.0).
struct InventoryFilterSubtitle: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text, !text.isEmpty {
            content.navigationSubtitle(text)
        } else {
            content
        }
    }
}

/// The fired reminders of one run, handed from the write back to the sheet.
actor InventoryFiredSink {
    private(set) var fired: [RenewalReminderFire]?

    func set(_ fired: [RenewalReminderFire]) {
        self.fired = fired
    }
}

/// Reports every touch in the window without taking part in gesture
/// handling, so the list can hold poll reorders until the operator's finger
/// has been still for a moment (stable lists, section 5.0).
struct InventoryTouchProbe: UIViewRepresentable {
    let onTouch: @MainActor () -> Void

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onTouch = onTouch
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        view.onTouch = onTouch
    }

    final class ProbeView: UIView {
        var onTouch: (@MainActor () -> Void)?
        private let recorder = Recorder()

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            recorder.onTouch = { [weak self] in self?.onTouch?() }
        }

        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            recorder.view?.removeGestureRecognizer(recorder)
            window?.addGestureRecognizer(recorder)
        }
    }

    /// Never recognizes: it notes the touch and fails, so no other gesture waits on it.
    final class Recorder: UIGestureRecognizer, UIGestureRecognizerDelegate {
        var onTouch: (() -> Void)?

        init() {
            super.init(target: nil, action: nil)
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
            delegate = self
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            onTouch?()
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            onTouch?()
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            onTouch?()
            state = .failed
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            state = .failed
        }

        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    }
}
