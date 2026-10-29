import SwiftUI

/// M7-04 one agent release: its artifacts by platform with their digests,
/// what this control plane stores of it, and who runs it. Read only.
struct AgentReleaseScreen: View {
    let id: String

    @Environment(AgentUpdatesStore.self) private var store
    @Environment(ChangeLog.self) private var changes
    @Environment(Router.self) private var router
    @Environment(\.locale) private var locale
    @Environment(\.timeZoneMode) private var mode

    private var version: String { AgentUpdatesVersion.normalize(id) }

    var body: some View {
        content
            .navigationTitle(version)
            .navigationSubtitle(subtitle)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Open on web", systemImage: "safari") {
                            router.openOnWeb(LatticeConsolePath(path: "/platform/agent-updates", query: [URLQueryItem(name: "view", value: "distribution")]))
                        }
                        Button("Copy version", systemImage: "doc.on.doc") { SSHGuardCopy.copy(version) }
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                }
            }
            .polling(.standard, version: changes.version([.agentUpdates])) { await store.refresh() }
    }

    private var isLatest: Bool { store.latest.map(AgentUpdatesVersion.normalize) == version }

    private var candidate: AgentUpdatesReleaseCandidate? {
        store.release.value?.candidates.first { AgentUpdatesVersion.normalize($0.version) == version }
    }

    private var stored: [AgentUpdatesArtifact] {
        (store.artifacts.value?.artifacts ?? []).filter { AgentUpdatesVersion.normalize($0.version) == version }
    }

    private var subtitle: String {
        if isLatest { return "Latest stable" }
        if let candidate { return candidate.prerelease ? "Prerelease, \(candidate.channel)" : candidate.channel.capitalized }
        return ""
    }

    /// Platform and digest per artifact: the release's SHA256SUMS for the
    /// latest stable, else the digests of the binaries this server stores.
    private var artifacts: [(platform: String, file: String, sha: String)] {
        if isLatest, let release = store.release.value {
            return release.artifacts.compactMap { file in
                guard let sha = release.sha256[file] else { return nil }
                return (AgentUpdatesArtifactName.platform(file) ?? file, file, sha)
            }.sorted { $0.platform < $1.platform }
        }
        return stored.map { ($0.platform, "lattice-agent-\($0.os)-\($0.arch)", $0.sha256) }.sorted { $0.platform < $1.platform }
    }

    @ViewBuilder
    private var content: some View {
        if let missing = store.missingGate {
            ScopeDeniedScreen(scope: missing.joined(separator: " and "))
        } else if store.release.value == nil, store.artifacts.value == nil {
            switch store.release {
            case .failed(let error, nil, _):
                WholeScreenState {
                    ContentUnavailableView {
                        Label("Could not load the release", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error.localizedDescription)
                    } actions: {
                        Button("Retry") { Task { await store.refresh() } }.buttonStyle(.bordered)
                    }
                }
            default:
                List { LoadingRows(label: "Loading the release", count: 4) }
            }
        } else if !isLatest, candidate == nil, stored.isEmpty {
            WholeScreenState {
                ContentUnavailableView("Release \(version) is not listed", systemImage: "shippingbox",
                                       description: Text("The server lists the newest releases and the binaries it stores. This version is neither."))
            }
        } else {
            list
        }
    }

    private var list: some View {
        let running = (store.nodes.value ?? []).filter { AgentUpdatesVersion.normalize($0.agentVersion) == version }
        return List {
            Section {
                DetailRow(label: "Version", value: version, monospaced: true)
                if let candidate {
                    DetailRow(label: "Tag", value: candidate.tagName, monospaced: true)
                    DetailRow(label: "Channel", value: candidate.prerelease ? "\(candidate.channel), prerelease" : candidate.channel, copyable: false)
                } else if isLatest, let release = store.release.value {
                    DetailRow(label: "Tag", value: release.latestTag, monospaced: true)
                    DetailRow(label: "Channel", value: release.channel.isEmpty ? "stable" : release.channel, copyable: false)
                }
                DetailRow(label: "Nodes running it", value: running.isEmpty ? "None" : "\(running.count)", copyable: false)
                if let url = releaseURL {
                    Link(destination: url) {
                        Label("Release notes", systemImage: "arrow.up.forward.square")
                            .frame(minHeight: Spacing.minimumTarget)
                    }
                    .accessibilityHint("Opens the release page in your browser")
                }
            }
            Section {
                if artifacts.isEmpty {
                    Text(isLatest ? "The release lists no agent binary." : "This server stores no binary of this version, and the release host lists digests only for the latest stable.")
                        .foregroundStyle(.secondary)
                        .frame(minHeight: Spacing.minimumTarget)
                }
                ForEach(artifacts, id: \.file) { artifact in
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(artifact.platform).textRole(.rowTitle)
                            Spacer(minLength: Spacing.s)
                            if stored.contains(where: { $0.platform == artifact.platform }) {
                                Label("stored", systemImage: "internaldrive")
                                    .labelStyle(.titleAndIcon)
                                    .textRole(.rowDetail)
                            }
                        }
                        DetailRow(label: "SHA-256", value: artifact.sha, monospaced: true)
                    }
                }
            } header: {
                Text("Artifacts by platform").accessibilityAddTraits(.isHeader)
            } footer: {
                Text("A plan pins one of these digests, and the node checks the download against it before it replaces the running agent.")
            }
            if !stored.isEmpty {
                Section {
                    ForEach(stored) { artifact in
                        DetailRow(label: artifact.platform, value: ByteCountFormatter.string(fromByteCount: artifact.sizeBytes, countStyle: .file),
                                  secondary: artifact.updatedAt.map { "stored \(TimeDisplay.dateTime($0, mode: mode, locale: locale))" }, copyable: false)
                    }
                } header: {
                    Text("Stored on this control plane").accessibilityAddTraits(.isHeader)
                }
            }
            Section {
                Text("Each agent binary states its own compatibility floors (lattice-agent -compat-json), and the update plan reads them on the node before it installs. The control plane does not publish them per release.")
                    .textRole(.footnote)
            } header: {
                Text("Compatibility").accessibilityAddTraits(.isHeader)
            }
            if !running.isEmpty {
                Section {
                    ForEach(running.sorted { $0.displayName < $1.displayName }) { node in
                        NavigationLink(value: AppRoute.fleet(.node(id: node.id))) {
                            StatusRow(style: StatusStyle.node(node.honesty), title: node.displayName, detail: node.role)
                        }
                    }
                } header: {
                    Text("Running \(version)").accessibilityAddTraits(.isHeader)
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await store.refresh() }
    }

    private var releaseURL: URL? {
        let raw = candidate?.releaseURL ?? (isLatest ? store.release.value?.releaseURL : nil) ?? ""
        guard let url = URL(string: raw), url.scheme == "https" else { return nil }
        return url
    }
}
