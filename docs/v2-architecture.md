# Lattice iOS companion architecture

Astra is the phone approval and attention device for the Lattice control plane. It is the same product as the Vue console, on a different device. The Xcode project stays `Astra`; the display name stays `Lattice`. iOS deployment target stays 16.0.

## Layering

- `Sources/AstraCore/` — no SwiftUI. Compiled into the app target and `AstraCoreCheck`.
  - `AstraCore.swift` — transport, login/TOTP, nodes, URL normalizers. `MonitorEngine` and `BarkClient` remain as library tests only; the app does not use them as an alerter.
  - `LatticeModels.swift` — control-plane views, including SSH Guard posture and capability admission.
  - `LatticeAPI.swift` — typed `LatticeClient` endpoints, including SSH Guard status, capabilities, and task cancel.
  - `LatticeNetwork.swift` — approvals (list without plan, get-by-id, `plan_sha256`, reject, dismiss, waiting).
  - `LatticeDeepLink.swift` — `lattice://approvals|nodes|monitors/{id}` and console path helpers.
  - `LatticeAnalytics.swift` — fleet, inventory, monitor summaries.
- `AstraApp/App/` — SwiftUI. Inbox / Fleet / More, hash-bound Review sheet, Face ID intent confirm.

## Approval contract

- List: `GET /api/network/approvals` omits `plan` unless `include=plan`. Every row has `plan_sha256`.
- Get: `GET /api/network/approvals?id=` returns `{"approval":...}` with the plan body.
- Approve: `POST /api/network/approvals/approve` `{approval_id, queue_apply, plan_sha256}` of the reviewed body.
- Reject: `POST /api/network/approvals/reject` `{approval_id}`.
- Dismiss: `POST /api/network/approvals/dismiss` `{approval_id, note}`.
- Waiting is on listing and get-by-id. After approve, reload by id.
- Inbox is human-pending only (skip `singbox-linemeta` with actor `lattice-server` or `system`).
- If get-by-id cannot be decoded, show companion-behind and disable approve.

## App shell

1. Inbox: Plans + Attention + quiet-since. Review sheet loads by id, shows the proof line, hashes the on-screen plan, Face ID for approve/reject.
2. Fleet: honesty words, compact map, node glance (facts, SSH Guard read, capabilities, waiting, Open on web). No enroll QR as a primary job; no disable/rotate on glance.
3. More: audit, tasks, inventory, monitors, logs, network read, notify channels, account, settings, About, Open console.

Deep links: custom URL scheme `lattice://`. Universal Links wait for a signed build.

## Alerting

Server notify is the alerter. The app does not send Bark. `BGAppRefresh` refreshes the Inbox badge only.

## Verification

```sh
swift run --scratch-path .build AstraCoreCheck
xcodebuild -project Astra.xcodeproj -scheme Astra \
  -sdk iphonesimulator -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData/ci \
  CODE_SIGNING_ALLOWED=NO build
```

Device login, Face ID cancel, and a Bark tap that opens `lattice://approvals/{id}` stay manual. Do not claim background alerting from this app.
