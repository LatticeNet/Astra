# Astra architecture (v3)

Astra is the iPhone client for the Lattice control plane: the same product as the web console on a different device. The Xcode project and target stay `Astra`; the display name is `Lattice`. The design specification `docs/design/astra-v3-design.md` is the source of truth; this page explains how the code is put together so a reader can find their way before opening the spec.

## Two halves

`Sources/AstraCore/` holds everything that can be tested without a device: the HTTP client, models and decoding, the write and decision sequencing, scopes, deep links, the query grammar and the demo transport. It never imports SwiftUI or UIKit. It compiles into the app target (through the synchronized root group) and into the SwiftPM targets `AstraCore` and `AstraCoreCheck`. `Shared/` is the foundation every module uses; `Domains/<Domain>/` belongs to one module each.

`AstraApp/App/` is the SwiftUI app. It compiles the core sources directly, so app files never `import AstraCore`, and every file and type name must be unique across both halves.

## The app layer

```text
AstraApp/App/
  Shell/      app entry, scene delegate, RootTabs, routes, Router, deep links,
              scope roots, Browse, registries, banner and privacy windows,
              background refresh, demo launch arguments
  Design/     color tokens, status vocabulary, typography, rows, controls,
              charts conventions, the plan seal, the verdict line, haptics
  Safety/     ActionRunner and its gates (ConfirmSheet, ConfirmPage,
              RevealFlow, the one-time value step), the OutcomeBanner,
              IntentAuth, ChangeLog
  Session/    SessionStore, Keychain, step-up, polling, network and power
              monitors, the node directory, the diagnostics log
  Settings/   WelcomeFlow and every Settings page
  Features/   one folder per module (M1 to M14)
```

Long-lived objects are created once in `AppServices` (`Shell/AstraApp.swift`) and injected with `.environment(_:)`; views read them with `@Environment(Type.self)`. There is no `ObservableObject` and no custom environment key for a main-actor object. The scene delegate, which UIKit creates, reaches them through `AppServices.shared`.

## Navigation

Five tabs: Inbox, Fleet, Monitor, Activity and Browse. Each tab owns a `NavigationStack` of `[AppRoute]`; `AppRoute` has one case per module, each wrapping that module's route enum, and `AppRouteDestination` is the single destination switch. The Settings sheet has its own stack of `SettingsRoute`. Fleet, Monitor and Activity show their segments in an adaptive segmented control (a menu at large text sizes or narrow widths, the principal toolbar slot in landscape).

Modules cross boundaries only through `Router` (`push`, `select`, `present`, `openSettings`, `openOnWeb`) and `AppRoute` values. `Router.present` dismisses whatever is presented first and waits for an in-flight write or decision. `DeepLinkRouter` maps every `lattice://` link and every same-origin console link to a tab and path, a Settings path or a global sheet; links that arrive during the welcome flow are held, and links that arrive during a write are queued.

Restoration: the selected tab, each tab's path (JSON in scene storage), the scope segments, the Monitor window and the Review target are written to `@SceneStorage` on every change. Nothing secret is restored. A path that no longer decodes resets that tab to its root.

## Writes, decisions and reveals

Every write is a `WriteIntent` run by `ActionRunner.run`, which presents the gate for its tier in the topmost action host: nothing for T1 (the swipe label states the consequence), a confirmation dialog for T2, and a ConfirmSheet for T3, T4 and plan filing. RootTabs is the root host; every sheet applies `.actionHost(inSheet: true)` inside its own stack, so a gate started in a sheet pushes a ConfirmPage instead of opening a second sheet. The order of dry run, Face ID, the dry-run re-check, perform and verify lives in AstraCore `WriteFlow`, which a check proves sends nothing when authentication is cancelled. Outcomes go to the banner (with Undo where the intent has a verified inverse), a haptic and a `ChangeLog` bump, which makes visible screens refetch.

Decisions on approvals stay in AstraCore `DecisionFlow` and the Review sheets (M1), which hold the runner busy while they run. Reveals are `RevealIntent`s run by `ActionRunner.reveal`: the RevealFlow signs in when there is no session, asks for the authenticator code unless a step-up grant is held, then shows the value once and clears it.

## Credentials and scopes

`SessionStore` holds two clients. `client` carries the API token from the Keychain (readable after first unlock, so background refresh can use it) or, without a token, the signed-in session. `revealClient` carries the session only; with a token present it serves reveals and session-only account endpoints alone. The session lives in memory unless the operator keeps it, and then it is a user-presence Keychain item read only in the foreground. Each client's `/api/me` gives its scopes; unknown scopes are treated as unknown, not as missing.

## The scene windows

Two windows sit above SwiftUI's: the banner window (above every sheet, claiming touches only on the banner) and the shield window (above alerts), which covers the app on resign active so the app-switcher snapshot never shows data, and holds the app lock when "Require Face ID to open" is on.

## Data and polling

List stores are `@Observable @MainActor` classes created by `StoreRegistry`; detail models are view-owned. Visible screens poll through `.polling(_:version:refresh:)`, which pauses in the background, offline and when the view disappears, doubles its interval after a failure, and restarts at once on a `ChangeLog` bump. Nothing from the server is written to disk.

## Demo mode

`-AstraDemo YES` (or "Explore with demo data") swaps both clients for `DemoTransport`, which serves the fixtures of every domain. The demo launch arguments (`-AstraRoute`, `-AstraTab`, `-AstraPresent`, `-AstraAuth`, `-AstraAutoConfirm`, `-AstraDemoScenario`, `-AstraDemoNow`, `-AstraOrientation`, `-AstraColorFilter`, `-AstraBoldText`, `-AstraDifferentiateWithoutColor`) are honored only in demo mode; `scripts/sim.sh` uses them for screenshots.

## Alerting

The server's notify channels are the alerter. Background refresh updates only the badge, and the app never posts a notification.

## Verification

```sh
swift run --scratch-path .build AstraCoreCheck
scripts/sim.sh build
scripts/sim.sh demo 'lattice://fleet?scope=nodes' && scripts/sim.sh shot fleet
```

Face ID, VoiceOver, Voice Control and touch are verified on a device with `docs/design/operator-checklist.md`.
