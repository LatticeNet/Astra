import SwiftUI
#if canImport(UIKit)
import UIKit
import CoreImage.CIFilterBuiltins
#endif

// MARK: - QR code

enum QRCode {
    #if canImport(UIKit)
    static func image(from string: String, scale: CGFloat = 8) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        let context = CIContext()
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)),
              let cgImage = context.createCGImage(output, from: output.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
    #endif
}

struct QRCodeView: View {
    var content: String
    var size: CGFloat = 200

    var body: some View {
        Group {
            #if canImport(UIKit)
            if let image = QRCode.image(from: content) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                placeholder
            }
            #else
            placeholder
            #endif
        }
        .frame(width: size, height: size)
        .padding(12)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var placeholder: some View {
        Image(systemName: "qrcode")
            .font(.system(size: size * 0.5))
            .foregroundStyle(.secondary)
    }
}

// MARK: - One-time token reveal

struct TokenRevealSheet: View {
    var title: String
    var token: String
    var command: String?

    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Label("Shown once — copy it now", systemImage: "exclamationmark.shield.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.warning)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    QRCodeView(content: command ?? token, size: 210)
                        .frame(maxWidth: .infinity)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Token").font(.caption).foregroundStyle(.secondary)
                        Text(token)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    }

                    if let command, !command.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Enroll command").font(.caption).foregroundStyle(.secondary)
                            Text(command)
                                .font(.footnote.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }

                    Button {
                        copy(command ?? token)
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                }
                .padding(20)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func copy(_ value: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = value
        #endif
        withAnimation { copied = true }
    }
}

// MARK: - Enroll a new node

struct EnrollNodeView: View {
    @EnvironmentObject private var model: DashboardModel
    @Environment(\.dismiss) private var dismiss

    @State private var nodeID = ""
    @State private var name = ""
    @State private var role = ""
    @State private var tagsText = ""
    @State private var wireGuardIP = ""
    @State private var working = false
    @State private var result: NodeTokenResponse?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Node ID (e.g. tokyo-edge)", text: $nodeID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Display name", text: $name)
                    TextField("Role (optional)", text: $role)
                        .textInputAutocapitalization(.never)
                    TextField("Tags, comma separated", text: $tagsText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("WireGuard IP (optional)", text: $wireGuardIP)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("New node")
                } footer: {
                    Text("Lattice issues a one-time enrollment token. Install the agent on the machine and run the generated command.")
                }

                Section {
                    Button {
                        Task { await enroll() }
                    } label: {
                        HStack {
                            if working { ProgressView() }
                            Text("Generate enrollment token")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(working || nodeID.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .navigationTitle("Enroll node")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(item: $result, onDismiss: { dismiss() }) { result in
                TokenRevealSheet(title: "Enroll \(result.nodeID)", token: result.token, command: result.command)
            }
        }
    }

    private func enroll() async {
        working = true
        defer { working = false }
        let tags = tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        result = await model.enrollNode(
            nodeID: nodeID.trimmingCharacters(in: .whitespaces),
            name: name.trimmingCharacters(in: .whitespaces),
            tags: tags,
            role: role.trimmingCharacters(in: .whitespaces),
            wireGuardIP: wireGuardIP.trimmingCharacters(in: .whitespaces)
        )
    }
}
