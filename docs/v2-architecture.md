# Lattice iOS Client v2 — Architecture & Progress

Goal: turn the read-only personal monitor into a polished, broad **Lattice control-plane companion** for iPhone, covering as much of the server API as makes sense on a phone, with a first-class SwiftUI design.

## Layering

- `Sources/AstraCore/` — pure, testable logic compiled into BOTH the app target
  (via Xcode) and the `AstraCoreCheck` SwiftPM target (via `swift run`). No UIKit/SwiftUI.
  - `AstraCore.swift` — original client (nodes/login/TOTP), MonitorEngine, Bark, formatters.
  - `LatticeModels.swift` — Codable domain models matching the server's view structs.
  - `LatticeAPI.swift` — full typed `LatticeClient` extension for every operator endpoint.
  - `LatticeAnalytics.swift` — FleetSummary, MetricsHistory, InventorySummary, MonitorStats, formatters.
- `AstraApp/App/` — SwiftUI app (iOS 16+). Only compiled by Xcode (cannot build headless here).

## Verification

`swift run --scratch-path .build AstraCoreCheck` builds AstraCore and runs the regression
suite (decoding, request building, auth/CSRF, analytics). This is the CI-able anchor since the
full iOS app needs Xcode + a device. UI is verified by inspection + an iOS-API review pass.

## Server API coverage (operator surface)

Implemented in AstraCore (`LatticeClient`):

- Identity: `GET /api/me`, `GET /api/version`
- Nodes: `GET /api/nodes`, disable/enable, rotate-token, enroll-token, geo get/set/resolve
- Tokens: list / create / revoke
- Machine inventory: list / create / update / delete / renew / run-reminders
- Monitors: list / create / delete / results
- Notify: channels list/delete, rules list/delete, test
- Audit: query (paged) + chain verify
- Tasks: list tasks + task-results
- Logs: sources, query (paged), stats
- Network & security (read-only + gated approve): netpolicy list, netpolicy graph,
  nft baseline inputs, tunnels, approvals; approve sends `plan_sha256` (SHA-256 of
  the reviewed plan, computed via `PlanHasher`/CryptoKit) so a changed plan is rejected.

Deliberately deferred (operator-heavy, poor phone fit) — read-only or later:
dns/ddns/geo-routing, proxy/subscription, storage/kv/workers/static, plugins,
OIDC provider admin, 2FA enroll/disable. Network *authoring* (create policy, plan
nft/wireguard, create tunnels) also stays web-only; the phone only reads + approves.

## Key server contract notes

- No success envelope; values encoded directly. Lists are bare arrays except where wrapped
  (`{"rules":[]}`, `{"sources":[]}`, `{"stats":[]}`, `{"results":[]}`, `{"fired":[]}`, audit-with-params `{events,total,limit,offset}`).
- POST bodies are strict (`DisallowUnknownFields`); request payload structs match server structs exactly.
- Error envelope `{"error":{code,message,request_id}}`; auth via bearer OR `lattice_session` cookie + `X-Lattice-CSRF`.
- Secret-free views: machines expose `has_console_url`/`has_detail_url` (not URLs); tasks expose `script_sha256`/`script_size_bytes`; notify channels expose `config_keys`.

## UI structure (v2)

TabView: Overview · Nodes · Monitors · Inventory · More
- Overview: fleet health ring, stat grid, mini fleet map, cost summary, critical nodes, recent activity.
- Nodes: searchable list → NodeDetail (live metric charts, host facts, network, geo, actions, enroll QR).
- Monitors: uptime/latency list → results chart; create/delete.
- Inventory: machines, monthly cost, renewals due → detail/renew/edit.
- More: Activity (audit + local events + chain verify), Account (identity/scopes/tokens/version), Logs, Tasks, Settings.

## Status

- [x] Core models + API client + analytics + tests (`AstraCoreCheck` green)
- [x] Design system + 5-tab app shell
- [x] Feature screens (Overview, Nodes+detail+enroll/QR, Monitors, Inventory, Activity, Account, Notifications, Logs, Tasks, Settings, About)
- [x] pbxproj registration of all new files (3 core + 13 app)
- [x] Full iOS app compiles: `xcodebuild ... -sdk iphonesimulator` → **BUILD SUCCEEDED**
- [x] Docs/README refresh

## Verified

- `swift run --scratch-path .build AstraCoreCheck` → "AstraCoreCheck passed" (9 test groups incl. new API-client + analytics tests).
- `xcodebuild -project Astra.xcodeproj -scheme Astra -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build` → BUILD SUCCEEDED (arm64 + x86_64, Swift 6 strict concurrency).
- Device install + live API + Bark + background refresh still require manual on-device verification (signing/permissions).
