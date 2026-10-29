import SwiftUI

/// M2-08 Edit identity: name, tags, role and comment. Save is T2, its dialog
/// naming the node and the fields that changed; a server refusal shows in place.
struct NodeIdentitySheet: View {
    let nodeID: String

    @Environment(FleetStore.self) private var store
    @Environment(SessionStore.self) private var session
    @Environment(ActionRunner.self) private var runner
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    @State private var original: LatticeNode?
    @State private var name = ""
    @State private var role = ""
    @State private var comment = ""
    @State private var tags: [String] = []
    @State private var newTag = ""
    @State private var error: String?
    @State private var saving = false
    @State private var loadError: String?
    @FocusState private var tagFieldFocused: Bool
    @State private var detent: PresentationDetent = .large
    @State private var confirmingDiscard = false

    var body: some View {
        NavigationStack {
            Group {
                if original != nil {
                    form
                } else if let loadError {
                    ContentUnavailableView("Could not load the node", systemImage: "exclamationmark.triangle", description: Text(loadError))
                } else {
                    List { LoadingRows(label: "Loading node", count: 3) }
                }
            }
            .navigationTitle("Edit identity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) {
                        if changes.isEmpty { dismiss() } else { confirmingDiscard = true }
                    }
                    .disabled(saving)
                    .confirmationDialog("Discard your changes to this node?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                        Button("Discard changes", role: .destructive) { dismiss() }
                        Button("Keep editing", role: .cancel) {}
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) {
                        Task { await save() }
                    } label: {
                        Text("Save")
                    }
                    .disabled(!canSave)
                }
            }
            .actionHost(inSheet: true)
        }
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.medium, .large], selection: $detent)
        .presentationDragIndicator(typeSize.isAccessibilitySize ? .hidden : .visible)
        .interactiveDismissDisabled(saving || changes.count > 0)
        .task { await load() }
    }

    private var form: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                    .textContentType(.none)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .frame(minHeight: Spacing.minimumTarget)
            } header: {
                Text("Name")
            } footer: {
                if name.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("A node needs a name.").foregroundStyle(Color.statusWarnText)
                }
            }
            Section {
                if tags.isEmpty {
                    Text("No tags").foregroundStyle(.secondary)
                }
                FlowLayout(spacing: Spacing.s) {
                    ForEach(tags, id: \.self) { tag in
                        Button {
                            tags.removeAll { $0 == tag }
                        } label: {
                            HStack(spacing: Spacing.xs) {
                                Text(tag)
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, Spacing.m)
                            .frame(minHeight: Spacing.minimumTarget)
                            .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
                        }
                        .tint(.primary)
                        .accessibilityLabel("\(tag), tag")
                        .accessibilityHint("Removes the tag")
                    }
                }
                // At accessibility sizes the field and Add stack, so they never read as one phrase.
                (typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.s)) : AnyLayout(HStackLayout())) {
                    TextField("Add a tag", text: $newTag)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($tagFieldFocused)
                        .onSubmit(addTag)
                        .submitLabel(.done)
                    Button("Add", action: addTag)
                        .buttonStyle(.bordered)
                        .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .frame(minHeight: Spacing.minimumTarget)
            } header: {
                Text("Tags")
            } footer: {
                Text("Groups that select by tag may gain or lose this node.")
            }
            Section("Role") {
                TextField("Role", text: $role)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .frame(minHeight: Spacing.minimumTarget)
            }
            Section("Comment") {
                TextField("Comment", text: $comment, axis: .vertical)
                    .lineLimit(1...4)
                    .frame(minHeight: Spacing.minimumTarget)
            }
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.statusFailText)
                }
            }
        }
        .announcing(error)
    }

    private func addTag() {
        let tag = newTag.trimmingCharacters(in: .whitespaces)
        guard !tag.isEmpty else { return }
        if !tags.contains(tag) { tags.append(tag) }
        newTag = ""
        tagFieldFocused = true
    }

    private var changes: [String] {
        guard let original else { return [] }
        var changed: [String] = []
        if name.trimmingCharacters(in: .whitespaces) != original.displayName { changed.append("name") }
        if Set(tags) != Set(original.tags) { changed.append("tags") }
        if role.trimmingCharacters(in: .whitespaces) != (original.role ?? "") { changed.append("role") }
        if comment.trimmingCharacters(in: .whitespaces) != original.comment { changed.append("comment") }
        return changed
    }

    private var canSave: Bool {
        !saving && !changes.isEmpty && !name.trimmingCharacters(in: .whitespaces).isEmpty && store.can("node:admin")
    }

    private func load() async {
        if let record = store.record(id: nodeID) {
            fill(record.node)
            return
        }
        guard let client = session.client else { return }
        do {
            guard let node = try await client.fetchNodes().first(where: { $0.id == nodeID }) else {
                loadError = "Not found, or not visible to this token."
                return
            }
            fill(node)
        } catch {
            loadError = LatticeAPIError(error).localizedDescription
        }
    }

    private func fill(_ node: LatticeNode) {
        guard original == nil else { return }
        original = node
        name = node.displayName
        role = node.role ?? ""
        comment = node.comment
        tags = node.tags
    }

    private func save() async {
        guard let original else { return }
        addTag()
        error = nil
        saving = true
        defer { saving = false }
        let request = FleetNodeUpdateRequest(
            nodeID: original.id,
            name: name.trimmingCharacters(in: .whitespaces),
            role: role.trimmingCharacters(in: .whitespaces),
            comment: comment.trimmingCharacters(in: .whitespaces),
            tags: tags
        )
        let outcome = await runner.run(FleetIntents.updateIdentity(FleetIntents.nodeRef(original), request: request, changed: changes))
        switch outcome {
        case .done: dismiss()
        case .refused(let code, let message):
            if case .notSent("Cancelled") = code { return }
            error = message
        case .unknown(let message): error = message
        default: break
        }
    }
}
