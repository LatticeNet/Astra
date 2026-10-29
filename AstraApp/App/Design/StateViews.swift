import SwiftUI

/// The placeholder every module screen shows until its module is built.
struct StubScreen: View {
    let title: String
    /// The screen id from section 2.3 ("M2-03").
    let screenID: String
    /// Scope roots leave the title to their tab ("Fleet").
    var showsTitle = true

    var body: some View {
        let content = ContentUnavailableView {
            Label("Not built yet", systemImage: "hammer")
        } description: {
            Text("\(title) (\(screenID)) arrives with its module.")
        }
        if showsTitle {
            content.navigationTitle(title)
        } else {
            content
        }
    }
}

/// First-load placeholder rows in the real layout, hidden from VoiceOver,
/// with one element that says what is loading (section 5.0).
struct LoadingRows: View {
    /// "Loading incidents"
    let label: String
    var count = 3

    var body: some View {
        Group {
            ForEach(0..<count, id: \.self) { _ in
                StatusRow(style: StatusStyle(word: "", symbol: "circle.fill", tone: .quiet),
                          title: "Placeholder object name", detail: "Placeholder detail line", trailing: "00")
                    .redacted(reason: .placeholder)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}

/// A whole screen the token cannot read (section 5.0).
struct ScopeDeniedScreen: View {
    let scope: String
    @Environment(Router.self) private var router

    var body: some View {
        ContentUnavailableView {
            Label(AccessState.denied(scope: scope).text, systemImage: "lock")
        } description: {
            Text("Ask for a token that includes \(scope), or check what this one covers.")
        } actions: {
            Button("Token scopes") { router.openSettings([.page(.scopes)]) }
                .buttonStyle(.bordered)
            Button("Manage tokens on web") { router.openOnWeb(.tokens) }
        }
    }
}

/// A surface the app could not decode: the server is newer than the app.
struct CompanionBehindRow: View {
    let surface: String

    var body: some View {
        Label {
            Text(AccessState.companionBehind(surface: surface).text)
                .foregroundStyle(Color.statusWarnText)
        } icon: {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(Color.statusWarnFill)
        }
        .frame(minHeight: Spacing.minimumTarget)
    }
}

/// Renders a whole screen from one resource: placeholders on first load, the
/// denied and companion-behind states, an error with Retry when there is no
/// earlier data, and the content otherwise. Never blank.
struct ResourceView<Value: Sendable, Content: View>: View {
    let state: ResourceState<Value>
    /// "incidents", used in "Loading incidents" and "Could not load incidents".
    let noun: String
    let retry: () -> Void
    @ViewBuilder let content: (Value) -> Content

    var body: some View {
        switch state {
        case .denied(let scope):
            ScopeDeniedScreen(scope: scope.isEmpty ? "the scope this screen needs" : scope)
        case .companionBehind(let surface):
            ContentUnavailableView {
                Label("This app is behind the server", systemImage: "exclamationmark.triangle")
            } description: {
                Text("\(surface) could not be read.")
            } actions: {
                Button("Reload", action: retry)
            }
        case .failed(let error, nil, _):
            ContentUnavailableView {
                Label("Could not load \(noun)", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error.localizedDescription)
            } actions: {
                Button("Retry", action: retry).buttonStyle(.bordered)
            }
        default:
            if let value = state.value {
                content(value)
            } else {
                List { LoadingRows(label: "Loading \(noun)") }
            }
        }
    }
}
