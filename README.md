# Lattice iOS client (Astra)

The Xcode project and target stay `Astra`. The installed display name is `Lattice`. It is the iPhone client for the same Lattice control plane as the web console: triage, decide, investigate and make targeted changes away from a desk. Long-form authoring, credentials shown once and plugin UIs too rich for a phone open the exact console route instead ("Open on web").

Status: every module of section 9.3 has landed on the foundation (shell, design system, write and reveal gates, sessions, onboarding and Settings), so each screen of the screen map is built and reads from the live server or the demo fleet.

The v3 design specification is [docs/design/astra-v3-design.md](docs/design/astra-v3-design.md). How the code is organized: [docs/architecture.md](docs/architecture.md) and [docs/project-structure.md](docs/project-structure.md).

## Information architecture

Five tabs:

- **Inbox.** The verdict line, active incidents, approvals that need a person, attention rows and renewals due soon.
- **Fleet.** Nodes, groups, the map and machines.
- **Monitor.** Overview, paths, checks and incidents, with one time window for all of them.
- **Activity.** Tasks, audit, approvals history and the notify Sent log.
- **Browse.** Every other console page in a directory that mirrors the console sidebar, and search across pages and objects.

Settings opens from the button on every tab root. Deep links use `lattice://` for every object (for example `lattice://approvals/{id}`, `lattice://nodes/{id}`, `lattice://incidents/{id}`); console links to the configured server open natively too. Universal Links wait for a signed build.

## Approval contract

Review loads the approval by id (`GET /api/network/approvals?id=`), hashes the plan body that is on screen, and sends that `plan_sha256`. Listing rows omit the body, so a listing row's plan is never hashed. Face ID or the device passcode gates approve, reject and dismiss; cancelled authentication sends nothing. Stale rows are inspect-only. An approval the app cannot decode turns Approve off ("this app is behind the server"). After a decision the sheet reloads by id and checks that the transition really happened, because the server answers 200 with the unchanged view when someone else already decided.

## Writes

Every write states its object, scope and consequence before it runs. Consequential writes ask in a dialog; privileged ones open a confirmation sheet and need Face ID; irreversible ones show the server's dry run where it has one and ask for the object's name. Plan filings need no Face ID because the approval is the gate. Secrets (knock sequences, share URLs, provider console links) need a signed-in session and your authenticator code, are shown once, and are never stored.

## Credentials

Prefer a dedicated API token, kept in the Keychain on this device only. Settings > Connection > Token scopes shows what the token can and cannot do and offers three presets (Triage, Operator, Operator plus root) to paste into the console's token form. Never give a phone token `secrets:reveal`, `notify:send` or `token:admin`. A signed-in session (password plus authenticator code) is optional and is used only for reveals and session-only account pages; it is held in memory unless you choose to keep it behind Face ID.

## Alerting

The Lattice server's notify channels are the alerter. This app does not send notifications. If you turn on badge refresh, iOS refreshes the app badge in the background when it chooses, which may be hours apart, and Inbox shows when the badge data came from.

## First run

1. Open `Astra.xcodeproj` and choose your Apple team under Signing & Capabilities. Keep the bundle identifier stable once installed.
2. Run on an iPhone with iOS 26 or the simulator.
3. Connect to a server: enter its address, then paste an API token (or sign in with password and code). Or choose "Explore with demo data", where every name, address and token is invented.

## Verify (no device required)

```sh
swift run --scratch-path .build AstraCoreCheck
scripts/sim.sh build
scripts/sim.sh demo 'lattice://monitor?segment=incidents'
scripts/sim.sh shot incidents --dark --text ax5
```

Face ID, VoiceOver, Voice Control and touch are checked on a device with [docs/design/operator-checklist.md](docs/design/operator-checklist.md). Device build: [docs/ios-build-deploy.md](docs/ios-build-deploy.md), [docs/install-on-iphone.md](docs/install-on-iphone.md).
