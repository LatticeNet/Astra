# Project structure

This directory is the Lattice iOS client. The Xcode project and target stay `Astra`; the installed display name is `Lattice`. How the pieces fit is in [architecture.md](architecture.md); what every screen does is in [design/astra-v3-design.md](design/astra-v3-design.md).

## Top level

```text
Astra/
├── Astra.xcodeproj/        iOS app (target and scheme Astra), synchronized folders
├── AstraApp/
│   ├── App/                SwiftUI app layer (see below)
│   ├── Assets.xcassets/    app icon and the color tokens of section 4.1
│   └── Info.plist
├── Sources/AstraCore/      testable core, no SwiftUI
│   ├── Shared/             foundation used by every module
│   ├── Domains/<Domain>/   one folder per module's models and API
│   └── Demo/               DemoTransport, fixtures, the invented fleet
├── Checks/AstraCoreCheck/  checks and JSON fixtures, run with SwiftPM
├── Config/                 export options
├── docs/                   English docs; design/ holds the v3 specification
├── scripts/                local checks, simulator, device build
├── Package.swift           SwiftPM: AstraCore and AstraCoreCheck
├── AGENTS.md
└── README.md
```

## Xcode

- Project, target and scheme: `Astra`. Display name: `Lattice`. Bundle id: `org.roobli.cdcd.Astra`.
- iOS 26.0 minimum, Swift 6 language mode, no third-party dependencies.
- `AstraApp/App` and `Sources/AstraCore` are synchronized root groups: any Swift file under them, at any depth, is compiled without a project edit. The M0 stubs under `AstraApp/App/Features/<Module>/` are built this way.

## App layer `AstraApp/App/`

- `Shell/`: `AstraApp` (entry and `AppServices`), `SceneDelegate` (banner and shield windows, app delegate), `RootTabs`, `AppState`, `AppRoute`, `SettingsRoute`, `AppRouteDestination`, `SettingsDestination`, `Router`, `DeepLinkRouter`, `ScopeRoots` (Fleet, Monitor, Activity), `BrowseRoot` and `BrowseDirectory`, `SearchRegistry`, `StoreRegistry`, `GlobalSheets`, `PrivacyCover`, `BannerWindow`, `BackgroundRefresh`, `LaunchArguments`, `TrustDetailScreen`.
- `Design/`: `Tokens`, `StatusStyle`, `Typography`, `Spacing`, `Rows`, `ObjectRows`, `Controls`, `FlowLayout`, `StateViews`, `ChartStyle`, `StateStrip`, `SealLabel`, `VerdictView`, `Haptics`, `A11yOverrides`, `StatusSampler` (debug builds).
- `Safety/`: `ActionRunner`, `ActionHost`, `ConfirmSheet`, `ConfirmPage`, `RevealFlowSheet`, `SecretRevealStep`, `OutcomeBanner`, `IntentAuth`, `ChangeLog`.
- `Session/`: `SessionStore`, `KeychainStore`, `StepUpCoordinator`, `Polling`, `NetworkMonitor`, `NodeDirectory`, `DiagnosticsLog`.
- `Settings/`: `WelcomeFlow`, `SettingsScreen`, `ConnectionScreen`, `ScopeSummaryScreen`, `SessionForRevealsScreen`, `DeviceSecurityScreen`, `BadgeRefreshScreen`, `DisplayScreen`, `DiagnosticsScreen`, `DemoScenarioScreen`, `AboutScreen`.
- `Features/`: `Inbox` (M1), `Fleet` (M2), `Monitoring` (M3), `Activity` (M4), `Inventory` (M5), `Networking` (M6), `SSHGuard` (M7), `Platform` (M8), `Notify` (M9), `Evidence` (M10), `Account` (M11), `Terminal` (M12), `VPN` (M13), `Intents` (M14). Each module edits only its own folder; the registries in `Shell/` already reference every module type.

## Checks

`Checks/AstraCoreCheck/main.swift` calls one check function per domain. Run them with `swift run --scratch-path .build AstraCoreCheck`; they need no device.
