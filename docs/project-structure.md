# Project structure

This directory is the Lattice iOS client. The Xcode project and target stay `Astra`. The installed display name is `Lattice`.

## Top level

```text
Astra/
├── Astra.xcodeproj/      # iOS app (target/scheme Astra)
├── AstraApp/             # SwiftUI app layer
├── Sources/AstraCore/    # testable core (no SwiftUI)
├── Checks/AstraCoreCheck # Swift regression checks, no device
├── Config/               # ExportOptions plist
├── docs/                 # English docs
├── scripts/              # local checks / doctor / device build
├── Package.swift         # SwiftPM: AstraCore + AstraCoreCheck
├── AGENTS.md
└── README.md
```

`AstraCore` is compiled twice: the Xcode app target lists `Sources/AstraCore/*.swift`, and SwiftPM auto-includes them for `AstraCoreCheck`. New core files must also be added to `Astra.xcodeproj/project.pbxproj`.

## Xcode

- Project / Target / Scheme: `Astra`
- Installed display name: `Lattice`
- Bundle ID: `org.roobli.cdcd.Astra`
- Marketing version: `0.1.0`
- iOS deployment target: `16.0`
- Swift 6 (strict concurrency)

## App layer `AstraApp/App/`

- `AstraApp.swift` — entry, background refresh registration, `onOpenURL` for `lattice://`.
- `ContentView.swift` — Inbox / Fleet / More.
- `InboxView.swift` — Plans, Attention, quiet-since; presents Review.
- `ReviewSheet.swift` — hash-bound review by id; Face ID; approve/reject/dismiss.
- `IntentAuth.swift` — `LAContext` device-owner authentication.
- `DashboardModel.swift` — `@MainActor` state: settings, Keychain, inbox, fleet glance, control-plane loads. Not an alerter.
- `BackgroundRefresh.swift` — `BGAppRefreshTask` refreshes the Inbox badge only.
- `AppSettings.swift` — Codable settings, Keychain, node snapshot, inbox quiet-since.
- `NodesView.swift` / `ServerDetailView.swift` — Fleet list and node glance.
- `MoreHubView.swift` — audit, tasks, inventory, monitors, logs, network read, account, settings, About.
- `NetworkView.swift` — NetPolicy, reachability, nft, tunnels (no review path).
- `SettingsView.swift` — server URL, PAT/session, polling, honest background-refresh copy.

## Core `Sources/AstraCore/`

- `AstraCore.swift` — client, nodes, login, formatters. `MonitorEngine` and `BarkClient` stay for library checks only.
- `LatticeNetwork.swift` — live approval API.
- `LatticeDeepLink.swift` — custom URL scheme and console paths.
- `LatticeModels.swift` / `LatticeAPI.swift` / `LatticeAnalytics.swift`

## Checks

`Checks/AstraCoreCheck/main.swift` covers node decode, URL normalize, auth, MonitorEngine/Bark library behavior, control-plane clients, analytics, approval golden fixtures (list without plan, get-by-id, waiting, reject, dismiss, linemeta skip, empty-row hash refuse), SSH Guard, capabilities, deep links.
