#if DEBUG
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Every state of the vocabulary in section 4.2 on one screen, for the
/// grayscale and deuteranopia check of section 4.1. Debug builds only. It is
/// plain SwiftUI (no List), so it can be rendered to an image and filtered.
struct StatusSampler: View {
    var colorFilter: LaunchOverrides.ColorFilter? = LaunchOverrides.current.colorFilter

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var simulated: UIImage?

    var body: some View {
        ScrollView {
            if colorFilter == .deuteranopia {
                if let simulated {
                    Image(uiImage: simulated).resizable().scaledToFit()
                        .accessibilityLabel("Status sampler, deuteranopia simulation")
                } else {
                    ProgressView().task { simulated = renderDeuteranopia() }
                }
            } else {
                samples
                shippedRows
            }
        }
        .background(Color(uiColor: .systemBackground))
        .colorFilter(colorFilter)
        .navigationTitle("Status sampler")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var samples: some View {
            VStack(alignment: .leading, spacing: Spacing.l) {
                group("Node", NodeHonesty.allCases.map(StatusStyle.node))
                group("Path", [
                    .path(.up), .path(.degraded(nil)), .path(.down),
                    .path(.paused(PathReason(rawValue: "path_paused"))), .path(.unknown(nil)),
                ])
                group("Incident", [
                    .incident(.openCritical), .incident(.openWarning), .incident(.openInfo),
                    .incident(.acknowledged), .incident(.snoozed(until: nil)), .incident(.held(window: "")),
                    .incident(.pending(opensAt: nil)), .incident(.resolved), .flapping,
                ])
                group("Task", TaskRunState.allCases.map(StatusStyle.task))
                group("Approval", ApprovalDisplayState.allCases.map(StatusStyle.approval))
                group("SSH Guard posture", SSHGuardPostureState.allCases.map(StatusStyle.posture))
                group("SSH Guard coverage", [
                    .coverage(.confirmed), .coverage(.armPending), .coverage(.reverting(deadline: .now)),
                    .coverage(.reverting(deadline: nil)), .coverage(.open), .coverage(.failed), .coverage(.excluded),
                ])
                group("Plan seal", [.seal(.unverified), .seal(.verified), .seal(.mismatch), .seal(.noBody)])
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text("Strip").font(.headline)
                    StateStrip(cells: [.up, .up, .degraded, .down, .unknown, .paused, .up, .degraded])
                    StateStripLegend()
                }
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text("Accent next to status").font(.headline)
                    HStack {
                        Button("Approve and apply") {}
                            .buttonStyle(.borderedProminent)
                            .tint(.accentFill)
                        StatusGlyph(style: .node(.online))
                        Text("online").foregroundStyle(.secondary)
                    }
                }
            }
            .padding(Spacing.l)
    }

    /// The rows screens actually ship, so the gate checks the drawn word and
    /// not only the vocabulary. Kept out of `samples` because IncidentRow
    /// reads the ActionRunner, which the deuteranopia renderer cannot supply.
    private var shippedRows: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Shipped rows").font(.headline)
            ForEach(Self.sampleNodes) { NodeRow(node: $0) }
            ForEach(Self.samplePaths) { PathRow(path: $0, sourceName: "edge-tyo-1", targetName: "relay-fra-2") }
            IncidentRow(incident: Incident(id: "i-crit", severity: "critical", state: "open"))
            IncidentRow(incident: Incident(id: "i-ack", severity: "warning", state: "acknowledged"))
        }
        .padding(.horizontal, Spacing.l)
        .padding(.bottom, Spacing.l)
    }

    private static let sampleNodes: [LatticeNode] = ["online", "degraded", "offline", "never_reported", "disabled"].compactMap { status in
        let json = #"{"id":"n-\#(status)","name":"edge-\#(status)","status":"\#(status)","status_reason":"sing-box has been down","last_seen":"2026-10-29T00:00:00Z","metrics":{"cpu_percent":12},"host_facts":{}}"#
        return try? JSONDecoder().decode(LatticeNode.self, from: Data(json.utf8))
    }

    private static let samplePaths: [PathView] = ["up", "down"].compactMap { state in
        let json = #"{"source":"n1","target_node":"n2","target":"192.0.2.2:443","monitor_id":"m-\#(state)","method":"tcp","state":"\#(state)","loss":0}"#
        return try? JSONDecoder().decode(PathView.self, from: Data(json.utf8))
    }

    /// Renders the samples and applies the severity 1.0 deuteranopia matrix of
    /// Machado, Oliveira and Fernandes (2009) with Core Image. The matrix is
    /// applied to encoded color, close enough to judge whether states stay apart.
    private func renderDeuteranopia() -> UIImage? {
        let content = samples
            .frame(width: 390)
            .background(Color(uiColor: .systemBackground))
            .environment(\.colorScheme, colorScheme)
            .environment(\.dynamicTypeSize, typeSize)
        let renderer = ImageRenderer(content: content)
        renderer.scale = displayScale
        guard let image = renderer.cgImage else { return nil }
        let filter = CIFilter.colorMatrix()
        filter.inputImage = CIImage(cgImage: image)
        filter.rVector = CIVector(x: 0.367322, y: 0.860646, z: -0.227968, w: 0)
        filter.gVector = CIVector(x: 0.280085, y: 0.672501, z: 0.047413, w: 0)
        filter.bVector = CIVector(x: -0.011820, y: 0.042940, z: 0.968881, w: 0)
        guard let output = filter.outputImage,
              let result = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: result, scale: displayScale, orientation: .up)
    }

    private func group(_ title: String, _ styles: [StatusStyle]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(title).font(.headline)
            ForEach(Array(styles.enumerated()), id: \.offset) { _, style in
                HStack(spacing: Spacing.m) {
                    StatusGlyph(style: style).frame(width: 28)
                    Text(style.word).foregroundStyle(style.tone.word)
                }
            }
        }
    }
}
#endif
