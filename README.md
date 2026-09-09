# Lattice iOS client (Astra)

The Xcode project and target stay `Astra`. The installed display name is `Lattice`. This is the phone approval device for the same Lattice control plane as the Vue console. Plugin authoring, Terminal, Store, Publishing, DNS, and host mutation stay on the web.

## Information architecture

Three tabs:

- **Inbox.** Plans that still need a person (not auto-approved linemeta) and Attention (node honesty, waiting apply, monitor down, inventory due). Empty Inbox is last refresh, last notify, quiet since.
- **Fleet.** Searchable nodes with honesty words (`never_reported` / `online` / `degraded` / `offline` / `disabled`), a compact map, and node glance (facts, SSH Guard posture read, capability admission, waiting tasks, Open on web).
- **More.** Audit, tasks, inventory, monitors, logs, network read views, notify channels, account, settings, About, Open console.

Review is a sheet. It loads `GET /api/network/approvals?id=`, hashes the plan body on screen, and sends that `plan_sha256`. Face ID or the device passcode gates approve and reject. Cancelled authentication does not POST. Reject and dismiss are first-class. Stale rows are inspect-only.

Deep links use the custom URL scheme `lattice://approvals/{id}`, `lattice://nodes/{id}`, and `lattice://monitors/{id}`. Universal Links wait for a signed build.

## Approval contract

Listing omits `plan` unless `include=plan`. Every row still has `plan_sha256`. Review must load by id and hash that body. Never hash an empty list-row plan. After approve, reload by id to read `waiting`.

Inbox is human-pending only. Auto-approved `singbox-linemeta` rows with actor `lattice-server` or `system` do not badge.

## Auth

Prefer a dedicated PAT in Keychain. Minimum scopes: `network:apply`, `node:read`, `audit:read`, `task:read`. Do not mint `notify:send`. Session plus TOTP remains a fallback.

## Alerting

The Lattice server notify channel (including Bark on the server) is the alerter. This app does not send Bark and does not run `MonitorEngine` as a client-side dispatcher. `BGAppRefresh` may refresh the Inbox badge only. The system decides if it runs.

## Directory

- `Astra.xcodeproj/` — iOS app. Target and scheme stay `Astra`.
- `AstraApp/App/` — SwiftUI shell (Inbox / Fleet / More, Review sheet).
- `Sources/AstraCore/` — testable core, no SwiftUI. New files are auto-included by SwiftPM and must also be added to the Xcode target.
- `Checks/AstraCoreCheck/` — golden fixtures for the live approval API, nodes, SSH Guard, capabilities, deep links.
- `scripts/` — local checks, iOS doctor, device build, development archive.

Details: [docs/project-structure.md](docs/project-structure.md).

## First run

1. Open `Astra.xcodeproj`.
2. Choose your Apple Team under Signing & Capabilities.
3. If `org.roobli.cdcd.Astra` is taken, change the bundle identifier and keep it stable.
4. Connect an iPhone (iOS 16+) or use the simulator.
5. Run. Open **Lattice**, then **More → Settings**.
6. Enter the Lattice server URL and a PAT with the minimum scopes above, or log in with username, password, and TOTP.
7. Test the connection. Open Inbox.

## Verify (no device required)

```sh
swift run --scratch-path .build AstraCoreCheck

xcodebuild -project Astra.xcodeproj -scheme Astra \
  -sdk iphonesimulator -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData/ci \
  CODE_SIGNING_ALLOWED=NO build
```

Full local checks: `./scripts/check-local.sh`. Device install, Face ID, and a server-sent Bark tap are manual. Do not claim background alerting works from this app.

Device build: [docs/ios-build-deploy.md](docs/ios-build-deploy.md), [docs/install-on-iphone.md](docs/install-on-iphone.md).
