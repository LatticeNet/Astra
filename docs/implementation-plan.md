# Implementation notes

Astra is the phone approval device for Lattice. Plugin authoring, Terminal, and host mutation stay on the web console.

## Live server contract (do not guess)

Read `lattice-server/internal/server/server.go` (`handleApprovals`, approve/reject/dismiss) and `server_views.go` `approvalView` before changing the client.

- List omits `plan` unless `include=plan`; every row has `plan_sha256`.
- Get-by-id is `GET /api/network/approvals?id=` returning `{"approval":...}`.
- Review loads by id and hashes that plan body. Never hash an empty list-row plan.
- Approve still `{approval_id, queue_apply, plan_sha256}`. Reject `{approval_id}`. Dismiss `{approval_id, note}`.
- Waiting is only on listing and get-by-id; after approve, reload by id.
- Inbox is human-pending only (skip auto-approved linemeta).
- SSH Guard glance: `GET /api/sshguard/status?node_id=`. Knock reveal stays web.
- Capabilities: `GET /api/nodes/capabilities?node_id=`.
- Task cancel: `POST /api/tasks/cancel` `{id}`.

## Auth

Minimum PAT scopes in the picker: `network:apply`, `node:read`, `audit:read`, `task:read`. Drop `notify:send` from the suggested set.

## Alerting

The app does not send Bark. `MonitorEngine` is not an alerter here. `BGAppRefresh` may refresh the Inbox badge only. Always-on alerting is the Lattice server notify channel.

## Secrets

UserDefaults hold non-secret settings (Lattice URL, poll interval, background refresh). Keychain holds PAT, session cookie, CSRF token, and a leftover Bark device key that this app no longer sends with. Clearing a secret field and saving deletes the Keychain item.

## Verification

```sh
swift run --scratch-path .build AstraCoreCheck
./scripts/check-local.sh
xcodebuild -project Astra.xcodeproj -scheme Astra \
  -sdk iphonesimulator -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData/ci \
  CODE_SIGNING_ALLOWED=NO build
```

Device install, Face ID, and a server-sent Bark URL that opens Review stay unverified from CI.
