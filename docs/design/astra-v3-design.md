# Astra v3 design specification

Status: final design for implementation, revision 2 of 2026-10-28 (critic findings resolved). This document is the single source of truth for the v3 rebuild of Astra (display name Lattice). Foundation and feature implementers build from it without asking questions. Where it says "must", it is a requirement; where it gives a value, use that value.

It was synthesized from three proposals (parity, on-call, iOS-native) and three independent judge reviews, then revised against a design, accessibility, server-contract and implementability critique. The parity proposal is the base. Conflicts were resolved in this order: the brief's non-negotiables, then Apple HIG for iOS 26, then operator task fit, then implementability.

Inputs that stay authoritative next to this document: `docs/design/brief.md` (product, platform, non-negotiables), `docs/design/console-inventory.md` (every console page, action and endpoint), `README.md` (approval contract), and the existing `AstraApp/App/ReviewSheet.swift` and `Sources/AstraCore/LatticeNetwork.swift` (the hash-bound review that v3 preserves). Response shapes come from `docs/design/api-shapes.md`, which M0a generates (section 8.9).

Facts verified against source on 2026-10-28 and relied on below:

- Step-up is session-only. `handleSecurityStepUp` refuses bearer principals (`lattice-server/internal/server/server_stepup.go:27`). A grant lives one minute (`stepUpGrantTTL`, line 13) and is reusable until it expires inside the same session (`stepUpGrantHeld`, line 113). A wrong code answers 401 "invalid second factor" (lines 45 to 55). TOTP replay protection (`AdvanceTOTPStep`) is per account, shared across devices. A PAT reveals secrets only with `secrets:reveal`, which no wildcard satisfies (`rbac.explicitOnlyScopes`) and which the phone never mints.
- Incident snooze accepts `minutes: 0` to end a snooze (`server_incidents.go:519` and `:533`).
- `GET /api/incidents` accepts `state` only as a comma list of `pending`, `open`, `acknowledged`, `resolved` and answers 400 "unknown state" for anything else (`server_incidents.go:129`). Without `state` it returns all four, default limit 500. `active`, `snoozed` and `all` are console URL filter names (`incidentsModel.ts`), never API values.
- `POST /api/monitors/update` requires `version` (`monitor_update.go:185`); a mismatch is 409 `ErrMonitorVersion`. Generated checks (from a definition or `managed_by` probe configuration) refuse edits and deletes with 409 `ErrMonitorManaged` (`generatedMonitorRefusal`, line 31). Pause and resume therefore send `{id, version, enabled}`.
- The approvals listing is filtered per caller by `approvalPrimaryScopeAllows` (`server.go:7993`) and a decision additionally needs `approvalDecisionExtraScope` (`server.go:9738`). Approving an already-decided approval returns 200 with the unchanged view; reject does the same for any non-pending approval.
- `rbac.compatibleScopes` (`internal/rbac/rbac.go:92`) is the only alias table: `sshguard:admin` satisfies `sshguard:read`; `vpncore:read` satisfies `proxy:read` and `proxy:read` satisfies `vpncore:read` and `substore:read` (likewise for `:admin`). No other admin scope implies read.
- `GET /api/sshguard/status` returns a server `stage` per node (`idle`, `arm_pending`, `arm_approved`, `arm_failed`, `awaiting_confirm`, `confirm_pending`, `confirm_approved`, `confirmed`, `hardened`, `reverted`, `in_force`; `server_sshguard_status.go:33`) and skips nodes the caller lacks `network:plan` on, with no hidden count. The console derives coverage in `views/networking/sshGuardBoardModel.ts` (`boardStage`, `coverageBucket`, `revertingNodes`) and the deadline in `sshGuardModel.ts` (`revertDeadline`, `rotateEligibility`, `buildRotationRequest`).
- The console addresses a path by `encodePathKey` in `lattice-dashboard/src/views/fleet/pathsModel.ts:180`: `<source>~<targetNode>` for a node pair, `<source>~@<monitorId>` for a check to an address, with `_` standing for the control plane.
- `MonitoringView.vue:130` treats `?open=` and `?node=` as the Checks layer. The incidents layer reads no `open` parameter. `AccessView`, `UsersView`, `TokensView` and `SsoView` read no `open` parameter either.
- Notify deliveries carry `incident_ids` (`lib/api/types.ts:3359`). Their list filters are `channel_id`, `event_type`, `outcome`, `event_id`, `source`, `source_id` (`server_notify_outbox.go:346`).
- Today's `LatticeConsolePath.approvals` builds `/approvals/{id}` and `.monitors` builds `/monitors/{id}`. Both hit the console's catch-all route. The console opens objects with `?open=`.
- The Xcode project is on synchronized folders: commit `cdb93de` moved it to `objectVersion = 77` with `PBXFileSystemSynchronizedRootGroup` roots `AstraApp/App` and `Sources/AstraCore`, iOS 26.0 and `SWIFT_VERSION = 6.0`, one `PBXNativeTarget` (the app) and no UI test target. Any file placed under those two folders, at any depth, is compiled without a project edit.
- `xcrun simctl ui` offers only `appearance`, `increase_contrast` and `content_size`; simctl cannot tap, swipe, rotate or toggle Bold Text, Button Shapes, Reduce Transparency, Differentiate Without Color or VoiceOver. `scripts/sim.sh` names its clone `Astra-<hash of checkout path>` whatever the base device, and the build machine has only iPhone 17 Pro and 17 Pro Max instances on iOS 26.5.

---

## 1. Decisions summary

| Topic | Decision |
|---|---|
| Platform | iOS 26.0 minimum, Swift 6 language mode with nonisolated default actor isolation in both builds, Xcode 26.5, SwiftUI only, no third-party dependencies. Every iPhone from SE (375 pt) up, portrait and landscape. iPad gets the adaptive sidebar from `.tabViewStyle(.sidebarAdaptable)` with no iPad-only work. |
| Tabs | Five regular tabs: **Inbox** (`tray.full`), **Fleet** (`server.rack`), **Monitor** (`waveform.path.ecg`), **Activity** (`clock.arrow.circlepath`), **Browse** (`square.grid.2x2`). Browse carries `.searchable` at its root in the standard style: the directory is its empty state and the palette results are its search results. Settings opens from a trailing toolbar button labelled "Settings" (`person.crop.circle`) on every tab root. No "More" tab, no `Tab(role: .search)`. Tapping the selected tab pops to its root and scrolls to the top. |
| Scope switching | One visible pattern on all three scoped tabs: a segmented control of at most four noun segments in a `safeAreaBar(edge: .top)` slot, replaced by a Menu picker labelled with the current segment when `dynamicTypeSize >= .xxxLarge` or the width is under 390 pt, and moved to `ToolbarItem(placement: .principal)` in a compact vertical size class. Fleet: Nodes, Groups, Map, Machines. Monitor: Overview, Paths, Checks, Incidents. Activity: Tasks, Audit, Approvals, Sent. No title menus. |
| Where pages live | Fleet scopes as above; Upcoming is a pushed screen reached from a header row in Machines and from Inbox "Due soon". Browse: recently opened pages, then a directory that mirrors the console sidebar (Fleet, VPN, Operations, Networking, Platform including Evidence, Settings). Rows that switch tabs or open the Settings sheet look different from push rows (2.4). |
| Signature element | The **plan seal** in text form: the `seal` symbol plus the first and last four hex characters of `plan_sha256` in SF Mono ("3f9a…c210"). It appears only where a plan hash is bound to a decision. The phone shows `checkmark.seal.fill` only after it has hashed the on-screen body itself and the hash matched. |
| Inbox header | The **verdict line**: one `.headline` sentence, the first list section, marked as a header, built only from data on screen. It never says "Quiet" when any section is failed, stale or offline; a scope-denied section qualifies the quiet verdict instead ("Quiet for what this token can see. Not covered: DDNS, SSH Guard."). Count buttons sit beneath it in a wrapping flow. It is a behavior rule, not a second signature. |
| Accent | Cobalt, split into two tokens: `accent.text` (`#2F5BEA` light, `#7C9BFF` dark) for tinted text, links and chart series, and `accent.fill` (`#2F5BEA`, `#1F45C7` in Light Increase Contrast) for prominent button backgrounds so a white label passes 4.5:1 in every variant. Status colors are reserved for status. Acknowledged, snoozed and held incidents use the quiet style, never blue. |
| Content style | Opaque inset-grouped lists. Liquid Glass only on the navigation and control layer (tab bar, nav bars, toolbars, search field, menus, sheets). Prominent actions are toolbar items (`.confirmationAction` or `.bottomBar`) or `.borderedProminent` inline, never glass in content. No material cards, gradients, ring gauges or stat-tile walls. |
| Presentation | One sheet at a time. A flow presents once and advances its content in place (confirm, authenticate, result or one-time reveal). Inside a sheet, confirmation is a page pushed on that sheet's stack. `Router.present` dismisses whatever is presented first. The privacy cover, the app lock and the OutcomeBanner live in scene-level windows above every sheet. |
| Write policy | Every write is a `WriteIntent` run by one `ActionRunner`; every reveal is a `RevealIntent`. Tiers: T1 swipe ack/unack/snooze on a row whose label states the consequence; T2 confirmation dialog naming object and consequence; T3 ConfirmSheet plus Face ID; T4 irreversible, dry run where the server has one, button carrying the object name, Face ID; P plan filing (ConfirmSheet, findings loop, then the filed approval opens in Review); D decisions (the existing hash-bound contract); S secrets (session step-up with TOTP). Outcomes are `.done`, `.partial`, `.refused`, `.unknown` (re-read, never retry a non-idempotent call), `.filed` with its refused half. Undo inherits the tier of the inverse. |
| Credentials | A PAT in the Keychain is the primary credential (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`). An optional signed-in session (password plus TOTP) is held in memory by default, used only for step-up reveals and session-only account endpoints, and ended after a reveal unless the operator opts to keep it (then it is a `.userPresence` Keychain item never read in the background). Session alone also works as the only credential. Passkeys wait for Associated Domains on a signed build. |
| Scopes | Two scope sets: `tokenScopes` (PAT `/api/me`) and `sessionScopes` (session `/api/me`). `ScopeSet` ports `rbac.directlyAllows` and `compatibleScopes` exactly. Approval visibility and decision scopes come from an AstraCore table mirrored from the server. Token presets are derived from the parity matrix; `task:run`, `terminal:open` sit only in "Operator plus root"; `token:admin` is in no preset. |
| Step-up | TOTP inside the RevealFlow sheet on the session client. The grant is held in memory until `expires_at` and reused for every reveal in that minute. Never written to disk. |
| Badge | One badge, on Inbox and the app icon: human-pending approvals visible to this token plus open, unacknowledged, unsnoozed, not-held incidents of severity warning or critical, computed by AstraCore `BadgeCount` from `GET /api/incidents?state=open,acknowledged`. Inbox stamps the time the badge data came from. Background refresh updates only the badge; the server's notify channels are the alerter. |
| Notifications permission | Requested only when the operator turns on Badge refresh in Settings (`.badge` option only). Never on first launch. |
| Times | Local time with relative age by default, formatted with `Date.FormatStyle` so the locale and the 12 or 24-hour setting apply. Settings > Display offers "Show times in UTC". Detail rows show the other zone on a secondary line. No hidden gestures. |
| Terminal | Native session list, read-only transcript from `/sessions/{id}/events`, and close, all needing `terminal:open`. Creating a session and typing stay on the web. |
| Batch approve | Native, one console event group at a time (the console's `groupApprovalsIntoEvents` key). Every body is loaded by id and hashed; every distinct body is on screen inline; one Face ID decides; results come back per row, and a row another operator already decided counts as failed. |
| What goes to the web, and why | Long-form authoring and selector forms (checks, definitions, outbound policies, DNS deployments, geo routes, tunnels create, node groups create and edit, users, SSO providers, script tasks, auto-update policy, IP-discovery override, maintenance window edit); anything whose result is a credential shown once that belongs on a host (enroll token, reconfigure command, webhook secret, API token create); plugin UIs too rich for a phone (Sub-Store, vpn-core profiles, usage and rollouts, WireGuard mesh, NetGuard writes, sandboxed third-party pages); writes that need a scope the phone must never hold (`notify:send`); Store writes; terminal input; password, TOTP and passkey enrollment. "Open on web" lands on the exact console route with the same object open where the console supports it, and on the list where it does not (2.5 says which). |
| Deferred past v3 | Lock Screen widget, Spotlight indexing, App Group and shared Keychain, Live Activities, Universal Links and passkeys (need a signed build with Associated Domains), native terminal input, QR scanning of tokens, a UI test target. A late module adds two App Intents that only open screens. |

---

## 2. Information architecture and navigation

### 2.1 Tab bar

`TabView(selection:)` with the iOS 18 `Tab` API and `.tabViewStyle(.sidebarAdaptable)`. The selected tab is persisted (section 2.6). Tapping the already-selected tab sets `paths[tab] = []` and scrolls the root list to the top.

| Tab | Symbol | Badge | Root | Job |
|---|---|---|---|---|
| Inbox | `tray.full` | needs-you approvals plus open unacknowledged warning/critical incidents | `InboxScreen` | Triage and decide. First screen on every launch unless state restoration returns elsewhere. |
| Fleet | `server.rack` | none | `FleetRoot` (segments: Nodes, Groups, Map, Machines) | The objects the operator owns: nodes, groups, machines and renewals. |
| Monitor | `waveform.path.ecg` | none | `MonitorRoot` (segments: Overview, Paths, Checks, Incidents) | Investigate: paths, checks, incidents, maintenance. |
| Activity | `clock.arrow.circlepath` | none | `ActivityRoot` (segments: Tasks, Audit, Approvals, Sent) | What happened and what is running. |
| Browse | `square.grid.2x2` | none | `BrowseRoot` (directory when the search field is empty, palette results while typing) | Every other console page and the command palette. Directory deep links land in this stack. |

Every tab root has a trailing toolbar group, separated from other trailing items by `ToolbarSpacer(.fixed)`, holding one button with accessibility label "Settings" (`person.crop.circle`) that presents the Settings sheet. In demo mode a plain `Label("Demo", systemImage: "theatermasks")` bar button sits before it (the system draws it in glass) and opens the same sheet at its "Demo data" section.

### 2.2 On-the-go tiers

This table is the written rule for Inbox ordering and for choosing native or web. Inbox sections appear in tier 1 order. A feature is native when it serves tiers 1 to 3; tier 4 is a read view plus an exact "Open on web" link.

| Tier | Moment | Surfaces |
|---|---|---|
| 1. 2am | Woken by a notify message | Active incidents, approvals that need a person, SSH Guard confirm before the automatic revert, offline or degraded node, degraded path, failed task, control-plane health |
| 2. Train | Investigating with time | Node detail and activity, path chart, task per-node output, audit by trace, notify Sent log (did the alert go out), Upcoming renewals |
| 3. Between meetings | Small targeted changes | Filing plans (agent update, beacon, tunnel, SSH Guard rotate, policy plan), renewing a machine, revoking a token or share, DDNS run now, maintenance window |
| 4. Desk | Long input, authoring, credentials shown once | Check and definition authoring, policy editing, DNS deployments, groups and selectors, Store writes, publishing creation, plugin verify, users, SSO, script authoring |

Acceptance check for every feature, the **two-tap guarantee**: from any Inbox signal (incident, attention row, approval), the evidence behind it (chart, last check result, task output, plan body) is on the screen one tap away or one row deeper.

### 2.3 Screen map

Presentation: **push** onto the tab's stack, **sheet** (with detents, one at a time), **cover** (full-screen cover), **window** (a scene-level `UIWindow` above every sheet). "Owner" is the implementation module (section 9). Every screen is listed.

| ID | Screen | Owner | Presentation and parent | Entry points |
|---|---|---|---|---|
| F-01 | RootTabs | M0b | app root | launch |
| F-02 | WelcomeFlow (Welcome, Server, Credential, TOTP, ScopeSummary) | M0b | cover | first launch, Sign out |
| F-03 | Settings | M0b | sheet (large) with its own NavigationStack | Settings button, Browse > Settings rows, `lattice://settings/connection`, token and user links |
| F-04 | Connection | M0b | push in Settings | Settings |
| F-05 | ScopeSummary | M0b | push in Settings and WelcomeFlow | Settings > Connection, any ScopeDenied row |
| F-06 | SessionForReveals | M0b | push in Settings | Settings > Connection, StepUp explanation |
| F-07 | DeviceSecurity | M0b | push in Settings | Settings |
| F-08 | BadgeRefresh | M0b | push in Settings | Settings |
| F-09 | Display | M0b | push in Settings | Settings |
| F-10 | Diagnostics | M0b | push in Settings | Settings |
| F-11 | DemoScenario | M0b | push in Settings (demo only) | Settings |
| F-12 | About | M0b | push in Settings | Settings, Browse > Settings > About |
| F-13 | RevealFlowSheet (code step, value step) | M0b | sheet (large); steps pushed inside a sheet when started there | any S action |
| F-14 | SecretRevealStep | M0b | step of F-13 and of F-15 | after step-up, rotate token, any shown-once value |
| F-15 | ConfirmSheet and ConfirmPage | M0b | sheet at the root; pushed page inside another sheet | T3, T4, P actions |
| F-16 | OutcomeBanner | M0b | window (BannerWindow), bottom, above sheets | after any write |
| F-17 | TrustDetail | M0b | push | Inbox trust row |
| F-18 | ShieldWindow (privacy cover and AppLock) | M0b | window above alerts | resign active; foreground with Face ID to open on |
| F-19 | FleetRoot | M0b | tab root | Fleet tab |
| F-20 | MonitorRoot | M0b | tab root | Monitor tab |
| F-21 | ActivityRoot | M0b | tab root | Activity tab |
| F-22 | BrowseRoot (directory, search results) | M0b | tab root | Browse tab |
| M1-01 | InboxScreen | M1 | tab root | Inbox tab, `lattice://inbox` |
| M1-02 | ApprovalReviewSheet | M1 | sheet (large) | approval rows anywhere, `lattice://approvals/{id}`, P outcomes |
| M1-03 | BatchReviewSheet | M1 | sheet (large) | Inbox grouped approval row, Approvals history "Needs you" group |
| M1-04 | ApprovalsScreen (Needs you, History, Stuck) | M1 | Activity scope "Approvals" | Activity, Browse, count button |
| M1-05 | InboxAllAttentionScreen | M1 | push | Inbox Attention "Show all" |
| M2-01 | NodesScreen | M2 | Fleet scope "Nodes" | Fleet, Browse |
| M2-02 | DuplicatesScreen | M2 | push | Nodes duplicate banner |
| M2-03 | NodeDetailScreen (Overview, Activity, Settings) | M2 | push | any node mention, `lattice://nodes/{id}` |
| M2-04 | NodeHistoryScreen | M2 | push | NodeDetail history section |
| M2-05 | NodeNetworkScreen | M2 | push | NodeDetail effective network row |
| M2-06 | NodeCapabilitiesScreen | M2 | push | NodeDetail capabilities row |
| M2-07 | NodeBeaconScreen | M2 | push | NodeDetail beacon row |
| M2-08 | NodeIdentitySheet | M2 | sheet (medium, large) | NodeDetail Settings > Edit identity |
| M2-09 | Node delete (T4 intent with dry run) | M2 | ConfirmSheet content (F-15) | NodeDetail Settings > Delete node |
| M2-10 | GroupsScreen | M2 | Fleet scope "Groups" | Fleet, Browse |
| M2-11 | GroupDetailScreen | M2 | push | Groups, NodeDetail group rows, `lattice://groups/{id}` |
| M2-12 | MapScreen | M2 | Fleet scope "Map" | Fleet, Browse |
| M2-13 | UnlocatedNodesScreen | M2 | push | Map toolbar "No location (n)" |
| M2-14 | CapabilityGatesScreen | M2 | push | Browse > Settings > Capability Gates |
| M2-15 | GateDetailScreen | M2 | push | CapabilityGates rows |
| M3-01 | MonitorOverviewScreen | M3 | Monitor segment "Overview" | Monitor |
| M3-02 | PathsScreen | M3 | Monitor segment "Paths" | Monitor, Browse |
| M3-03 | PathMatrixScreen | M3 | push | Paths view menu "Matrix" (row and column headers push filtered Paths) |
| M3-04 | PathDetailScreen | M3 | push | path rows, incidents, node detail, `lattice://paths/{key}` |
| M3-05 | ChainDetailScreen | M3 | push | Paths "Chains" view |
| M3-06 | ChecksScreen | M3 | Monitor segment "Checks" | Monitor, Browse |
| M3-07 | CheckDetailScreen | M3 | push | checks, path detail, `lattice://checks/{id}`, `lattice://monitors/{id}` |
| M3-08 | CheckResultsScreen | M3 | push | CheckDetail "All results" |
| M3-09 | DefinitionDetailScreen | M3 | push | Checks "Definitions" section, `lattice://definitions/{id}` |
| M3-10 | IncidentsScreen | M3 | Monitor segment "Incidents" | Monitor, Browse |
| M3-11 | IncidentDetailScreen | M3 | push | incident rows anywhere, `lattice://incidents/{id}` |
| M3-12 | MaintenanceStartSheet | M3 | sheet (medium) | IncidentDetail, NodeDetail menu, Incidents toolbar |
| M3-13 | MaintenanceWindowScreen | M3 | push | Incidents "Maintenance" section |
| M4-01 | TasksScreen | M4 | Activity scope "Tasks" | Activity, Browse |
| M4-02 | TaskRunScreen | M4 | push | task rows anywhere, `lattice://tasks/{id}` |
| M4-03 | TaskNodeOutputScreen | M4 | push | TaskRun node rows, `lattice://tasks/{id}/nodes/{node}` |
| M4-04 | AuditScreen | M4 | Activity scope "Audit" | Activity, Browse |
| M4-05 | AuditEventScreen | M4 | push | audit rows, node activity, `lattice://audit/{id}` |
| M4-06 | CorrelationTraceScreen | M4 | push | AuditEvent trace row, `lattice://trace/{correlation}` |
| M4-07 | AuditVerifySheet | M4 | sheet (medium) | Audit toolbar |
| M5-01 | InventoryScreen | M5 | Fleet scope "Machines" | Fleet, Browse |
| M5-02 | MachineDetailScreen | M5 | push | inventory rows, NodeDetail machine row, `lattice://machines/{id}` |
| M5-03 | RenewSheet | M5 | sheet (medium) | MachineDetail, Upcoming rows, Inbox due rows |
| M5-04 | RemindersSheet | M5 | sheet (large) | Inventory toolbar |
| M5-05 | UpcomingScreen | M5 | push in Fleet > Machines | Machines header row, Inbox "All upcoming", Browse > Fleet, `lattice://upcoming` |
| M6-01 | OutboundPolicyScreen (Policies, Nodes, Matrix) | M6 | push | Browse > Networking, NodeNetwork |
| M6-02 | PolicyDetailScreen | M6 | push | policy rows, `lattice://policies/{id}` |
| M6-03 | NodePolicyScreen | M6 | push | OutboundPolicy "Nodes" rows |
| M6-04 | DNSScreen | M6 | push | Browse > Networking |
| M6-05 | DNSDeploymentScreen | M6 | push | DNS rows, `lattice://dns/{id}` |
| M6-06 | DDNSScreen | M6 | push | Browse > Networking, Inbox attention |
| M6-07 | DDNSProfileScreen | M6 | push | DDNS rows, `lattice://ddns/{id}` |
| M6-08 | GeoRoutingScreen | M6 | push | Browse > Networking |
| M6-09 | GeoRouteScreen | M6 | push | geo rows, `lattice://geo-routes/{id}` |
| M6-10 | TunnelsScreen | M6 | push | Browse > Networking |
| M6-11 | TunnelScreen | M6 | push | tunnel rows, `lattice://tunnels/{id}` |
| M6-12 | InboundFirewallScreen | M6 | push | Browse > Networking |
| M6-13 | SecurityGroupScreen | M6 | push | InboundFirewall rows |
| M7-01 | SSHGuardBoardScreen | M7 | push | Browse > Networking, Inbox attention |
| M7-02 | SSHGuardNodeScreen | M7 | push | board rows, NodeDetail SSH Guard row, `lattice://ssh-guard/{node}` |
| M7-03 | AgentUpdatesScreen (Nodes, Distribution, Mirrors) | M7 | push | Browse > Platform, NodeDetail agent row |
| M7-04 | AgentReleaseScreen | M7 | push | Distribution rows |
| M7-05 | SSHGuardArmSheet (arm and rotate) | M7 | sheet (large) | board swipe Arm, SSHGuardNode Arm and Rotate knock |
| M8-01 | PluginsScreen | M8 | push | Browse > Platform |
| M8-02 | PluginDetailScreen | M8 | push | plugin rows, trust detail, `lattice://plugins/{id}` |
| M8-03 | ExtensionPageScreen | M8 | push | Extensions rows, PluginDetail |
| M8-04 | PublishingScreen (Overview, Routes, Tokens, Buckets) | M8 | push | Browse > Platform |
| M8-05 | ShareDetailScreen | M8 | push | share rows, `lattice://shares/{id}` |
| M8-06 | BindingDetailScreen | M8 | push | route rows |
| M8-07 | StorageTokenDetailScreen | M8 | push | token rows |
| M8-08 | StoreScreen | M8 | push | Browse > Platform |
| M8-09 | StoreBucketScreen | M8 | push | store rows |
| M8-10 | StoreEntryScreen | M8 | push | bucket entries |
| M8-11 | SystemScreen | M8 | push | Browse > Platform, Inbox control-plane row |
| M8-12 | ExtensionsScreen | M8 | push | Browse > Platform > Extensions |
| M9-01 | NotificationsScreen (Routing, Sent) | M9 | push | Browse > Platform |
| M9-02 | SentLogScreen | M9 | Activity scope "Sent" and Notifications "Sent" | Activity, Inbox footer |
| M9-03 | DeliveryDetailScreen | M9 | push | Sent rows, IncidentDetail deliveries, `lattice://notify/deliveries/{id}` |
| M9-04 | ChannelDetailScreen | M9 | push | Routing rows, `lattice://notify/channels/{id}` |
| M9-05 | RuleDetailScreen | M9 | push | Routing rules |
| M9-06 | WebhooksScreen | M9 | push | Browse > Platform |
| M9-07 | WebhookDetailScreen | M9 | push | webhook rows, `lattice://webhooks/{id}` |
| M10-01 | EvidenceScreen (readiness overview) | M10 | push | Browse > Platform > Evidence |
| M10-02 | ConnectionsScreen | M10 | push | Evidence |
| M10-03 | ConnectionDetailScreen | M10 | push | connection rows, `lattice://evidence/connections/{id}` |
| M10-04 | LogExplorerScreen | M10 | push | Evidence, NodeDetail Activity "Logs" |
| M11-01 | SecurityScreen | M11 | push in the Settings sheet | Settings > Account, Browse > Settings |
| M11-02 | PasskeyDetailScreen | M11 | push in the Settings sheet | Security passkey rows |
| M11-03 | AccessScreen (Users, Tokens, SSO) | M11 | push in the Settings sheet | Browse > Settings |
| M11-04 | UserDetailScreen | M11 | push in the Settings sheet | user rows, `lattice://users/{id}` |
| M11-05 | TokenDetailScreen | M11 | push in the Settings sheet | token rows, `lattice://tokens/{id}` |
| M11-06 | SSOProviderScreen | M11 | push in the Settings sheet | SSO rows |
| M12-01 | TerminalSessionsScreen | M12 | push | Browse > Operations, NodeDetail menu |
| M12-02 | TerminalTranscriptScreen | M12 | push | session rows, `lattice://terminal/{session}` |
| M13-01 | VPNUsersScreen | M13 | push | Browse > VPN |
| M13-02 | VPNUserDetailScreen | M13 | push | user rows, `lattice://vpn/users/{id}` |
| M13-03 | VPNLinesScreen | M13 | push | Browse > VPN |
| M13-04 | VPNLineDetailScreen | M13 | push | line rows, Paths chains |

### 2.4 Typed navigation routes

Each tab owns `NavigationStack(path: $paths[tab])` where the path is `[AppRoute]`. The Settings sheet owns its own `NavigationStack(path: $settingsPath)` of `[SettingsRoute]`. `AppRoute` is a foundation-owned enum with one case per module; each case wraps a module-owned route enum. All route enums are `Hashable, Codable, Sendable`. Enums that AstraCore must also see (`NodeDetailTab`, `ApprovalsScope`, `MonitorSegment`, `FleetScope`, `ActivityScope`) are `public enum ...: String, Codable, Sendable` in `Shared/DeepLinks.swift`, so `LatticeDeepLink` can parse `?view=` without app types.

```swift
// AstraApp/App/Shell/AppRoute.swift (M0b, frozen after M0)
enum AppRoute: Hashable, Codable, Sendable {
    case inbox(InboxRoute)        // M1
    case fleet(FleetRoute)        // M2
    case monitoring(MonitoringRoute) // M3
    case activity(ActivityRoute)  // M4
    case inventory(InventoryRoute) // M5
    case networking(NetworkingRoute) // M6
    case sshGuard(SSHGuardRoute)  // M7
    case platform(PlatformRoute)  // M8
    case notify(NotifyRoute)      // M9
    case evidence(EvidenceRoute)  // M10
    case terminal(TerminalRoute)  // M12
    case vpn(VPNRoute)            // M13
}

// AstraApp/App/Shell/SettingsRoute.swift (M0b, frozen after M0)
enum SettingsRoute: Hashable, Codable, Sendable {
    case page(SettingsPage)       // M0b: connection, scopes, session, deviceSecurity, badge, display, diagnostics, demo, about
    case account(AccountRoute)    // M11, hosted only in the Settings sheet's stack
}
```

`AppRouteDestination` (M0b) is the single `navigationDestination(for: AppRoute.self)` and switches once per module to that module's destination view (`FleetDestination(route:)`, and so on). `SettingsDestination` does the same for `SettingsRoute`. Destination views live in module-owned files that M0 creates as stubs. There is no `.web` route: web-only rows are `WebLinkRow(path: LatticeConsolePath)`.

M0 declares, in each module's route file, the cases that deep links and cross-module navigation need. Modules may add cases to their own route enum but must not rename or remove the M0-declared cases.

| Route enum | M0-declared cases (minimum) |
|---|---|
| `InboxRoute` | `allAttention` (the full attention list behind "Show all"; Approvals is an Activity scope reached with `select`) |
| `FleetRoute` | `node(id: String, tab: NodeDetailTab = .overview)`, `nodeHistory(id: String)`, `nodeNetwork(id: String)`, `nodeCapabilities(id: String)`, `nodeBeacon(id: String)`, `duplicates`, `group(id: String)`, `unlocated`, `capabilityGates`, `gate(id: String)` |
| `MonitoringRoute` | `path(key: String)`, `matrix`, `chain(id: String)`, `check(id: String)`, `checkResults(id: String)`, `definition(id: String)`, `incident(id: String)`, `maintenanceWindow(id: String)` |
| `ActivityRoute` | `task(id: String)`, `taskNode(taskID: String, nodeID: String)`, `auditEvent(id: String)`, `trace(correlationID: String)` |
| `InventoryRoute` | `machine(id: String)`, `upcoming` (a pushed screen, not a scope) |
| `NetworkingRoute` | `outboundPolicy`, `policy(id: String)`, `nodePolicy(nodeID: String)`, `dns`, `dnsDeployment(id: String)`, `ddns`, `ddnsProfile(id: String)`, `geoRouting`, `geoRoute(id: String)`, `tunnels`, `tunnel(id: String)`, `inboundFirewall(nodeID: String?)`, `securityGroup(id: String)` |
| `SSHGuardRoute` | `board(posture: String?, coverage: String?)`, `node(id: String)`, `agentUpdates(view: String?, nodeID: String?)`, `agentRelease(id: String)` |
| `PlatformRoute` | `plugins`, `plugin(id: String)`, `extensions`, `extensionPage(pluginID: String, route: String)`, `publishing(view: String?)`, `share(id: String)`, `binding(id: String)`, `storageToken(id: String)`, `store`, `bucket(kind: String, name: String)`, `storeEntry(kind: String, bucket: String, key: String)`, `system` |
| `NotifyRoute` | `notifications(view: String?)`, `delivery(id: String)`, `channel(id: String)`, `rule(id: String)`, `webhooks`, `webhook(id: String)` |
| `EvidenceRoute` | `overview`, `connections(filter: String?)`, `connection(id: String)`, `logs(nodeID: String?)` |
| `AccountRoute` | `security`, `passkey(id: String)`, `access(view: String?)`, `user(id: String)`, `token(id: String)`, `ssoProvider(id: String)` |
| `TerminalRoute` | `sessions(nodeID: String?)`, `transcript(sessionID: String)` |
| `VPNRoute` | `users`, `user(id: String)`, `lines`, `line(id: String)` |

**Router.** `@MainActor @Observable final class Router` (M0b), injected with `.environment(router)` and read with `@Environment(Router.self)`. AppState, ActionRunner and ChangeLog are injected the same way; there are no custom `EnvironmentKey`s for main-actor objects.

```swift
func push(_ route: AppRoute)                                   // onto the selected tab
func select(tab: AppTab, scope: String? = nil, query: String? = nil)
func present(_ sheet: GlobalSheet)                             // Review, maintenanceStart, renew
func openSettings(_ path: [SettingsRoute] = [])
func openOnWeb(_ path: LatticeConsolePath)
```

- `select` sets the tab and, for a scoped tab, the segment. A non-nil `query` is written to `AppState.pendingQuery[scope]`; the scope root consumes it into its `.searchable` text once on appear and clears it. Count buttons ("1 failed task" goes to Tasks with `status:failed`), NodeDetail "All paths" (`source:{node}`) and directory rows use it.
- `present` first dismisses whatever is presented (the root view controller's `presentedViewController?.dismiss(animated:)`, then the global sheet state is set in the completion), so a deep link never fails silently behind an open sheet. If a write or decision is in flight (`ActionRunner.isBusy`), the request is queued, the OutcomeBanner says "Opens after the current action finishes", and it runs when the action ends.
- `openSettings` presents the Settings sheet (dismissing any other sheet first) with its stack set to `path`.

Sheets are not routes. Three sheets can be opened from outside their module, through `Router.present(_ sheet: GlobalSheet)`: `.review(ReviewTarget)` (`single(id)` or `batch(groupKey, ids)`), `.maintenanceStart(nodeID: String?)` (M3-12) and `.renew(machineID: String)` (M5-03). `Shell/GlobalSheets.swift` (M0b) maps each case to the owning module's sheet view. Every other sheet is presented by its own module, and never on top of another sheet (section 6.5).

Directory rows and count buttons that point at a tab scope (Nodes, Groups, Map, Machines, the Monitor segments, Tasks, Audit, Approvals, Sent) call `Router.select` instead of pushing, so the page always appears in one place. Those rows look different from push rows: the target tab's symbol as the trailing accessory and the secondary text "Opens in Fleet" in place of a chevron. Rows that open the Settings sheet (Security, Access, About) read "Opens in Settings".

Modules navigate across module boundaries only through the Router and `AppRoute` values. A module never references another module's views or stores; shared row views live in `Design/ObjectRows.swift` (M0b, section 8.2).

### 2.5 Deep links

Custom scheme `lattice://` now; the same paths on `https://<server>/` once a signed build has Associated Domains. `LatticeDeepLink` (AstraCore) gains one case per object. "Open on web" uses `LatticeConsolePath` builders with explicit inputs (`incident(id:query:)`, `agentUpdates(nodeName:)`), because several console routes need data an id cannot supply. The three existing links keep working unchanged.

| Object | App link | Opens | Console route ("Open on web") |
|---|---|---|---|
| Inbox | `lattice://inbox` | Inbox tab | `/` |
| Approval | `lattice://approvals/{id}` (kept) | current tab, Review sheet | `/approvals?open={id}` |
| Node | `lattice://nodes/{id}[?view=activity\|settings]` (kept) | Fleet tab, NodeDetail | `/nodes/{id}?view={view}` |
| Check | `lattice://monitors/{id}` (kept), `lattice://checks/{id}` | Monitor tab, CheckDetail | `/monitoring?view=checks&open={id}` |
| Check definition | `lattice://definitions/{id}` | Monitor tab, DefinitionDetail | `/monitoring?view=checks&open={id}` (lossy: parses back as a check; CheckDetail falls back to the definition with that id) |
| Path | `lattice://paths/{key}` with `key` from `encodePathKey`, percent-encoded | Monitor tab, PathDetail | `/monitoring?view=topology&path={key}` |
| Incident | `lattice://incidents/{id}` (a derived id `pending:<key>` is percent-encoded) | Monitor tab, IncidentDetail | `incident(id:query:)` builds `/monitoring?view=incidents&state=all&q={subject or node name}` (lands on a filtered list) |
| Maintenance window | `lattice://maintenance/{id}` | Monitor tab, MaintenanceWindow | `/monitoring?view=incidents&state=all` (lands on the list) |
| Task run | `lattice://tasks/{id}` | Activity tab, TaskRun | `/tasks?open={id}` |
| Task node output | `lattice://tasks/{id}/nodes/{nodeID}` | Activity tab, TaskNodeOutput | `/tasks?open={id}` (lossy: the node is dropped) |
| Audit event | `lattice://audit/{id}` | Activity tab, AuditEvent | `/audit?open={id}` |
| Trace | `lattice://trace/{correlationID}` | Activity tab, CorrelationTrace | `/audit?view=all&q=trace:{correlationID}` |
| Machine | `lattice://machines/{id}` | Fleet tab, MachineDetail | `/inventory?machine={id}` |
| Upcoming | `lattice://upcoming` | Fleet tab, Machines, Upcoming pushed | `/upcoming` |
| Node group | `lattice://groups/{id}` | Fleet tab, GroupDetail | `/node-groups?open={id}` |
| Outbound policy | `lattice://policies/{id}` | Browse tab, PolicyDetail | `/network/outbound?policy={id}` |
| DNS deployment | `lattice://dns/{id}` | Browse tab, DNSDeployment | `/network/dns?open={id}` |
| DDNS profile | `lattice://ddns/{id}` | Browse tab, DDNSProfile | `/network/ddns?open={id}` |
| Geo route | `lattice://geo-routes/{id}` | Browse tab, GeoRoute | `/network/geo-routing?open={id}` |
| Tunnel | `lattice://tunnels/{id}` | Browse tab, Tunnel | `/network/tunnels?open={id}` |
| SSH Guard node | `lattice://ssh-guard/{nodeID}` | Browse tab, SSHGuardNode | `/network/ssh-guard?node_id={nodeID}` |
| Agent update node | `lattice://agent-updates/{nodeID}` | Browse tab, AgentUpdates with `nodeID` | `agentUpdates(nodeName:)` builds `/platform/agent-updates?view=nodes&q={node name}` |
| Plugin | `lattice://plugins/{id}` | Browse tab, PluginDetail | `/platform/plugins?open={id}` |
| Share | `lattice://shares/{id}` | Browse tab, ShareDetail | `/platform/publishing?view=routes&origin=share&open={id}` |
| Notify channel | `lattice://notify/channels/{id}` | Browse tab, ChannelDetail | `/platform/notifications?view=routing&channel={id}` |
| Notify delivery | `lattice://notify/deliveries/{id}` | Activity tab, Sent, DeliveryDetail | `/platform/notifications?view=sent&open={id}` |
| Webhook | `lattice://webhooks/{id}` | Browse tab, WebhookDetail | `/platform/webhooks?open={id}` |
| Token | `lattice://tokens/{id}` | Settings sheet, Access, TokenDetail | `/settings/access?view=tokens` (lands on the list; the console reads no `open`) |
| User | `lattice://users/{id}` | Settings sheet, Access, UserDetail | `/settings/access?view=users` (lands on the list) |
| Terminal session | `lattice://terminal/{sessionID}` | Browse tab, TerminalTranscript | `/terminal?session_id={sessionID}` |
| VPN identity | `lattice://vpn/users/{id}` | Browse tab, VPNUserDetail | `/plugins/latticenet.vpn-core/users` (lands on the page) |
| Connection record | `lattice://evidence/connections/{id}` | Browse tab, ConnectionDetail | `/platform/evidence?view=explore&lens=connections&conn={id}` |
| Settings connection | `lattice://settings/connection` | Settings sheet, Connection | `/settings/security` (lossy) |
| Scope and segment | `lattice://fleet?scope=nodes\|groups\|map\|machines`, `lattice://monitor?segment=overview\|paths\|checks\|incidents[&view=problems\|all\|chains]`, `lattice://activity?scope=tasks\|audit\|approvals\|sent[&view=needs\|history\|stuck]`, each with optional `q=` | that tab and segment, query consumed by the scope root | the matching console list route |

`LatticeDeepLink` also parses the console's HTTPS routes, so a console link pasted into the app, shared to it, or embedded in plan text lands natively, but only when the URL's host and port equal the configured console URL's (Settings > Connection). Any other host opens in the default browser. Parsed routes: `/approvals?open=X`, `/monitoring/X` and `/monitoring?view=checks&open=X` (to a check), `/monitoring?view=topology&path=K`, `/nodes/X[?view=]`, `/tasks?open=X`, `/audit?open=X`, `/inventory?machine=X`, `/node-groups?open=X`, `/network/ssh-guard?node_id=X`, `/platform/plugins?open=X`. Unmapped console URLs open in the default browser. Taps inside Bark or another app still open Safari until Universal Links ship; the spec does not claim otherwise.

Deep-link handling rules (M0b `DeepLinkRouter`): select the owning tab, reset that tab's path to `[route]` (or call `Router.present(.review(...))` for approvals, which dismisses any open sheet first), and keep other tabs untouched. A link to an object the token cannot read opens the screen in its missing-scope state; it never fails silently. A link arriving while a write or decision is in flight is queued until it finishes. While the welcome flow is up, the link is held and applied after connection.

**Opening by id.** Most objects have no by-id endpoint (`/api/audit`, `/api/incidents`, the deliveries listing and terminal sessions take no id filter). A detail screen opened by deep link loads its owning list at the largest allowed limit and finds the object: audit `limit=100` with offset paging matched on `id` up to 10 pages (a trace uses the `correlation_id` filter directly); incidents with no `state`; deliveries `limit=200`; terminal sessions all; tasks `limit=200`. When absent it shows "Not found in the last {N}" with Open on web. Approvals use `?id=`; a 404 there reads "Not found, or not visible to this token" with a "Token scopes" button (section 6.12).

**Goldens.** App links round-trip exactly (parse then build returns the input) for every row, including ids containing `/`, `~`, `@`, `:` and spaces (`pending:` keys, path keys with `_` and `@`). Console builders are checked for the URL they build only. Console parsing is checked only for the HTTPS routes listed above, with definitions documented as parsing to a check, and with a foreign host checked to return nil.

### 2.6 State restoration

- The selected tab is `@SceneStorage("shell.root.tab")`. Every `@SceneStorage` key is namespaced `<module>.<screen>.<field>` (`fleet.nodes.query`, `monitor.root.window`), and the key strings are `static let` constants in the owning file so a grep finds collisions.
- Each tab's `[AppRoute]` is encoded as JSON `Data` into `@SceneStorage("shell.path.<tab>")` on change and decoded on launch. A decode failure (for example after a route enum change) resets that tab to its root without an error.
- The scope segment of Fleet, Monitor and Activity, the Monitor window (`1h` to `14d`), and each list's search text persist, with two exceptions that always start broad: the Inbox filter is All on every launch, and incident and SSH Guard filters reset to their broadest scope. While a list is filtered it shows a visible row ("Showing approvals only. Show all") and the filter in `.navigationSubtitle`.
- The Review sheet persists only its target id (`@SceneStorage("inbox.review.target")`). On relaunch it reopens by loading the approval by id again and re-hashing. A decision is never restored: a decision interrupted by termination is unknown, so the sheet reloads by id and shows the server's state.
- Browse's recently opened pages (up to 6) persist in `UserDefaults` (not secret).
- Nothing secret is ever restored: no revealed values, no step-up grants, no session, no draft credentials.
- `@SceneStorage` is saved only when the scene goes to the background. The restoration check therefore runs: deep link to NodeDetail, `xcrun simctl launch <udid> com.apple.Preferences` (backgrounds Lattice), `xcrun simctl terminate <udid> org.roobli.astra`, relaunch, and confirm NodeDetail is on top.

---

## 3. Parity matrix

Modes: **N** native read or non-mutating action; **N-T1, N-T2, N-T3, N-T4** native write at that tier; **N-P** native plan filing (the approval is the gate); **N-D** native decision; **N-S** native with session step-up; **W** "Open on web" at the exact console route (with the object open where the console supports it). Two modes joined by "+" run both gates in order. Tiers are defined in section 6.5.

Every page in `console-inventory.md` section 1 and every action in section 2 appears below. Plugin pages from section 4 and shell features are at the end.

### 3.1 Pages (read side)

| Console page | Console route | Phone home | Read mode | Notes |
|---|---|---|---|---|
| Overview | `/` | Inbox | N | Verdict line, incidents, needs you, attention (including a "Recent changes" row to Audit), due soon, the four counts as buttons |
| Nodes | `/nodes` | Fleet > Nodes | N | Grouped list, query grammar, duplicate report as a banner |
| Node detail | `/nodes/:id` | Fleet > NodeDetail | N | Overview, Activity, Settings, matching `?view=` |
| Node groups | `/node-groups` | Fleet > Groups | N | Member health, Used by |
| Map | `/map` | Fleet > Map | N | MapKit, status annotations, latency arcs toggle (`layer=latency`) |
| Inventory | `/inventory` | Fleet > Machines | N | Grouped by region/country/role/group/status/tag, spend, renewals |
| Upcoming | `/upcoming` | Fleet > Machines > Upcoming (pushed), Inbox "Due soon" | N | One list of renewals, VPN users, shares, TLS certificates |
| Monitoring overview | `/monitoring?view=overview` | Monitor > Overview | N | Health and degraded verdicts |
| Monitoring topology | `/monitoring?view=topology` | Monitor > Paths (list, chains, matrix) | N | Force graph is W ("Graph on web" in the view menu) |
| Monitoring checks | `/monitoring?view=checks` | Monitor > Checks | N | Checks, definitions, results, series |
| Monitoring incidents | `/monitoring?view=incidents` | Monitor > Incidents | N | Incidents by state, maintenance windows |
| Approvals | `/approvals` | Inbox (needs you), Activity > Approvals (needs, history, stuck) | N | Rows filtered by the server per token (6.12); hidden plugins are named; custom range filters `until` on device |
| Tasks | `/tasks` | Activity > Tasks | N | Runs, per-node results, output |
| Terminal | `/terminal` | Browse > Operations > Terminal | N | Session list and read-only transcript |
| Audit | `/audit` | Activity > Audit | N | Changes, all, integrity; correlation trace |
| Outbound policy | `/network/outbound` | Browse > Networking | N | Policies, per-node, matrix as a list |
| Self-host DNS | `/network/dns` | Browse > Networking | N | Deployments, drift, certificate watch, publish errors |
| DDNS | `/network/ddns` | Browse > Networking, Inbox attention | N | Current, failing, stale |
| Geo-Routing | `/network/geo-routing` | Browse > Networking | N | Routes, DNS nodes, preview config |
| Tunnels | `/network/tunnels` | Browse > Networking | N | Profiles and ingress |
| SSH Guard | `/network/ssh-guard` | Browse > Networking, NodeDetail row, Inbox attention | N | Posture and coverage board |
| Plugins | `/platform/plugins` | Browse > Platform | N (`audit:read`) | Health, capabilities, risk, contributions; Extensions list |
| Publishing | `/platform/publishing` | Browse > Platform | N | Overview, routes, tokens, buckets, shares |
| Store | `/platform/store` | Browse > Platform | N | Buckets, KV keys and static objects (values on tap, never cached) |
| Evidence | `/platform/evidence` | Browse > Platform > Evidence | N | Overview (readiness), connections, logs. The Collection layer is W |
| Notifications | `/platform/notifications` | Browse > Platform; Sent also in Activity | N | Routing (channels, rules, witness), Sent log |
| Webhooks | `/platform/webhooks` | Browse > Platform | N | Webhooks, deliveries, "reaches nobody" |
| Agent Updates | `/platform/agent-updates` | Browse > Platform, NodeDetail agent row | N | Nodes, Distribution, Mirrors |
| System | `/platform/system` | Browse > Platform, Inbox control-plane row | N (needs `*`) | Read only |
| Plugin page (core) | `/plugins/:pluginId/:route*` | see 3.3 | per plugin | |
| Security & 2FA | `/settings/security` | Settings sheet > Security (Browse row opens it) | N | 2FA state, passkeys |
| Capability Gates | `/settings/capabilities` | Browse > Settings > Capability Gates | N | Each gate and what it would refuse |
| Access | `/settings/access` | Settings sheet > Access (Browse row opens it) | N | Users, tokens, SSO providers |
| Appearance | `/settings/appearance` | none | n/a | The phone follows system appearance, Increase Contrast and Dynamic Type; no app setting |
| About | `/settings/about` | Settings > About | N | Server build from `/api/version` against app version and compatibility |
| Login | `/login` | WelcomeFlow, Settings > Connection | N | PAT, password plus TOTP |

### 3.2 Write actions

| Page | Action | Endpoint | Scope | Mode | Reason |
|---|---|---|---|---|---|
| Overview | Acknowledge incident | `POST /api/incidents/ack` | monitor:admin | N-T1 | Tier 1 job; the row names the incident; verified inverse (unack) |
| Overview | Snooze incident | `POST /api/incidents/snooze` | monitor:admin | N-T1 | Tier 1; verified inverse (`minutes: 0`) |
| Nodes | Enroll node | `POST /api/nodes/enroll-token` | node:admin | W | The install command is pasted on a host; a credential should not land on the phone |
| Nodes | Disable node | `POST /api/nodes/disable` | node:admin | N-T3 | Quarantine at 2am. Copy: "edge-tyo-3 can no longer authenticate: it stops reporting and receives no plans or tasks. Services on it keep running." The recommended phone response to a leaked node token |
| Nodes | Enable node | `POST /api/nodes/disable` (`disabled:false`) | node:admin | N-T2 | Restores service; confirmation names the node |
| Nodes | Bulk disable | `POST /api/nodes/disable` per node | node:admin | N-T3 | Edit mode in Nodes; one confirm sheet lists every node; per-node outcomes |
| Nodes | Bulk enable | `POST /api/nodes/disable` (`disabled:false`) per node | node:admin | N-T2 | Edit mode; dialog names the count; per-node outcomes |
| Nodes | Rotate token | `POST /api/nodes/rotate-token` | node:admin | N-T3 | NodeDetail Settings only, never the Nodes context menu. The server replaces the hash at once and returns the new token with no step-up; copy: "edge-tyo-3 stops reporting and receives no plans until the new token is installed on the host. You cannot do that from this iPhone." The token shows once in F-14 with Copy only (no Share) and "Reconfigure on web". Disable is the recommended leak response |
| Nodes | Open terminal | `POST /api/terminal/sessions` | terminal:open | W | Root shell; typing stays on the web |
| Node detail | Edit identity (name, tags, role) | `POST /api/nodes/update` | node:admin | N-T2 | Short form |
| Node detail | Capability enroll or exclude | `POST /api/nodes/capabilities` | node:admin | N-T3 | Changes what the node admits |
| Node detail | Geo set | `POST /api/nodes/geo` | node:admin | W | Needs a location picker and city fields |
| Node detail | Geo clear | `POST /api/nodes/geo` | node:admin | N-T2 | One field |
| Node detail | Geo resolve | `POST /api/nodes/geo/resolve` | node:admin | N-T2 | One tap, names the node |
| Node detail | IP-discovery override | `POST /api/nodes/ip-config` | node:admin, network:plan | W | Network input with lockout risk |
| Node detail | Agent debug | `POST /api/nodes/debug` | node:admin | N-T2 | Investigation aid on the go |
| Node detail | Generate reconfigure command | `POST /api/nodes/reconfigure-command` | node:admin | W | Credential-bearing command for a host |
| Node detail | Rotate token | `POST /api/nodes/rotate-token` | node:admin | N-T3 | As in Nodes (this is where it lives) |
| Node detail | Delete node | `POST /api/nodes/delete/plan` then `/delete {node_id}` | node:admin | N-T4 | The dry run lists every non-zero counter of `nodeDeleteSummary` (DNS deployments, net policies, geo routes, tunnels, DDNS and machine profiles, approvals, managed lines, line-chain definitions, monitors, logs, metrics, tasks, capabilities, group membership); `/delete` is not bound to it, so the plan is re-run right before sending and a change stops the write; typed node name when DNS, geo, tunnel or line dependencies exist; 409 line-chain conflict mapped; `log_store_purge_errs > 0` is partial |
| Node detail | Auto-update policy | `POST /api/nodes/agent-updates` | node:admin | W | Policy form |
| Node detail | Agent update plan, force plan | `POST /api/nodes/agent-updates/plan` | node:admin, network:plan | N-P | Approval gates it |
| Node detail | Beacon plan | `POST /api/nodes/beacon/plan` `{node_id, action, port?, bind?, endpoint?}` | monitor:admin, node:admin, network:plan (+ netguard:admin when the plan carries a NetGuard companion) | N-P | `action` is `enable`, `disable` or `change` per entry point; 409 findings loop |
| Node detail | Beacon rotate | `POST /api/nodes/beacon/rotate` | monitor:admin, node:admin | N-T3 | Direct key change |
| Node groups | Create or edit (selector or members) | `POST /api/groups` | group:admin | W | Selector authoring |
| Node groups | Preview selector | `POST /api/groups/preview` | group:read | W | Part of authoring |
| Node groups | Add or remove static members | `POST /api/groups/members` | group:admin | N-T2 | Static groups only; the dialog names the group and the nodes |
| Node groups | Delete | `POST /api/groups/delete` | group:admin | N-T4 | Shows Used by first |
| Node groups | Reorder, seed | `/api/groups/reorder`, `/seed` | group:admin | W | Desk work |
| Map | Locate missing nodes | `POST /api/nodes/geo/resolve` (`missing_only`) | node:admin | N-T2 | Lists how many nodes it will touch |
| Inventory | Create or edit machine profile | `POST /api/machines`, `/update` | inventory:admin | W | Long form (vendor, price, cycle, links) |
| Inventory | Delete machine | `POST /api/machines/delete` | inventory:admin | N-T4 | Irreversible |
| Inventory | Renew | `POST /api/machines/renew` | inventory:admin | N-T2 | Frequent on the go |
| Inventory | Upsert vendor | `POST /api/machine-vendors` | inventory:admin | W | Form |
| Inventory | Delete vendor | `POST /api/machine-vendors/delete` | inventory:admin | W | Rare desk work |
| Inventory | Preview then send reminders | `POST /api/machines/reminders/run` | inventory:admin | N-T2 | Preview list shown before send |
| Inventory | Reveal console or detail link | `POST /api/machines/reveal-link` | inventory:admin + step-up | N-S | Rebooting a VPS from the provider console is a 2am job |
| Upcoming | Record renewal | `POST /api/machines/renew` | inventory:admin | N-T2 | Same sheet as Inventory renew |
| Monitoring | Check create or edit | `POST /api/monitors`, `/update` | monitor:admin | W | Authoring |
| Monitoring | Check pause or resume | `POST /api/monitors/update` `{id, version, enabled}` | monitor:admin | N-T2 | Sends the version that was read; 409 `ErrMonitorVersion` reloads and re-shows; generated checks refuse (`ErrMonitorManaged`), so the action is hidden on them with "Generated by definition {name}: change it on web" |
| Monitoring | Check delete | `POST /api/monitors/delete` | monitor:admin | N-T4 | Irreversible, loses history; hidden on generated checks |
| Monitoring | Definition create, update, preview | `/api/monitors/definitions[/update\|/preview]` | monitor:admin | W | Authoring |
| Monitoring | Definition delete | `POST /api/monitors/definitions/delete` `{id, version, monitor_ids}` | monitor:admin | N-T4 | Irreversible; `monitor_ids` must equal the definition's current monitors, every one listed in the sheet with its history |
| Monitoring | Definition forget | `POST /api/monitors/definitions/forget` | monitor:admin | W | Rare, needs context the console gives |
| Monitoring | Latency probe plan | `PUT /api/monitors/latency` | monitor:admin | W | Pair-set editing |
| Monitoring | Retention | `POST /api/monitors/settings/update` | monitor:admin | W | Desk setting |
| Monitoring | Beacon replan | `POST /api/nodes/beacon/plan` (`action: change`) | monitor:admin, node:admin, network:plan | N-P | From path detail |
| Monitoring | Incident ack, unack, snooze, end snooze | `/api/incidents/ack\|unack\|snooze` | monitor:admin | N-T1 | Swipes and detail toolbar |
| Monitoring | Maintenance window start now (presets) | `POST /api/maintenance-windows` `{name, node_ids or group_ids, starts_at, ends_at, reason?}` | monitor:admin | N-T2 | Name prefilled and editable; 30 min, 1 h, 4 h, until a time; `ends_at` in the future and at most 30 days after start; copy "Incidents for {node} are held and no alerts are sent until {time}." |
| Monitoring | Maintenance window end | `POST /api/maintenance-windows` (full window, `ends_at` now) | monitor:admin | N-T2 | Re-sends the stored window unchanged except `ends_at`, because the upsert validates every field |
| Monitoring | Maintenance window delete | `POST /api/maintenance-windows/delete` | monitor:admin | N-T2 | Dialog names the window |
| Monitoring | Maintenance window edit | `POST /api/maintenance-windows` | monitor:admin | W | Scheduling form |
| Approvals | Approve and apply | `POST /api/network/approvals/approve` `queue_apply:true` | network:apply + plugin decision scope | N-D | Core phone job |
| Approvals | Approve without applying | same, `queue_apply:false` | same | N-D | Visible "Apply after approval" toggle turned off ("Approve only") |
| Approvals | Reject | `POST /api/network/approvals/reject` | same | N-D | |
| Approvals | Dismiss | `POST /api/network/approvals/dismiss` `{approval_id, note}` | same | N-D | Gated by `canDismiss` (server `waiting.dismissible` first); 409 `approval_stale` here means not dismissible |
| Approvals | Batch approve or reject | the same endpoints per id | same | N-D | One event group, every body hashed and on screen, one Face ID, every transition verified |
| Approvals | Replan stale agent update | `POST /api/nodes/agent-updates/plan` | node:admin, network:plan | N-P | From a stale row in Review |
| Tasks | Create script task | `POST /api/tasks` | task:run | W | Script authoring is desk work and runs as root on N nodes |
| Tasks | Rerun | `POST /api/tasks/rerun` | task:run | N-T3 | Re-executes on every target |
| Tasks | Rerun one node | `POST /api/tasks/rerun-node` `{id, node_id}` | task:run | N-T3 | Swipe on a node row; "Rerun failed nodes" is sequential calls with per-node outcomes, each a separate task run |
| Tasks | Cancel | `POST /api/tasks/cancel` | task:run | N-T2 | Stops pending work |
| Tasks | Delete | `POST /api/tasks/delete` | task:run | N-T4 | Irreversible |
| Tasks | Reveal script | `POST /api/tasks/reveal-script` | task:read + step-up | N-S | Investigation |
| Terminal | Create session | `POST /api/terminal/sessions` | terminal:open | W | Root shell |
| Terminal | Type, resize, attach | `/input`, `/resize`, WebSocket `/attach` | terminal:open | W | A good terminal is its own project |
| Terminal | Close session | `POST /api/terminal/sessions/{id}/close` | terminal:open | N-T2 | Clean up a forgotten session |
| Audit | Verify chain | `GET /api/audit/verify` | audit:read | N | Non-mutating |
| Audit | Export CSV, NDJSON, head | built on device from `/api/audit` | audit:read | N | `ShareLink`; NDJSON from each event's raw JSON slice, CSV as the console builds it; pages to the end of the range; partial scans labelled |
| Outbound policy | Group policy upsert or delete | `POST /api/group-policies[/delete]` | netpolicy:admin | W | Rule authoring |
| Outbound policy | Plan all group policies | `POST /api/group-policies/plan` `{}` | netpolicy:admin | N-P | Plans every node covered by any enabled group policy; no dry run, so the sheet lists covered nodes as "will try" and the result lists filed approvals, conflicts and orphans (`GroupPolicyPlanResult`) |
| Outbound policy | Edit node policy | `POST /api/netpolicy` | netpolicy:admin | W | Rule authoring |
| Outbound policy | Plan node policy | `POST /api/netpolicy/plan` | netpolicy:admin | N-P | |
| Outbound policy | Convert manual policy | `POST /api/netpolicy/convert` `{target_node_id, name?, priority?}` | netpolicy:admin | N-T3 + P | Creates group policy {name} directly, then files a plan (`{group_policy, approval or null}`); the ConfirmSheet says both |
| Self-host DNS | Deployment upsert or delete | `POST /api/dns/deployments[/delete]` | dns:admin | W | Form |
| Self-host DNS | Plan | `POST /api/dns/plan` (`accept_lockout_risk`) | dns:admin | N-P | 409 lockout findings listed; acceptance is an explicit toggle |
| Self-host DNS | Publish IPs to the provider | `POST /api/dns/publish` `{id}` | dns:admin | N-T3 | Failover; writes the external provider; no server preview, so the sheet shows one computed on device and labelled ("Will publish the node's current address {ip}; the provider has {last_ipv4}"); hidden for external-engine or disabled deployments |
| Self-host DNS | Measure certificate | `POST /api/dns/measure-cert` | dns:admin on the node, monitor:admin on a token without a node allowlist | N-T2 | "Creates a TLS check on {host}:{port} and links it to {deployment}"; marks checks dirty |
| DDNS | Save profile | `POST /api/ddns` | ddns:admin | W | Form |
| DDNS | Delete | `POST /api/ddns/delete` | ddns:admin | N-T4 | Irreversible |
| DDNS | Run now | `POST /api/ddns/run` | ddns:admin | N-T3 | Writes the external DNS provider, like DNS publish; the sheet names profile and record with an on-device preview of the address |
| Geo-Routing | Upsert | `POST /api/geo-routing` | geo:admin | W | Form |
| Geo-Routing | Delete | `POST /api/geo-routing/delete` | geo:admin | N-T4 | Irreversible |
| Geo-Routing | Preview config | `POST /api/geo-routing/plan` (preview) | geo:read | N | Read |
| Tunnels | Create | `POST /api/tunnels` | tunnel:admin | W | Form |
| Tunnels | Delete | `POST /api/tunnels/delete` | tunnel:admin | N-T4 | Irreversible |
| Tunnels | Plan | `POST /api/tunnels/plan` | tunnel:admin | N-P | |
| SSH Guard | Arm | `POST /api/sshguard/plan` `{node_id, ssh_port, enable_knock?, mgmt_sources?, confirm_window_sec?, out_of_band_fallback?, accept_findings?}` | sshguard:admin (+ network:plan per node) | N-P | SSHGuardArmSheet (M7-05): defaults prefilled and shown field by field; 409 lint findings with an unchecked "Accept findings" |
| SSH Guard | Confirm (cancels automatic revert) | `POST /api/sshguard/confirm` | same | N-P | Time-critical; countdown to `revert_deadline` in Inbox; when `actionable_approval_id` is set, opens that approval in Review instead of filing again |
| SSH Guard | Reveal knock sequence | `POST /api/sshguard/knock/reveal` | sshguard:read + network:plan on the session, step-up | N-S | |
| SSH Guard | Rotate knock | knock state `POST /api/sshguard/knock`, S reveal of the digest when needed, then `POST /api/sshguard/plan` with `rotate_from_sha256` | sshguard:admin (+ network:plan) | N-P (+ S) | SSHGuardArmSheet in rotate mode; ports `rotateEligibility` and `buildRotationRequest` |
| SSH Guard | Exclude a node via capability | `POST /api/nodes/capabilities` | node:admin | N-T3 | |
| Plugins | Lifecycle activate or disable | `POST /api/plugins/lifecycle` | plugin:admin | N-T3 | Stop a misbehaving plugin |
| Plugins | Lifecycle verified to installed | `POST /api/plugins/lifecycle` | plugin:admin | W | Part of the install ceremony |
| Plugins | Verify uploaded bundle | `POST /api/plugins/verify` | plugin:verify | W | Needs a file upload |
| Publishing | Delete binding | `POST /api/storage/bindings/delete` | kv:write or static:write | N-T4 | Leak response |
| Publishing | Revoke storage token | `POST /api/storage/tokens/revoke` | kv:write or static:write | N-T4 | Leak response |
| Publishing | Share create | `POST /api/subscription-shares` | proxy:admin | W | Form |
| Publishing | Share edit expiry or interval | `PATCH /api/subscription-shares/{id}` | proxy:admin | W | Form |
| Publishing | Share rotate | `POST /api/subscription-shares/{id}/rotate` | proxy:admin | N-T3 | Leak response; old URL stops working |
| Publishing | Share refresh | `POST /api/subscription-shares/{id}/refresh` | proxy:admin | N-T2 | |
| Publishing | Share delete | `DELETE /api/subscription-shares/{id}` | proxy:admin | N-T4 | |
| Publishing | Reveal share URL | `POST /api/subscription-shares/{id}/reveal` | proxy:admin + step-up | N-S | |
| Publishing | Create bucket, binding, token | `/api/storage/{buckets,bindings,tokens}` | kv/static write | W | Form; token shown once |
| Store | Put KV entry or static object | `POST /api/kv`, `/api/static` | kv:write, static:write | W | Long input or file |
| Store | Delete entry | `/api/kv/delete`, `/api/static/delete` | kv:write, static:write | W | Desk work |
| Evidence | Start capture session | `POST /api/trace/sessions` `{name, filter, level, ttl_seconds}` | log:read | N-T2 | Name "phone {node} {time}", filter on that node, the console's default level, `ttl_seconds` from the preset; "Records connection metadata for users on {node} for {duration}" |
| Evidence | Stop capture session | `POST /api/trace/sessions/stop` | log:admin | N-T2 | |
| Evidence | Trace policy | `/api/trace/policy` | log:admin | W | Policy form |
| Evidence | Log sources | `/api/logs/sources[/delete]` | log:admin | W | Form |
| Evidence | Evidence budgets | `/api/evidence/settings` | `*` | W | Admin settings |
| Notifications | Channel upsert | `POST /api/notify/channels` | notify:admin | W | Form with secrets |
| Notifications | Channel delete | `POST /api/notify/channels/delete` | notify:admin | N-T4 | |
| Notifications | Channel test | `POST /api/notify/channels/test` | notify:admin | N-T2 | "Did the alert path work" from the phone |
| Notifications | Test send | `POST /api/notify/test` | notify:send | W | The phone must never hold `notify:send` |
| Notifications | Rule upsert or delete | `/api/notify/rules[/delete]` | notify:admin | W | Routing authoring |
| Notifications | Witness plan | `POST /api/notify/witness/plan` | notify:admin | N-P | |
| Webhooks | Create, edit, rotate secret | `/api/notify/webhooks[/rotate]` | notify:admin | W | Secret shown once belongs at a desk |
| Webhooks | Delete | `POST /api/notify/webhooks/delete` | notify:admin | N-T4 | |
| Webhooks | Test | `POST /api/notify/webhooks/test` | notify:admin | N-T2 | |
| Agent Updates | Policy upsert or delete | `/api/nodes/agent-updates[/delete]` | node:admin | W | Policy form |
| Agent Updates | Plan one node or all behind | `POST /api/nodes/agent-updates/plan` `{node_id, force}` per node | node:admin, network:plan | N-P | All behind is sequential single-node POSTs; the sheet lists "will try"; per-node 409s are the refused half; the filed group opens in BatchReview |
| Agent Updates | Artifacts import or delete | `/api/nodes/agent-updates/artifacts/*` | node:admin | W | File handling |
| Agent Updates | Mirror plan | `POST /api/nodes/agent-updates/mirrors/plan` | node:admin, network:plan | W | Registry editing precedes it |
| System | none | | | | Read only |
| Security | Change password | `POST /api/auth/password` | session | W | |
| Security | TOTP enroll, activate, disable | `/api/2fa/totp/*` | session | W | Enrollment shows a secret and recovery codes |
| Security | Passkey add | `/api/security/webauthn/register/*` | session | W | Needs Associated Domains |
| Security | Passkey rename | `/api/security/webauthn/credentials/rename` | session | N-T2 | Needs a session credential |
| Security | Passkey delete | `/api/security/webauthn/credentials/delete` | session + step-up when TOTP is on | N-T4 + S | Needs a session credential |
| Capability Gates | Toggle enforced | `POST /api/capabilities` | node:admin | N-T3 | Sheet shows what turning it on would refuse |
| Access | User create, update, delete | `/api/users[/update\|/delete]` | user:admin | W | Identity administration is desk work |
| Access | Token create | `POST /api/tokens` | token:admin | W | Secret shown once |
| Access | Token revoke | `POST /api/tokens/revoke` | token:admin | N-T4 | Leak response |
| Access | Token delete | `POST /api/tokens/delete` | token:admin | N-T4 | |
| Access | OIDC provider upsert, delete, test | `/api/auth/oidc/providers[/delete\|/test]` | oidc:admin | W | Form with client secrets |
| Login | Password plus TOTP, PAT, sign out | `/api/login`, `/api/login/totp`, `/api/logout` | public | N | |

### 3.3 Plugin pages and shell features

| Surface | Phone home | Read | Writes |
|---|---|---|---|
| vpn-core Lines (`latticenet.vpn-core`) | Browse > VPN > Lines; chain health also in Monitor > Paths > Chains | N via `POST /api/plugins/call` | Chain plan, remove plan, managed rollout: W |
| vpn-core Users | Browse > VPN > Users | N via `callPlugin` (`latticenet.vpn-core/users`, `list`, `get`) and `/api/proxy/users` | Reveal subscription link (`POST /api/vpn/users/{id}/link/reveal`, vpncore:admin): N-S with Share; reveal credentials (`/api/proxy/users/reveal-credentials`, proxy:admin): N-S; link rotate (`POST .../link/rotate`, "the old link stops working at once"): N-T3; link revoke (`DELETE .../link`): N-T4; create, bind, cutover: W |
| vpn-core Node Profiles | Browse > VPN | W | W |
| vpn-core Usage, outbound probe | Browse > VPN | W | W (`vpn:probe`) |
| Sub-Store (`latticenet.sub-store`) | Browse > VPN | W | W. Plans it files (`plans.propose`) arrive in Inbox like any approval |
| Inbound firewall (`latticenet.netguard`) | Browse > Networking > Inbound firewall | N via `/api/netguard/{groups,zones,nodes}` (netguard:read) and `/bindings`, `/node-group-bindings` (netguard:admin); NodeNetwork links to it filtered by node | All writes, adoption and plans: W |
| WireGuard mesh (`latticenet.wireguard`) | Browse > Networking | W | W |
| Third-party plugin pages | Browse > Platform > Extensions | Table and detail kinds drawn natively from the manifest (`PluginView.vue` model); sandboxed iframe pages: W | Form kind: W |
| Command palette | Browse tab | N | Palette batch-approve of system events maps to BatchReviewSheet |
| Plugin trust (`/api/plugin-trust`) | Inbox trust row (opaque), TrustDetail | N | none |
| Recent errors panel | Settings > Diagnostics | N | none |
| Sidebar badges | Inbox tab badge and app icon badge | N | none |
| Appearance (theme, palette, language) | iOS settings | n/a | The app follows the system and ships English; the console's zh-CN locale is out of v3 scope |

---

## 4. Design system

All tokens live in `AstraApp/App/Design/` (M0). Colors are asset-catalog color sets with Any, Dark, and High Contrast variants, exposed as `Color` statics in `Tokens.swift`. Views never use raw hex or `Color.green` and friends directly.

### 4.1 Semantic color tokens

Contrast targets, checked by M0 against every background colored text can sit on: light cells `#FFFFFF` and light grouped background `#F2F2F7` (section footers); dark base cells `#1C1C1E` and dark elevated cells `#2C2C2E` (sheets such as Review and ConfirmSheet). Text tokens reach 4.5:1 on all four; Increase Contrast text tokens reach 7:1 on all four. Fill tokens are for glyphs, chart marks and swatches; they reach 3:1 against the same backgrounds and always appear with a word or a distinct shape, so color is never the only signal. White labels on `accent.fill` reach 4.5:1 in every variant. System label colors (`label`, `secondaryLabel`) are accepted as Apple ships them and adapt under Increase Contrast; this spec does not claim they reach 4.5:1 (light `secondaryLabel` is about 3.4:1 on white), so state words never rely on them alone: every state word also has its own symbol.

| Token | Light | Dark | Light, Increase Contrast | Dark, Increase Contrast | Use |
|---|---|---|---|---|---|
| `accent.text` | `#2F5BEA` | `#7C9BFF` | `#1A3DB8` | `#A3BAFF` | Tinted text, links, selection, the primary chart series. Never a status. |
| `accent.fill` | `#2F5BEA` | `#2F5BEA` | `#1A3DB8` | `#2F5BEA` | Background of prominent buttons only (white label 5.52:1, 8.74:1 in Light Increase Contrast). Set as the tint of `.glassProminent` and `.borderedProminent`. |
| `destructive.fill` | `#D70015` | `#D70015` | `#A00010` | `#D70015` | Background of the T4 destructive button. System red under a white label is about 3.5:1; this reaches 4.5:1 in every variant. |
| `status.ok.fill` | `#248A3D` | `#30D158` | `#1B6B30` | `#30DB5B` | Healthy glyphs, ok chart marks and strip cells |
| `status.ok.text` | `#1F7A35` | `#30D158` | `#145A26` | `#5BE37D` | Rarely used: "resolved", "applied" words on detail screens |
| `status.warn.fill` | `#C93400` | `#FF9F0A` | `#A12A00` | `#FFB340` | Degraded, stale, stalled, reverting glyphs; loss bars on a degraded path; trigger rule |
| `status.warn.text` | `#B25000` | `#FF9F0A` | `#803800` | `#FFB340` | Warning words and reason lines |
| `status.fail.fill` | `#E0281E` | `#FF453A` | `#B8000F` | `#FF6961` | Offline, down, failed, open critical glyphs |
| `status.fail.text` | `#D70015` | `#FF7A72` | `#A00010` | `#FFA39E` | Failure words and reason lines (dark 5.49:1 on `#2C2C2E`, Dark Increase Contrast 7.29:1) |
| `status.quiet` | system `secondaryLabel` | system | system | system | Acknowledged, snoozed, held, pending, never reported, unknown, queued, cancelled, and off states (disabled, paused, excluded). Always paired with the state's own symbol. |
| `chart.band` | `secondaryLabel` at 12% | at 18% | at 20% | at 26% | Maintenance windows on charts |
| `chart.compare` | `secondaryLabel` | system | system | system | Previous window series (long dash `[6, 3]`, directly labelled "previous") |
| Backgrounds | `systemGroupedBackground`, `secondarySystemGroupedBackground` | system | system | system | Lists and sheets. No custom backgrounds. |
| Separators | system `separator` | system | system | system | |

There is no `status.off` token: off states use `status.quiet` with their own symbol, and no state word uses `tertiaryLabel`.

Rules:

- Health is quiet. A healthy row colors only its glyph (`status.ok.fill`); its word is `secondaryLabel`. A problem row colors glyph and word (the `.text` token for the word).
- The accent must never sit next to a status meaning. Acknowledged and snoozed incidents, "waiting" approvals and running tasks use `status.quiet` plus their own symbol, never blue.
- M0's `ContrastChecks` (AstraCoreCheck, from the hex values in this table, mirrored in `Tokens.swift`) asserts every text token against the four backgrounds, every fill against them at 3:1, and white on `accent.fill` at 4.5:1 in all four variants.
- Before M0 merges, the accent and the status fills are checked through the demo color filter (`-AstraColorFilter grayscale|deuteranopia`, section 9.2): every status must stay distinguishable by shape, and a tinted button must not read as "online". M0 also attaches dark plus Increase Contrast screenshots of the Review toolbar panel and the ConfirmSheet.

### 4.2 Status vocabulary

Every state renders as symbol + word, with color as a third channel. Symbols use `.symbolRenderingMode(.hierarchical)` except where noted. VoiceOver phrases are the exact strings to use (localization keys may wrap them). `{age}` is a relative duration ("12 minutes"), `{time}` a clock time in the chosen zone formatted per 6.16. "off" states use `status.quiet` with their own symbol.

`StatusStyle` (M0b) maps only the Shared display-state enums of `DisplayStates.swift` (`NodeHonesty`, `PathDisplayState`, `IncidentDisplayState`, `TaskRunState`, `ApprovalDisplayState`, `SSHGuardCoverage`); domain models expose a `displayState`, so M0 can finish the vocabulary and the StatusSampler before any module exists.

**Node honesty** (server `status`; `NodeStatus` in the console)

| Server value | Word | Symbol | Color | VoiceOver |
|---|---|---|---|---|
| `online` | online | `checkmark.circle.fill` | `status.ok.fill` glyph, quiet word | "{name}, online, seen {age} ago" |
| `degraded` | degraded | `exclamationmark.triangle.fill` | warn | "{name}, degraded, {reason}" |
| `offline` | offline | `xmark.octagon.fill` | fail | "{name}, offline for {age}" |
| `never_reported` | never reported | `circle.dashed` | quiet | "{name}, never reported" |
| `disabled` | disabled | `minus.circle` | quiet | "{name}, disabled, cannot authenticate" |

An offline node keeps its last facts with "Last reported 3 h ago" and hides live metrics instead of showing zeros.

**Path state** (`pathsModel.ts`: `up`, `down`, `degraded` only when the server sends `degraded_at`, otherwise `unknown` with a reason)

| State | Word | Symbol | Color | VoiceOver |
|---|---|---|---|---|
| `up` | up | `arrow.right.circle.fill` | ok glyph, quiet word | "{source} to {target}, up, {p50} milliseconds" |
| `degraded` | degraded | `exclamationmark.triangle.fill` | warn | "{source} to {target}, degraded, {reason sentence}, since {time}" |
| `down` | down | `xmark.circle.fill` | fail | "{source} to {target}, down since {time}" |
| `unknown`, pause reason (`path_paused`, `path_set_paused`, `check_paused`, `source_paused`, `packet_budget`) | paused | `pause.circle` | quiet | "{source} to {target}, paused, {reason sentence}" |
| `unknown`, any other reason | unknown | `questionmark.circle` | quiet | "{source} to {target}, unknown, {reason sentence}" |

Reason words (AstraCore `PathReason.sentence(for:)`, aliases resolved as in `pathsModel.ts`): `agent_offline` "source offline"; `source_unavailable` "source unavailable"; `not_probeable` "cannot be probed"; `no_data` "no data yet"; `no_tcp_line` "no TCP line"; `udp_only` "UDP only"; `no_public_address` "no public address"; `no_inventory` "not in inventory"; `no_results` "no results"; `results_stopped` "results stopped"; `agent_too_old` "agent too old"; `icmp_not_permitted` "ICMP not permitted"; `destination_refused` "destination refused"; `method_refused` "method refused"; `icmp_filtered` "ICMP filtered"; `beacon_not_enabled` "beacon not enabled"; `firewall_pending` "firewall change pending"; `beacon_source_pending` "beacon source pending"; `refused_by_node` "refused by the node"; `beacon_not_listening` "beacon not listening"; `beacon_filtered` "beacon filtered"; `beacon_stale` "beacon stale"; `beacon_unknown_epoch` "beacon epoch unknown"; `beacon_rate_limited` "beacon rate limited"; `beacon_no_key` "beacon has no key"; `packet_budget` "paused to stay under the packet budget"; `path_paused` "path paused"; `path_set_paused` "path set paused"; `check_paused` "check paused"; `source_paused` "source paused"; `degraded_loss` "loss above trigger"; `degraded_latency` "latency above trigger"; `degraded_loss_latency` "loss and latency above trigger". Anything else is shown as sent.

**Incident** (`IncidentState` plus the `snoozed`, `maintenance` and `severity` fields)

| Condition | Word | Symbol | Color | VoiceOver |
|---|---|---|---|---|
| `open`, severity `critical` | open | `exclamationmark.octagon.fill` | fail | "Critical, {title}, open since {time}" |
| `open`, severity `warning` | open | `exclamationmark.triangle.fill` | warn | "Warning, {title}, open since {time}" |
| `open`, severity `info` | open | `info.circle` | quiet | "{title}, open since {time}" |
| `acknowledged` | acknowledged | `person.crop.circle.badge.checkmark` | quiet | "{title}, acknowledged by {who}" |
| `snoozed == true` (any open state) | snoozed until {time} | `moon.zzz` | quiet | "{title}, snoozed until {time}" |
| `maintenance` non-empty | held | `wrench.and.screwdriver` | quiet | "{title}, held by maintenance window {name}" |
| `pending` (derived, id `pending:`) | pending | `hourglass` | quiet | "{title}, pending, opens at {opens_at} if still failing" |
| `resolved` | resolved | `checkmark.circle` | ok glyph, quiet word | "{title}, resolved at {time}" |
| `flapping == true` (modifier) | adds "flapping" | `arrow.triangle.2.circlepath` secondary glyph | quiet | appends ", flapping" |

Precedence when several apply: held, then snoozed, then acknowledged, then the severity of open.

**Task run** (`TaskRunState` from `lib/taskLease.ts`)

| State | Word | Symbol | Color | VoiceOver |
|---|---|---|---|---|
| `pending` | pending | `hourglass` | quiet | "pending, not yet sent to nodes" |
| `queued` | queued | `clock` | quiet | "queued" |
| `leased` | running | `play.circle` | quiet | "running, {n} of {m} finished" |
| `finished` | finished | `checkmark.circle` | ok glyph, quiet word | "finished, exit code 0" |
| `failed` | failed | `xmark.circle.fill` | fail | "failed, exit code {code}" |
| `stalled` | stalled | `exclamationmark.arrow.circlepath` | warn | "stalled, no heartbeat for {age}" |
| `expired` | expired | `clock.badge.xmark` | warn | "expired, the node never picked it up" |
| `cancelled` | cancelled | `slash.circle` | quiet | "cancelled" |

A running task never shows a spinner or pulse: it shows a determinate count ("9 of 12 finished, 1 failed"). An expired node reads "Expired: the node never picked it up", never "failed".

**Approval** (server status words plus `stale` and `waiting`)

| Condition | Word | Symbol | Color | VoiceOver |
|---|---|---|---|---|
| `pending`, human, not stale | needs you | `hand.raised.fill` | `accent.text` glyph (a call to act, not a status color), primary word | "Needs you, {title} on {node}, filed {age} ago" |
| `pending`, `stale == true` | stale | `clock.badge.exclamationmark` | warn | "Stale, inspect only, {title}" |
| `approved` with `waiting.blocked` | waiting | `pause.circle` | warn | "Approved, waiting: {reason}" |
| `approved` without block, or `applying` | applying | `arrow.clockwise.circle` | quiet | "Approved, applying" |
| `applied` | applied | `checkmark.circle` | ok glyph, quiet word | "Applied" |
| `rejected` without `rejected_by` (the server rejects an approval whose apply task failed, keeping `approved_by`; there is no `failed` or `applied_unobserved` approval status) | failed | `xmark.circle.fill` | fail | "Apply failed" |
| `rejected` with `rejected_by` | rejected | `xmark.circle` | quiet | "Rejected by {who}" |
| `dismissed` | dismissed | `archivebox` | quiet | "Dismissed" |
| auto-approved `singbox-linemeta` by `lattice-server` or `system` | auto | `gearshape` | quiet | "Approved automatically" (history only, never in Inbox, never badged) |

**SSH Guard** (posture from the server's `posture` object; coverage from Shared `coverageBucket(boardStage(...), scope)`, a port of `sshGuardBoardModel.ts` over the server `stage`)

| Value | Word | Symbol | Color |
|---|---|---|---|
| posture `secured` | secured | `lock.shield` | ok glyph |
| posture `password_open` | password login open | `lock.open.fill` | fail |
| posture `partial` | partial | `shield.lefthalf.filled` | warn |
| posture `unknown` | unknown | `questionmark.circle` | quiet |
| coverage `confirmed` | confirmed | `checkmark.shield` | ok glyph |
| coverage `armPending` (stage `arm_pending` or `arm_approved`: the arm plan is not on the box yet) | arm pending | `hourglass` | quiet |
| coverage `reverting` with the revert timer running (`revertingNodes`) | confirm by {time}, with a `Text(timerInterval:)` countdown to `revert_deadline` | `timer` | warn |
| coverage `reverting`, timer not running | confirming | `arrow.uturn.backward.circle` | warn |
| coverage `open` (stage `idle`) | not armed | `circle` | quiet |
| coverage `failed` (`arm_failed`, or reverted after the window closed) | failed | `xmark.shield` | fail |
| coverage `excluded` | excluded | `minus.circle` | quiet |

**Freshness and access**

| State | Word | Symbol | Color | VoiceOver |
|---|---|---|---|---|
| fresh | "Updated {age} ago" | none | quiet | "Updated {age} ago" |
| stale (older than 3 poll intervals, or the last poll failed) | "Stale. As of {time}" | `clock.badge.exclamationmark` | warn | "Stale, as of {time}" |
| offline (no network path) | "Offline. Showing data from {time}" | `wifi.slash` | warn | same |
| denied (missing scope) | "Hidden: this token lacks {scope}" | `lock` | quiet | same |
| partial (approvals hidden by the server) | "Hidden from this token: {plugins}" | `eye.slash` | quiet | same |
| companion behind | "This app is behind the server. {surface} could not be read." | `exclamationmark.triangle` | warn | same |
| demo | "Demo" bar button | `theatermasks` | system | "Demo mode, data is invented" |

**Plan seal** (section 4.7)

| State | Symbol | Color | Where |
|---|---|---|---|
| unverified (server-supplied hash) | `seal` | `secondaryLabel` | approval rows, history, batch rows, task and audit references |
| verified (phone hashed the on-screen body, equal to `plan_sha256`) | `checkmark.seal.fill` | `status.ok.fill` | Review and BatchReview only |
| mismatch | `xmark.seal.fill` | `status.fail.fill` | Review and BatchReview only; Approve disabled |
| no body (listing row) | `seal` | `tertiaryLabel` | never actionable |

### 4.3 Typography roles

System text styles only, no custom face. Every role scales through the accessibility sizes.

| Role | Style | Use |
|---|---|---|
| `screenTitle` | navigation large title (system) | Tab roots and detail screens |
| `verdict` | `.headline` | Inbox verdict sentence (first list section, header trait) |
| `detailHeader` | `.title3.weight(.semibold)` | Object name inside a sheet or header block when no nav title shows it |
| `rowTitle` | `.body` | Object names in rows (2 lines, 3 at accessibility sizes) |
| `rowDetail` | `.subheadline`, `secondaryLabel` | Second line (region, agent, last seen) |
| `rowReason` | `.subheadline`, status `.text` token | Third line, the reason in words |
| `metric` | `.body.monospacedDigit()` | Trailing values, live numbers |
| `count` | `.subheadline.monospacedDigit()` | Inbox count buttons |
| `code` | `.callout.monospaced()` | Plan bodies, task output, transcripts, log lines |
| `identifier` | `.footnote.monospaced()` in rows, `.body.monospaced()` in detail rows | IDs, IPs, hashes, tokens |
| `stamp` | `.footnote.monospacedDigit()`, `secondaryLabel` | Times, freshness footers |
| `seal` | `.footnote.monospaced()` in rows; `.body.monospaced()` in the proof strip | Plan seal |
| `chartAxis` | `.caption2` | Chart axes and annotations |
| `footnote` | `.footnote`, `secondaryLabel` | Section footers, explanations |

### 4.4 Spacing scale

`Spacing.xxs = 2`, `.xs = 4`, `.s = 8`, `.m = 12`, `.l = 16`, `.xl = 24`, `.xxl = 32` points, all wrapped in `@ScaledMetric` where they separate text. List margins, row insets and section spacing come from the system inset-grouped list; custom spacing is used only inside rows and headers. Minimum hit target 44 by 44 pt.

### 4.5 List row anatomy

`StatusRow` (M0b, `Design/Rows.swift`) is the one row used for objects with a state. The layout is chosen from `@Environment(\.dynamicTypeSize).isAccessibilitySize` through `AnyLayout` (`HStackLayout` or `VStackLayout`), never from content width, so a whole list switches together.

Default sizes (up to xxxLarge):

1. Leading glyph column: the status symbol at `.title3` inside `@ScaledMetric(relativeTo: .title3) var glyphWidth = 28`.
2. Text stack: `rowTitle` (object name, up to 2 lines; middle truncation only for ids, hashes and IPs), `rowDetail` (context, up to two lines), optional `rowReason` (only for problems).
3. Trailing value: `metric` or `stamp`, right-aligned.
4. Chevron only when the row pushes (from `NavigationLink`); a tab-switching row shows the target tab's symbol and "Opens in {tab}" instead (2.4).

Accessibility sizes: no glyph column. The glyph sits inline before the title at the title's size, the title wraps to 3 lines, detail and reason wrap without a limit, and the trailing value moves to its own line under the detail. Rows are at least 44 pt tall at every size.

Accessibility: one combined element (`.accessibilityElement(children: .ignore)` with an explicit label built from the vocabulary phrase plus the trailing value). Swipe actions are exposed by SwiftUI as accessibility actions already; rows do not add a duplicate `.accessibilityAction(named:)` for them. Context-menu items that are not also swipes are added as named actions. Lists group by state, worst first, with section headers marked `.isHeader` so the headings rotor jumps between groups.

`DetailRow` (M0b): label and value. At default sizes the label leads and the value trails; at accessibility sizes the label sits above a wrapping value. Long monospaced values (IPs, digests, ids) wrap by character rather than truncate. Copy happens through the whole row (a `Button` whose accessibility hint is "Copies the value") or its context menu, never through a small inline icon.

Other shared rows (M0b, `Design/Rows.swift`): `ValueBarRow` (metric with a 4 pt inline bar, colored only past its threshold, the bar on its own line at accessibility sizes), `WebLinkRow` (`safari` symbol, "Open on web", the console path as a footnote), `ScopeDeniedRow`, `FreshnessFooter`, `ErrorRow` (message plus Retry), `PendingUpdatesRow` (section 5.0), `FilterStateRow` ("Showing approvals only. Show all"), `SealLabel`. Object rows used by more than one module (`IncidentRow`, `ApprovalRow`, `TaskRow`, `PathRow`, `NodeRow`, `AuditRow`) live in `Design/ObjectRows.swift` (section 8.2).

Context menus: node, incident, path, task and approval rows provide `contextMenu(menuItems:preview:)` with a compact glance preview (StatusRow plus two to four facts) and items: Open, Copy link, Copy ID, Open on web, the row's swipe actions, and for approval rows "Copy plan hash". Destructive items use `role: .destructive`. Actions the token cannot perform stay in the menu, disabled, with "Needs {scope}" as their subtitle.

Swipe actions: only actions the token can perform are offered (the explanation lives in the context menu). T1 swipes may use full swipe; T2 to T4 swipes set `allowsFullSwipe: false`. A swipe never holds a `Menu`: a swipe that needs a choice (Snooze) is a `Button` that sets list-level state driving one `confirmationDialog` attached to the list, with `titleVisibility: .visible`.

### 4.6 Chart conventions

Swift Charts only.

- Primary series: `LineMark`, 2 pt, `accent.text`. No area fill under lines, no gradients.
- p95: `AreaMark` band between p50 and p95 at 15% `accent.text`.
- Loss: `BarMark` on a separate lower chart sharing the x axis; tinted `status.warn.fill` only while the path is degraded or down, else `secondaryLabel`. No dual axes.
- Missing data is a gap. Consecutive points more than 2.5 sample intervals apart start a new series segment. Never interpolate across a gap.
- Rules, each with a direct text label at its trailing end: baseline `RuleMark` in `secondaryLabel`, dotted `[1, 3]`, "baseline"; trigger in `status.warn.fill`, dashed `[4, 2]`, "trigger"; `degraded_at` vertical rule in `status.fail.fill`, solid, "degraded {time}"; method changes as labelled point annotations.
- Maintenance windows: `RectangleMark` in `chart.band`, labelled "maintenance".
- Compare previous window: a second series in `chart.compare`, long dash `[6, 3]`, labelled "previous". Baseline and compare never share a dash pattern.
- State strips (path 24-cell strip, node status history): state is encoded by shape as well as color. Down is a full-height cell, degraded half height, up a thin tick at the baseline, unknown a hollow outline, paused a gap. When `accessibilityDifferentiateWithoutColor` is on, the cells also draw a 1 pt outline and the legend is shown.
- Height is `@ScaledMetric(relativeTo: .body) var chartHeight = 180` with a minimum of 160. Axes: three or four ticks at default sizes, two ticks with abbreviated labels (`02:41` or `2:41 AM` by locale, `40ms`) at accessibility sizes, times in the chosen zone.
- Scrubbing starts with a long press then drag (`chartGesture` with `LongPressGesture(minimumDuration: 0.3)` sequenced before `DragGesture`), as in Stocks and Health, so vertical scrolling and the edge swipe back keep working. The callout shows value, unit and time; `.sensoryFeedback(.selection)` fires when the selection snaps to a new sample.
- Accessibility: every chart has an `accessibilityChartDescriptor` (Audio Graphs) and a text summary row above it ("p50 41 ms, loss 0.2%, last hour"). Series with more than 60 marks hide their individual marks from accessibility (`.accessibilityHidden(true)` on the marks), relying on the descriptor and the summary row.
- Landscape gives the chart the full width inside the horizontal safe area (the Dynamic Island side inset is respected); nothing else changes.
- When the source is down or offline for the whole window, the chart is replaced by a sentence ("No data since {time}: source offline") with a link to the node. An empty chart frame is never shown.

### 4.7 Signature element: the plan seal

What it is: the plan's `plan_sha256` made visible as a short fingerprint, Lattice's doctrine (an approval binds to exactly what was shown) in a form the operator can compare with the console's digest. It is used only where a plan hash is bound to a decision.

Compact form (`SealLabel`, AstraCore `PlanSeal.short(_:)`): `seal` symbol, then the first four and last four lowercase hex characters joined by "…" ("3f9a…c210"), `seal` role typography, `secondaryLabel`. Inside rows it has no gesture of its own (copying is "Copy plan hash" in the row's context menu), it is hidden at accessibility sizes, and it is exposed to VoiceOver with `accessibilityCustomContent("Plan seal", "starts 3 f 9 a, ends c 2 1 0, not verified on this phone")`, read on request rather than in the row label. Outside rows (proof strip, TaskRun header, AuditEvent) it is its own element with that phrase as its label and a Copy button beside it.

Proof strip (Review and BatchReview only, `ProofStrip` in M1):

1. A header row: seal state symbol (section 4.2) and the state words: "Checking the plan below", "Matches the plan below", or "Does not match the plan below. Approve is off."
2. The full `plan_sha256` in `.body.monospaced()`, split into 4-character groups that wrap naturally; the first 8 and last 8 characters in `.semibold` primary, the middle in regular `secondaryLabel`. At accessibility sizes only the state row and the compact seal show, with a "Show full hash" button that expands the groups.
3. The line: "Approve sends this hash. If the plan changed, the server refuses."
4. A Copy button (`doc.on.doc`).

Where it appears: approval rows (Inbox, Approvals history, batch rows, node activity), the Review proof strip, the TaskRun header when the task was filed by an approval (from that approval's `plan_sha256`), and AuditEvent detail when the event references an approval id (fetched via the approval listing row). Never in empty states, loading placeholders, the app icon, marketing surfaces or as decoration. Never on a row for something that has no plan.

### 4.8 The verdict line

AstraCore `VerdictBuilder.verdict(for: InboxSnapshot, now:) -> Verdict` produces one sentence and a list of count segments; it is pure and covered by checks. `InboxSnapshot` holds plain counts, summaries and per-section coverage (fresh, failed, stale, offline, denied with the missing scope, partial with hidden plugins), never domain models, so M0a can build and test it before any module exists.

Inputs: per section (approvals, incidents, nodes, tasks, upcoming, SSH Guard, DDNS) its coverage plus the counts and the worst item summary; the node count and confinement; the newest `resolved_at` from `GET /api/incidents?state=resolved&limit=1`; degraded paths come from path-kind incidents in the incidents section (Inbox does not fetch `/api/monitors/paths`).

Rules, in order:

1. Nothing has loaded yet: "Checking the fleet."
2. Any section is failed, stale or offline: never say quiet. If approvals are fresh and non-zero, lead with them: "2 need you. Cannot confirm the rest: incidents did not load." Otherwise: "Cannot confirm. Last good refresh {age} ago." (the oldest successful refresh among the sections).
3. All readable sections fresh and something is wrong: "{n} need you. {worst problem} since {time}." The worst problem is chosen in this order: critical open incident, SSH Guard node `reverting` (confirm before its deadline), warning open incident, offline node, degraded path, failed task. With no approvals: "{worst problem} since {time}." Examples: "2 need you. Path tokyo-1 to fra-2 degraded since {time}." "fra-2 offline since {time}."
4. All readable sections fresh and nothing is wrong: "Quiet since {time}." where the time is the newest incident `resolved_at`; without one, "Quiet. Nothing needs you."
5. Denied and partial sections never block rules 3 and 4; they qualify them with a second sentence: "Not covered: DDNS, SSH Guard." (denied sections) and "Hidden from this token: Self-host DNS approvals." (plugins whose approvals this token cannot list, from `ApprovalVisibility`). A confined token adds "of visible nodes" to the node clause ("Quiet for what this token can see" leads when anything is denied or confined).

Count segments beneath, `count` typography, each a `Button` at least 44 pt tall that respects Button Shapes, laid out in a wrapping flow layout (M0b `FlowLayout`) at default sizes and as one full-width row per count at accessibility sizes: "33 of 35 online" (Fleet > Nodes, query `status:-online` when some are not), "2 waiting" (Activity > Approvals), "1 failed task" (Activity > Tasks, query `status:failed`), "3 due" (Fleet > Machines > Upcoming). A segment whose section is unknown or denied is omitted, never shown as zero.

Presentation: the sentence is the first list section, in `.headline`, with `.accessibilityAddTraits(.isHeader)`; it is not a hero and does not compete with the plan seal. Acceptance: on an iPhone SE at AX5 the first incident or needs-you row is visible without scrolling.

VerdictBuilder golden cases include a Triage-preset snapshot (approvals, DDNS and SSH Guard denied: "Quiet for what this token can see. Not covered: approvals, DDNS, SSH Guard."), an Operator snapshot, a confined-token snapshot, and a failed-section snapshot.

### 4.9 Haptics map

`sensoryFeedback` only for outcomes the operator caused. Passive updates (a new incident arriving, a poll changing a count) never vibrate.

| Event | Feedback |
|---|---|
| Approve lands (server confirms) | `.success` |
| Reject or dismiss lands | `.impact(weight: .medium)` |
| Batch decision lands, all rows ok | `.success` |
| Any write partially succeeds | `.warning` |
| Any write fails, 409 stale, hash mismatch detected | `.error` |
| Acknowledge, snooze, undo, end snooze applied | `.impact(weight: .light)` |
| T2 to T4 write lands | `.success` |
| Plan filed (P tier) | `.success` |
| Face ID cancelled | none |
| Confirm sheet shown | none (the sheet is the signal) |
| Picker, segment, window change; chart scrub snap | `.selection` |
| Pull to refresh completes | none |

### 4.10 Motion and Reduce Motion

- System springs and default list animations only. Rows move between state groups with the list's default animation.
- A state glyph change uses `.contentTransition(.symbolEffect(.replace))`; counts use `.contentTransition(.numericText())`.
- Nothing pulses, bounces or loops. No `.pulse`, `.bounce`, `.breathe` or repeating effects anywhere. No zoom transitions in v3.
- `@Environment(\.accessibilityReduceMotion)`: replace symbol and numeric transitions with a crossfade (`.opacity`), and disable list move animations (`withAnimation(nil)` on poll-driven reorders).
- The OutcomeBanner slides up from the bottom edge; with Reduce Motion it fades.
- Poll-driven reorders follow the stable-list rule (5.0) whatever the motion setting.

### 4.11 Liquid Glass rules

- Glass comes from system components only: tab bar, navigation bars, toolbars (including bottom toolbars), the search field, menus, sheets and their grabbers.
- At most one prominent action per screen, and it lives in the control layer: the Review "Approve and apply" toolbar button, the ConfirmSheet primary button (a `.confirmationAction` toolbar item, or the bottom-inset button described in F-15), and the WelcomeFlow primary action (`.bottomBar` toolbar item). In the toolbar the system draws it as prominent glass tinted `accent.fill`; a prominent button that must sit in content uses `.borderedProminent` with the same tint, never `.glassProminent`. Secondary actions are plain toolbar buttons or `.bordered`.
- Toolbar buttons that dismiss a sheet use `Button(role: .close)` (the system xmark); `role: .confirm` is used only where something is saved.
- The OutcomeBanner is an opaque rounded rectangle in the banner window (F-16), not glass. Trust is an opaque list row in Inbox; there is no TrustBanner.
- Content is never glass: no `.background(.ultraThinMaterial)`, `.regularMaterial` or `.glassEffect` on rows, cards, charts, headers, banners or empty states. `LatticeCard`, `StatTile`, `RingGauge` and `Theme.gradient` are deleted in M0.
- A pushed screen with a bottom toolbar stacks a second glass bar above the floating tab bar; this is accepted in portrait and verified on device (M3 acceptance). In a compact vertical size class, bottom-toolbar actions move into the navigation bar's trailing group (at most three groups) and the rest into its menu.
- Use `ToolbarSpacer(.flexible)` to separate destructive and primary actions in bottom toolbars.

### 4.12 Iconography

SF Symbols only. M0 checks every symbol name in this document against the SF Symbols app for iOS 26 and, if one is missing, substitutes the nearest existing symbol with the same meaning and records the substitution in `Tokens.swift`. Tab symbols as in 2.1. Plugin glyphs in approval rows: `sshguard` `lock.shield`, `agentupdate` `arrow.down.circle`, `beacon` `dot.radiowaves.left.and.right`, `netpolicy` `arrow.up.forward.circle`, `dns` `globe`, `tunnel` `point.topleft.down.to.point.bottomright.curvepath`, `netguard` `shield.lefthalf.filled`, `wireguard` `network`, `notify` witness `bell`, any other `puzzlepiece.extension`. Never emoji.

---

## 5. Screen specs

### 5.0 Shared rules every screen follows

Every data-backed screen binds to one or more `ResourceState<Value>` values (section 8.3) and renders the states the brief requires with M0 components:

| State | Rendering |
|---|---|
| Loading, first time | Placeholder rows with `.redacted(reason: .placeholder)` in the real layout, hidden from accessibility (`.accessibilityHidden(true)`); one accessibility element per section labelled "Loading incidents" takes their place. Completion is announced only on the first load of a screen. No spinner in the middle of the screen. |
| Loading, refresh | Keep the data; the freshness footer reads "Updating" |
| Empty | `ContentUnavailableView` with a symbol, a one-line title saying what is absent, and the freshness footer |
| Error | If there is earlier data, keep it and add an `ErrorRow` at the top of the failed section ("Could not refresh incidents: timeout" plus Retry). If there is none, `ContentUnavailableView` with the error and Retry. Never blank, which would read as healthy. |
| Stale or offline | Freshness footer in the stale style (section 4.2); verdicts and summaries stop claiming health |
| Missing scope | `ScopeDeniedRow` in place of the section, or `ContentUnavailableView("Hidden: this token lacks monitor:read", systemImage: "lock")` for a whole screen, with a "Token scopes" button to F-05 and "Manage tokens on web" (`/settings/access?view=tokens`). Tabs and directory rows never disappear. A section's requirement comes from the server's route wrappers and handler checks (section 8.9), not only from `nav.ts`, and is written in each screen spec. |
| Companion behind | Decode failure shows the companion-behind row for that surface, never an empty list |

Write actions the token cannot perform stay in their menus, disabled, with a second line "Needs node:admin". An action that needs a session the phone does not have shows "Needs a signed-in session" and opens F-06.

**Stable lists.** A poll result that reorders, inserts or removes rows is applied only while the list is idle: no touch or scroll in the last 2 s, no swipe open, no context menu or dialog up. While VoiceOver is running, reorders and inserts are held behind a `PendingUpdatesRow` at the top ("3 updates. Show") that is announced once; focus stays where it is (`@AccessibilityFocusState`). Value changes inside existing rows apply at once. Pull to refresh applies at once.

**Filters.** No chip rows. Mutually exclusive states use `.searchScopes` (default the broadest scope). Multi-dimension filters use a toolbar filter `Menu` (`line.3.horizontal.decrease.circle`) with inline `Picker` sections. Active filters show as search tokens and in `.navigationSubtitle` ("Password login open"). Views of one pushed screen (Policies, Nodes, Matrix) use `AdaptiveSegmentedPicker` pinned in that screen's `safeAreaBar(edge: .top)`. M0b provides `FilterMenu` and `RangeMenu` (1h, 24h, 7d, 30d, All, Custom with since and until pickers) in `Design/Controls.swift`.

**Sheets.** One sheet at a time (section 6.5). Detents: `[.medium, .large]` only at non-accessibility sizes and `[.large]` at accessibility sizes; sheets with text entry open at `.large`. `.presentationDragIndicator(.visible)` whenever a sheet has more than one detent. Every sheet's content scrolls, and its primary action is pinned in `safeAreaInset(edge: .bottom)` (or the toolbar) so it is visible at every size and above the keyboard. In landscape iPhone sheets open full height; layouts assume that height is about 375 pt on an SE.

**Navigation titles.** Short: the object name ("tokyo-1 to fra-2", "fra-2"). State goes in `.navigationSubtitle`; a full event sentence is the first content row in `detailHeader` style. Arrows in visible text ("tokyo-1 → fra-2" in rows) carry an accessibility label that says "to".

Every list that can exceed one screen has `.searchable` with the console query grammar (section 6.14) and pull to refresh. Every object screen has "Open on web" in its toolbar menu and "Copy link" (`lattice://`).

Screen spec format below: **Gate** (read requirement), **Layout** top to bottom, **Data**, **Actions**, **Search**, **States** (only what differs from 5.0).

### 5.1 Foundation screens (M0)

**F-01 RootTabs.** Five tabs per 2.1. Owns `AppState` (selected tab, paths, presented review, pending queries, demo flag), the scene phase handling (pause polling in background, lock on return when enabled), and applies `.actionHost()` (section 8.3). It does not own the banner, the privacy cover or the lock: those are scene-level windows (F-16, F-18).

**F-02 WelcomeFlow.** Full-screen cover, its own stack. See section 7 for every step. Each step's primary action is a `.bottomBar` toolbar button (prominent, tinted `accent.fill`). "Explore with demo data" is on the first step.

**F-03 Settings.** Sheet, large detent, inset-grouped list in its own `NavigationStack` of `SettingsRoute`. Sections: Connection (server name, credential type, actor, scope count) > F-04; Session for reveals (state) > F-06; Device security > F-07; Badge refresh > F-08; Display > F-09; Diagnostics > F-10; Demo data > F-11 (demo only, first section); About > F-12; Account: Security (M11-01) and Access (M11-03), pushed inside this sheet's stack. Footer: app version and build. A `Button(role: .close)` dismisses it; nothing in Settings needs a save button because each change applies when made.

**F-04 Connection.** Server URL, console URL, `/api/version` build, actor id, credential (API token or Signed-in session), Keychain status, "Check connection" (calls `/api/health`, `/api/version`, `/api/me` on each client and lists each result), "Token scopes" > F-05, "Change credential", "Switch to demo data", "Sign out" (T2 dialog naming the server: "Sign out of lattice.example.net? This removes the token and session from this iPhone.").

**F-05 ScopeSummary.** From `/api/me` on each client: a list of capabilities grouped by tab, each row "Can" or "Cannot" with the scopes that decide it ("Acknowledge incidents: needs monitor:admin, missing"), evaluated with the client the intent runs on (section 6.12). Shows `server_allowlist` confinement ("Confined to 12 nodes") and the approval plugins this token cannot list. Warns when the active token holds `task:run`, `terminal:open`, `token:admin`, `user:admin` or `plugin:admin`, each with what it permits through the API ("token:admin: this token can mint other tokens that outlive it"). Token presets as copyable text blocks for the console's token form, generated from AstraCore `TokenPresets` (derived from the parity matrix, section 6.12): **Triage**, **Operator**, **Operator plus root**. Footer: "Never add secrets:reveal, notify:send or token:admin to a phone token."

**F-06 SessionForReveals.** Explains that reveals and passkey changes need a signed-in session because the server refuses step-up for tokens. State row ("Signed in as {user} until {expires}" from the cookie's `Expires`, or "Not signed in"). "Sign in for reveals" runs username, password and TOTP against `/api/login` and `/api/login/totp`. "Keep the session on this iPhone" (off by default; when on, the session is a `.userPresence` Keychain item, section 7.2). "End session after each reveal" (on by default; calls `POST /api/logout` when a reveal closes). "Sign out of the session" (T2). Explicit states: "This account has no authenticator code. Set one up on the web first." (403 "an authenticator passcode must be enabled", for SSO accounts with `skip_local_totp` or passkey-only accounts) and "Two-factor enrollment is required. Enroll on the web first." (403 `mfa_required`).

**F-07 DeviceSecurity.** "Require Face ID to open" (off by default) and "Lock after" (Immediately, 1 min, 5 min, 15 min). Footer: "Face ID or the passcode always confirms decisions and privileged changes, whatever this setting says."

**F-08 BadgeRefresh.** Toggle "Refresh the badge in the background". Turning it on is the only place the app calls `UNUserNotificationCenter.requestAuthorization(options: [.badge])`. Copy: "The server's notify channels alert you. This only refreshes the badge when iOS allows, which may be hours apart." Shows last background refresh time and outcome, and which approval plugins and incident scopes the badge cannot see. If authorization is denied, shows the state and a button to the app's iOS Settings page.

**F-09 Display.** "Show times in UTC" toggle, stored in `UserDefaults` and supplied to views as an environment value `\.timeZoneMode` (section 6.16). Preview row showing a sample time both ways.

**F-10 Diagnostics.** Last 50 request errors (method, path, status, time, message; no headers, no bodies), the plugin trust state, polling cadence in effect (normal, Low Power), network path state. In demo mode also the DemoTransport request log. "Copy diagnostics" builds a text report with tokens redacted.

**F-11 DemoScenario** (demo only). Picker over the scenarios of section 8.6 (Normal, Quiet, Failing, Stale, Offline, Limited token, Confined token, No session, Forbidden, Empty, Companion behind) and a "Pin demo clock" toggle. Used for state screenshots.

**F-12 About.** App version and build, server build and dashboard ref from `/api/version`, compatibility verdict, links to the public site and source repository.

**F-13 RevealFlowSheet.** One sheet for every S action, advancing in place through its steps; there is never a separate step-up sheet followed by a reveal sheet.
1. *Code* (skipped when a grant is held for more than 5 s): title "Confirm with your code"; states the secret and object ("Reveal the knock sequence for edge-tyo-3"); one TOTP field (`.textContentType(.oneTimeCode)`, number pad, autofill from Passwords). It submits by itself once six digits are present, including after paste or autofill; a Submit button stays pinned in the bottom inset above the keyboard. If the current 30 s step equals the step of the last code this phone sent, it shows "Wait for the next code" with a countdown. A wrong code stays on this step with "Wrong code. If you just used this code elsewhere, wait for the next one." and never signs the session out. Without a session the step is replaced by the explanation and "Sign in for reveals" (F-06), which signs in and continues to this step with the next code.
2. *Value*: F-14.
Cancel (`role: .close`) at any step sends nothing further. Opens at `.large` (text entry).

**F-14 SecretRevealStep.** The value step shared by F-13 and by ConfirmSheet results that return a credential (rotate node token). Title names the secret and object. The value is masked until "Show" is tapped, shown in `identifier` style. Actions: Copy (UIPasteboard with `.localOnly: true` and `.expirationDate` 60 s ahead); Share only for share URLs and VPN subscription links, which are meant to be sent; a console link opens in `SFSafariViewController` (no shared history), never through `openURL`. A visible 60 s countdown; at zero, on the scene's `.inactive` transition, or when the sheet closes, the value is cleared. While `UITraitCollection.sceneCaptureState` is `.active` (screen recording, AirPlay mirroring) the value stays masked with "Hidden while the screen is being recorded or mirrored". Footer: "iOS cannot block screenshots. This value is not stored on this iPhone." Values are never logged, cached, restored or put in diagnostics.

**F-15 ConfirmSheet.** The step container for T3, T4 and P intents (section 8.3). At the root it is a sheet; inside another sheet, the same content is a `ConfirmPage` pushed on that sheet's stack. Steps, advancing in place:
1. *Confirm*: title (the verb and object, "Disable edge-tyo-3"); consequence sentence; "Uses scope node:admin"; blast radius ("Affects 1 node" or the node list, or "Will try" for P intents whose server decides per node); dry-run results when the intent has one (loaded before the button enables, with a row "Checking what would change"); explicit toggles (for example "Accept lockout risk", unchecked by default); for intents with `confirmPhrase`, a field where the operator types the object name. The primary action, pinned in the bottom inset, carries the verb and object ("Disable edge-tyo-3", "Delete node edge-tyo-3", "File plan"), destructive role for T4.
2. *Authenticate* (T3, T4): Face ID with a reason naming verb and object. Cancel returns to step 1 and sends nothing.
3. *Findings* (P, on a 409 with findings): the findings list and the acceptance toggle; a second tap re-sends with the acceptance flag (section 8.3).
4. *Result*: per-object outcomes for bulk and P intents, or F-14 when the outcome carries a secret. Single-object `.done` outcomes dismiss and show the banner.
Opens at `.medium` at default sizes when the content fits, else `.large`.

**F-16 OutcomeBanner.** Shown at the bottom, above the tab bar and toolbars, in a scene-level `BannerWindow` (a `UIWindow` at `windowLevel = .normal + 1` whose hit testing passes through everywhere outside the banner), so it stays above any presented sheet. An opaque rounded rectangle (`secondarySystemGroupedBackground`, 1 pt `separator` stroke, corner radius 14) that grows with its text; at accessibility sizes Undo stacks under the text. Content: the outcome text ("Acknowledged fra-2 offline"), an Undo button when the intent has a verified inverse, and a chevron to the object for partial results. Stays 10 s; the timer pauses while the banner is touched or has accessibility focus, and while VoiceOver or Switch Control is running it stays until dismissed. It posts an `AccessibilityNotification.Announcement` with the text. The inverse stays in the row menu and detail toolbar after the banner goes (6.6). With Reduce Motion it fades instead of sliding.

**F-17 TrustDetail.** Lists `/api/plugin-trust` findings with plugin links (M8 routes) and the console path.

**F-18 ShieldWindow (privacy cover and AppLock).** A separate `UIWindow` owned by the `UIWindowScene`, `windowLevel = .alert + 1`, created by `Shell/PrivacyCover.swift` from the scene delegate. On `sceneWillResignActive` it is shown at once with an opaque cover (app symbol, no data), so the app-switcher snapshot never shows plan bodies, IPs or a revealed value, whatever sheet is up. On `sceneDidBecomeActive` it is removed, unless "Require Face ID to open" is on and the lock interval has passed: then it shows "Unlock" and runs `IntentAuth` with reason "Unlock Lattice", and is removed only after success. Cancelled stays locked. No SwiftUI presentation is used for either.

**F-19 FleetRoot.** Segmented control (Nodes, Groups, Map, Machines) in `safeAreaBar(edge: .top)` with the adaptive rules of section 1 (`AdaptiveSegmentedPicker`, `Design/Controls.swift`). Content is the owning module's scope view (M2 or M5). Toolbar trailing items come from the scope view.

**F-20 MonitorRoot.** The same control with Overview, Paths, Checks, Incidents. Window menu in the trailing toolbar (`1h`, `6h`, `24h`, `3d`, `7d`, `14d`), shared by all segments through `AppState.monitorWindow`. Content from M3.

**F-21 ActivityRoot.** The same control with Tasks (M4), Audit (M4), Approvals (M1), Sent (M9).

**F-22 BrowseRoot.** `.searchable` at the top of its root (standard style). Empty query shows the directory: "Recent" (up to 6 recently opened pages), then sections mirroring the console sidebar: Fleet (Nodes, Groups, Map, Machines, Upcoming, Monitoring; tab-switching rows except Upcoming), VPN (Users, Lines, Node profiles [web], Usage [web], Sub-Store [web]), Operations (Approvals, Tasks, Terminal, Audit), Networking (Inbound firewall, Outbound policy, WireGuard mesh [web], Self-host DNS, DDNS, Geo-Routing, Tunnels, SSH Guard), Platform (Plugins, Extensions, Publishing, Store, Evidence, Notifications, Webhooks, Agent Updates, System), Settings (Security & 2FA and Access open the Settings sheet; Capability Gates pushes; About opens the Settings sheet). Pages the token cannot read move into a collapsed group at the bottom, "Not available with this token (n)", each row naming the missing scope. Typing searches pages by name plus every registered `SearchProvider` (section 8.5): nodes, approvals, incidents, tasks, checks, machines, groups, policies, tokens, VPN identities, shares, debounced 250 ms and cancelled on each new query. Results are grouped by kind, five per kind with "Show all". The query accepts the console grammar (`status:offline region:tokyo`, `-tag:lab`). Directory deep links land in this stack.

### 5.2 M1 Inbox and approvals

**M1-01 InboxScreen.**
- Gate: none for the screen; each section has its own gate.
- Layout: large title "Inbox". Toolbar: trailing filter `Menu` (All, Approvals, Incidents, Attention; All on every launch), then the Settings button group. While filtered, a `FilterStateRow` ("Showing approvals only. Show all") is the first row and the filter is the `.navigationSubtitle`. Then:
  1. Verdict section (4.8): the sentence and the count buttons.
  2. Trust row, only when `/api/plugin-trust` warns; control-plane row, only when `/api/health` is not ok (expands inline to the health fields; links to System when the token has `*`).
  3. **Incidents** (`IncidentRow`): open incidents, critical first, then warning, then by age; acknowledged and snoozed follow in quiet style. Row: incident glyph, title ("fra-2 offline"), detail "since {time}, 18 min", trailing state word. Leading swipe Acknowledge (Unacknowledge when acknowledged), label "Acknowledge: stops repeat alerts". Trailing swipe "Snooze" (a Button) opens the list-level snooze dialog (1 h, 4 h, until 08:00 tomorrow as formatted by the locale, End snooze when snoozed), whose title names the incident and whose message states "No repeat alerts until {time}". Context menu adds Start maintenance (`Router.present(.maintenanceStart(nodeID:))`), Open node, Open path, Copy link.
  4. **Needs you** (`ApprovalRow`): human-pending approvals this token can list, grouped by console event key: a group of one renders an approval row (plugin glyph, title, target node, actor, age, `SealLabel` per 4.7, waiting reason in `rowReason`); a group of several renders one row ("Agent update to 0.4.2 on 14 nodes") that opens BatchReviewSheet. Tap opens Review. No swipe to approve. Footer: plugins hidden from this token ("Hidden from this token: SSH Guard, Self-host DNS", from `ApprovalVisibility`); when the list hit the server's default of 100, "Showing 100 of {N}" from `?count=1`.
  5. **Attention**: offline and degraded nodes not already covered by an incident; SSH Guard nodes `reverting` with a `Text(timerInterval:)` countdown to `revert_deadline` (a row with `actionable_approval_id` opens that approval in Review); tasks failed or stalled in 24 h; approved plans waiting to apply (blocked); DDNS profiles failing or stale (`DDNSProfile.health(now:)`); renewals due in 3 days; "Recent changes" (audit changes in the last hour, count) > Activity > Audit with view Changes. Each row pushes or selects the owning screen. More than six rows show "Show all" > `InboxRoute.allAttention`.
  6. **Due soon**: up to three upcoming items plus "All upcoming" > Fleet > Machines > Upcoming.
  7. Footer: freshness; "Badge from {time}" when background refresh set the badge; "Notified via {channel} at {time}" or "Notification failed via {channel} at {time}" from the newest delivery's outcome (omitted without `notify:admin`).
- Data: `GET /api/network/approvals` (human-pending filter as today, `?count=1`), `GET /api/incidents?state=open,acknowledged` and `GET /api/incidents?state=resolved&limit=1`, `GET /api/nodes`, `GET /api/tasks?status=failed,stalled&since=<now minus 24 h, RFC 3339>&limit=20` and `/api/tasks/counts`, `GET /api/expiring?within=7` (whole days, 1 to 365), `GET /api/sshguard/status` (only with `sshguard:read` and `network:plan`), `GET /api/ddns`, `GET /api/audit?at_from=<now minus 1 h>&limit=100` with the console's Changes-view filter (the `exclude_action` and `exclude_decision` values AuditView sends for `view=changes`, recorded in `api-shapes.md`), counted on device (only with `audit:read`), `GET /api/notify/deliveries?limit=1`, `GET /api/plugin-trust`, `GET /api/health`. Badge number from Shared `BadgeCount.compute(approvals:incidents:)`.
- Actions: swipes per above (T1 with Undo); pull to refresh; filter menu. Poll results follow the stable-list rule of 5.0.
- Search: none (short by design; Browse covers it).
- States: empty is `ContentUnavailableView("Nothing needs you", systemImage: "checkmark.circle")` under the quiet verdict. A failed section shows its ErrorRow with Retry while other sections render. Missing `network:apply` (or the plugin's decision scope) keeps approvals listed and Review opens read-only. Without `sshguard:read` plus `network:plan`, the SSH Guard attention input is a ScopeDeniedRow "Needs sshguard:read and network:plan" and counts as denied for the verdict.

**M1-02 ApprovalReviewSheet.** Specified in full in section 6.1. One `ScrollView` is the only vertical scroller. Top to bottom: header (plugin glyph and name, action, status word, targets as node links, actor or "filed by agent", filed age, plugin version, artifact digest as a DetailRow); SSH Guard confirm explanation when `isSSHGuardConfirm` ("Must be approved and applied before {deadline}", from the node's `revert_deadline`); proof strip (4.7); the plan body; waiting section; superseded-by link; result section after a decision. Navigation title "Review"; leading `Button(role: .close)`; trailing `Menu` with Copy plan, Copy link, Open on web, Wrap lines, Dismiss (when `canDismiss`).
- Decision panel: a `safeAreaInset(edge: .bottom)` panel above the toolbar holds a visible `Toggle("Apply after approval")`, on by default, and, when Approve is unavailable, the reason as wrapping body text with a symbol ("Deciding needs network:apply and sshguard:admin"). The bottom toolbar keeps two short buttons: Reject (destructive), `ToolbarSpacer(.flexible)`, and the prominent primary whose label follows the toggle: "Approve and apply" or "Approve only". Custom bar content gets `.accessibilityShowsLargeContentViewer()`. At accessibility sizes the toolbar is dropped and the panel holds a full-width vertical stack: toggle, primary, Reject.
- Plan view: `PlanTextView` (M1), a `UITextView` representable in embedded mode: `isEditable = false`, `isScrollEnabled = false`, sized to its intrinsic height inside the sheet's scroll view, `code` font scaled with Dynamic Type. Lines soft-wrap by default at accessibility sizes and in compact width; "Wrap lines" in the menu toggles it, and when off the text view sits in a horizontal `ScrollView` (a different axis, so no same-axis nesting). Line numbers are a separate gutter view hidden from accessibility that marks continuation lines with a hook. Find is a SwiftUI find bar (menu "Find in plan") that computes match ranges in the string, asks the text view for each match's rect (`firstRect(for:)`), and scrolls the sheet with `ScrollPosition.scrollTo(y:)`. The text is exactly `approval.plan`, the same string passed to `PlanHasher`; wrapping changes layout only.

**M1-03 BatchReviewSheet.** Specified in 6.2. Layout in one scroll view: title ("Agent update to 0.4.2, 14 plans"); a summary row "14 plans, 1 distinct body" or "14 plans, 14 distinct bodies"; refusal rows when opened from a P outcome with refusals; offline-node warning row when any target is offline; one row per approval (node name and honesty glyph, `SealLabel` with its verification state, waiting reason); then each distinct body inline in an embedded `PlanTextView`, labelled with its seal and the nodes that share it. Decision panel as in M1-02 ("Apply after approval" toggle); toolbar: Reject all (destructive), spacer, "Approve and apply 14" or "Approve only 14". After the decision, each row shows its own outcome.

**M1-04 ApprovalsScreen.** Activity scope. `.searchScopes`: Needs you, History, Stuck (console `view=needs|history|stuck`). Gate: listing needs `network:plan` plus a plugin read scope (section 6.12); rows the token cannot list are named in the footer. Rows are `ApprovalRow`, with status word per 4.2. Toolbar: `RangeMenu` (1h, 24h, 7d, 30d, All, Custom since and until; the server takes only `since`, so `until` filters loaded rows on device). Search tokens `status:`, `plugin:`, `node:`. Data: `GET /api/network/approvals` with `status`, `plugin`, `node_id`, `since`, `limit=50`, `offset` (envelope form), `include_dismissed=1` in History. Infinite scroll by offset (`PagedListLoader`). Stuck shows approved rows with `waiting.blocked`, each with its reason and Dismiss available inside Review when dismissible.

### 5.3 M2 Fleet

**M2-01 NodesScreen.** Gate node:read. Header row "35 nodes, 33 online" (or "Confined to 12 nodes"); duplicate banner when `/api/nodes/duplicates` is non-empty ("2 possible duplicate nodes") > M2-02. Sections by status, worst first (offline, degraded, never reported, online, disabled); a toolbar Group menu offers None, Status, Region, Provider, Group, Tag. Row: `NodeRow` with name, detail "Tokyo, aws, agent 0.4.1, seen 12 s", trailing CPU percent. Trailing swipe: Disable (T3) or Enable (T2). Edit mode (toolbar Select) for bulk disable (T3) and bulk enable (T2). Context menu: glance preview, Open terminal on web, Copy IP. Search: console node fields (`name`, `ip`, `tag`, `group`, `provider`, `country`, `region`, `os`, `agent`, `cap`, `status`, `cpu`, `mem`, `disk`, `rx`, `tx`, `last_seen`), `sort:-cpu`. Data: `GET /api/nodes`, `/api/nodes/duplicates`, `/api/groups` (names). Empty: "No nodes enrolled" with "Enroll on web".

**M2-02 DuplicatesScreen.** List of duplicate sets from `/api/nodes/duplicates`, each with the nodes, their last seen and IPs; rows push NodeDetail. Footer "Resolve duplicates on web".

**M2-03 NodeDetailScreen.** Gate node:read. Title: node name; `.navigationSubtitle` the honesty word. Header block (not a card, a plain list section): honesty glyph and word with duration ("offline for 12 min"), last seen, agent version ("2 behind" in warn when behind target), region and provider, public IP (copyable). `AdaptiveSegmentedPicker` Overview, Activity, Settings (mirrors `?view=`, `NodeDetailTab`) pinned in `safeAreaBar(edge: .top)` so it never scrolls away.
- Overview: open incidents for this node; Now (CPU, memory, disk, rx, tx as ValueBarRows); History chart (1 h, 24 h, 7 d, 30 d from `/api/nodes/history?node_id&range`) > M2-04; Paths: the worst five where the node is source or target (Shared `fetchPaths`, `PathRow`) > PathDetail, "All paths" > `Router.select(tab: .monitor, scope: "paths", query: "source:{node}")`; Effective network row (policy name, rule count) > M2-05; SSH Guard row (posture and coverage words; needs sshguard:read and network:plan) > M7-02; Capabilities row (n admitted, n excluded) > M2-06; Machine row (vendor, monthly cost, renewal countdown) > M5-02; Beacon row > M2-07; Queued tasks.
- Activity: merged timeline of audit events (Shared `fetchAudit`, `node_id`), tasks (`node_id`), approvals (Shared `listApprovals`, `node_id`), newest first, rows from `Design/ObjectRows`, `.searchScopes` All, Changes, Tasks, Approvals; "Logs" row > M10-04 filtered.
- Settings: Identity (name, tags, role) with Edit (T2) > M2-08; Groups (rows > GroupDetail); Geo (country, city) with menu Resolve (T2), Clear (T2), Set on web; IP discovery (read, Open on web); Agent debug toggle (T2); Auto-update policy (read, Open on web); Agent update: Plan update, Force plan (P, Shared `planAgentUpdate`); Beacon: Plan (P), Rotate (T3); Token: Rotate (T3; consequence "edge-tyo-3 stops reporting and receives no plans until the new token is installed on the host. You cannot do that from this iPhone."; the new token shows once, Copy only, with "Reconfigure on web"); Danger: Disable or Enable, Delete node (T4) > M2-09.
- Toolbar menu: Open terminal on web, Terminal sessions (M12), Start maintenance (`Router.present(.maintenanceStart(nodeID:))`), Open on web, Copy link, Copy ID.
- States: disabled collapses Now to "Not reporting while disabled" with Enable; never reported replaces Overview with "Agent has never reported" plus enrollment facts and "Open on web" for the reconfigure command; missing node:admin leaves Settings write rows disabled with "Needs node:admin".

**M2-04 NodeHistoryScreen.** Full-width charts per metric (CPU, memory, disk, rx, tx) with range picker, gaps for missing samples, scrubbing. Data `/api/nodes/history?node_id&range` and `/api/nodes/status-history`. Status history as a `StateStrip` above the charts (online, degraded, offline encoded by shape as well as color, 4.6).

**M2-05 NodeNetworkScreen.** From `/api/nodes/network?node_id&rules=1`: effective outbound policy, rules list (direction, protocol, ports, peer), an "Inbound firewall" row that pushes `NetworkingRoute.inboundFirewall(nodeID:)` (M6), and links to PolicyDetail (M6) and NodePolicy (M6).

**M2-06 NodeCapabilitiesScreen.** `/api/nodes/capabilities?node_id`: each capability with admitted, excluded or not enrolled, and the gate behind it. Row swipe: Enroll or Exclude (T3).

**M2-07 NodeBeaconScreen.** `GET /api/nodes/beacon`: beacon state for the node, epoch, key age, listening, last seen by sources. A 404 (servers older than M2b) reads "No beacon on this node", not an error. Actions: Plan beacon (P, Shared `planBeacon`; `action: enable` when none exists, `change` otherwise, with port, bind and endpoint from the current state; adds netguard:admin to the intent's scopes when the plan carries a NetGuard companion; 409 findings loop), Disable beacon (P, `action: disable`), Rotate key (T3).

**M2-08 NodeIdentitySheet.** Form: name, tags (token field), role. Save is T2 with the dialog naming the node and fields changed. Validation errors from the server in place.

**M2-09 Node delete.** A T4 `WriteIntent` (`NodeDeleteIntent.swift`) whose dry run is `POST /api/nodes/delete/plan`, rendered in the ConfirmSheet; there is no separate sheet. It shows every non-zero counter of `nodeDeleteSummary`, grouped by consequence: services (managed lines, line-chain definitions, tunnels, DNS deployments, geo routes, DDNS profiles), configuration (net policies, approvals, machine profiles, monitors, group membership, capabilities), history (tasks, results, logs, metrics). The dry run's `fingerprint` is the counters; it is re-run immediately before sending and the write stops with "What would be deleted changed. Review again." if it differs. `confirmPhrase` is the node name when the node has DNS, geo, tunnel or line dependencies. The button reads "Delete node {name}", destructive; Face ID with reason "Delete node {name}". A 409 line-chain conflict maps to its message. `log_store_purge_errs > 0` is `.partial` ("Node deleted; 2 log stores could not be purged"). The node leaves lists only after the server confirms.

**M2-10 GroupsScreen.** Gate group:read. Rows: group name, kind (selector or static), member health ("12 nodes, 1 offline"). Swipe Delete (T4, the sheet lists Used by first). Toolbar "New group on web". Data `GET /api/groups` (`resolved_members`, `rollup`).

**M2-11 GroupDetailScreen.** Selector text or static member list, member rows (`NodeRow`) from `resolved_members` with health from `rollup`, Used by (`/api/groups/used-by`: policies, rules, checks) with links. Actions: for static groups, Add members and Remove (T2, `POST /api/groups/members`, group:admin; the dialog names the group and the nodes); Delete (T4); Edit on web.

**M2-12 MapScreen.** Gate node:read. A "Map | List" segmented control in the toolbar (principal placement); no persistent sheet, so the tab bar stays reachable. Map: one `Annotation` per location cluster (nodes grouped by coordinates rounded to 0.5 degrees by AstraCore `MapClusters`) showing the status glyph of the worst member and a count, each at least 44 by 44 pt and labelled "Tokyo, 4 nodes, 1 offline". Tap shows a callout list of members > NodeDetail. Toolbar menu: "Latency" toggle (`MapPolyline` geodesic arcs for paths, problem paths only by default, "All paths" in the menu), "No location (n)" > M2-13. Arcs carry state by dash pattern as well as color (solid up, dashed `[6, 4]` degraded, dotted `[1, 4]` down) with a legend row. List: nodes by region (`NodeRow`) and, when Latency is on, the problem paths (`PathRow`), which is also what VoiceOver users get. Data `/api/nodes`, `/api/nodes/geo`, Shared `fetchPaths(window:)` for arcs.

**M2-13 UnlocatedNodesScreen.** Nodes without geo. Toolbar "Locate all" (T2: "Resolve location for 4 nodes from their public IPs"). Per-row Resolve (T2).

**M2-14 CapabilityGatesScreen.** Gate node:read. Each gate: name, enforced or not, description. Tap > M2-15.

**M2-15 GateDetailScreen.** Gate facts and the "would refuse" preview (which nodes or plans it would refuse) from `/api/capabilities`. Toggle enforced (T3; the ConfirmSheet repeats the would-refuse list).

### 5.4 M3 Monitoring

**M3-01 MonitorOverviewScreen.** Gate monitor:read. Health verdicts as rows: paths by state counts, checks failing, incidents open, beacon replans pending; each row filters the matching segment. Recently degraded paths (top five) with their reason sentences. Data Shared `fetchPaths(window:)`, `/api/monitors`, Shared incidents.

**M3-02 PathsScreen.** Gate monitor:read. Toolbar: view `Menu` (Problems, All, Chains, Matrix > M3-03, Graph on web). "Show unmeasured" toggle in the menu. List grouped by state in `topologyModel` order (down, degraded, unknown, paused, up; up collapsed by default in Problems). Row (`PathRow`): state glyph, "tokyo-1 → fra-2" (spoken "tokyo-1 to fra-2"), method (`icmp`, `tcp`, `http`), trailing p50 and loss in `metric`, a 24-cell `StateStrip` over the window (shape-encoded, hidden from VoiceOver, summarized in the label), reason sentence for unknown and degraded. At accessibility sizes the row stacks title, method, then p50 and loss on their own lines, and the strip moves to its own full-width line (or hides on an SE at AX5, its summary kept in the label). Chains view: line chains as vertical hop lists (entry, relay, exit) each with its path state > M3-05. Search: `source:`, `target:`, `method:`, `state:`, free text (`paths.q`). Data Shared `fetchPaths(window:)` (`{window, sources, targets, paths, degraded_at, beacon_replans}`), `/api/network/lines/chains` (M3-owned) for Chains (proxy:read; ScopeDeniedRow otherwise). Empty: "No paths measured. The latency plan has no pairs yet." with "Latency plan on web".

**M3-03 PathMatrixScreen.** An overview, not a control: cells are not tappable. Sources as rows, targets as columns, pinned header row and column, cells 14 pt (fit-to-width toggle in the toolbar), drawn in a `Canvas`, each cell the state fill plus a shape mark (4.6) so grayscale reads. Tapping a source row label or a column header (each hit area at least 44 pt) pushes Paths filtered to that source or target (`source:` or `target:` query). Best in landscape. At accessibility sizes, or while VoiceOver runs, the grid is replaced by the per-source list ("tokyo-1: 3 down, 2 degraded, 30 up"), each row pushing the filtered Paths, with a custom rotor "Problem paths" over sources that have down or degraded paths.

**M3-04 PathDetailScreen.** Pushed. Title "tokyo-1 to fra-2", state in `.navigationSubtitle`. Header: state word and reason sentence; evidence sentence ("Loss 4.1% against a baseline of 0.3%, trigger 2%, since {time}"); method. Latency chart (p50 line, p95 band, baseline and trigger rules, `degraded_at` rule, method-change annotations, maintenance bands) and loss chart beneath; "Compare previous window" toggle; reverse direction row ("fra-2 to tokyo-1, up") > its PathDetail. When the source is offline: the charts are replaced by "No data since {time}: source offline" with a link to the node. Rows: source node, target node (or address), the check behind it > M3-07, open incident > M3-11, recent beacon replans. Action: Plan beacon replan (P, `action: change`). Data Shared `fetchPaths(window:)` (the path), `/api/monitors/latency/series` and `/api/monitors/series` for the charts, `/api/incidents`.

**M3-05 ChainDetailScreen.** Hops in order with each hop's path state and latency, the line it serves, link to VPN line detail (M13) when readable.

**M3-06 ChecksScreen.** Gate monitor:read. Sections: Failing, Checks (by type `tcp`, `http`, `icmp`, `tls`, `beacon`, `dns`), Definitions. Row: check name, type, target, trailing last result and age; paused checks in quiet style with `pause.circle`. Swipe Pause or Resume (T2), not offered on generated checks. Toolbar: "New check on web". Search: `type:`, `node:`, `state:`, free text (`monitors.q`). Data `/api/monitors`, `/api/monitors/results`, `/api/monitors/definitions`.

**M3-07 CheckDetailScreen.** Header: type, target, interval, timeout, assigned nodes count, enabled. Last results per node (StatusRow), latency series chart, incidents for this check. Actions: Pause or Resume (T2, sends `{id, version, enabled}`), Delete (T4), Edit on web. A generated check (from a definition or `managed_by` probe configuration) shows none of these and reads "Generated by definition {name}: change it on web" with a link to M3-09. A 409 version conflict reloads and shows the current state. "All results" > M3-08.

**M3-08 CheckResultsScreen.** Paged results (`/api/monitors/results?monitor_id`), filterable by node and outcome.

**M3-09 DefinitionDetailScreen.** Definition fields, the pairs it generates, paused pairs and why (`packet_budget`). Actions: Delete (T4; the ConfirmSheet lists every monitor that goes with the definition and its history, and sends `version` plus exactly those `monitor_ids`); create, update, preview, forget on web.

**M3-10 IncidentsScreen.** Gate monitor:read. `.searchScopes`: Active (default), Acknowledged, Snoozed, Pending, Resolved, All. The screen fetches `GET /api/incidents` once with no `state` (all four server states, default limit 500) and applies the scope on device through Shared `IncidentFilter`, a port of `incidentsModel.ts` `matchesFilter` and `isSnoozed`: Active is open and acknowledged; Acknowledged is acknowledged; Snoozed is open or acknowledged where `isSnoozed`; Pending is pending; Resolved is resolved; All is everything. The console's Open chip (open minus snoozed) is the `state:open` search token. Rows are `IncidentRow` with its swipes, offered per `incidentActions` (acknowledge only when open, nothing for `pending:` ids). Section "Maintenance" lists active and upcoming windows > M3-13. Toolbar: Start maintenance (M3-12). Search: `kind:`, `node:`, `state:`, free text. Data `GET /api/incidents` (`{incidents, windows, durable, now}`) and `/api/maintenance-windows`. When `durable` is false, the footer says "Incidents are lost on a server restart". Stable-list rule (5.0).

**M3-11 IncidentDetailScreen.** Title is the short subject ("tokyo-1 to fra-2", "fra-2") with the state in `.navigationSubtitle`; the event sentence ("Path degraded: tokyo-1 to fra-2", "fra-2 offline") is the first row in `detailHeader` style. Header: severity and state words, subject (node or path link), opened at, duration, flaps. Evidence: the emitter's detail (last check result, last seen, loop health) and a link to the two-tap evidence (PathDetail chart or NodeDetail). Notification truth: "Notified via {channel} at {time}" or "Notification failed via {channel} at {time}" from each delivery's outcome, "Recovery still owed", suppression reason, escalations by rule. Deliveries for this incident from the Sent log (`/api/notify/deliveries?limit=200` filtered by `incident_ids`; channel, outcome, time) > M9-03; omitted with a ScopeDeniedRow without notify:admin. Timeline: opened, notified, acknowledged by, snoozed until, resolved. Maintenance window holding it, if any. Bottom toolbar: Acknowledge (or Unacknowledge), Snooze (the dialog of M1-01), Start maintenance; in a compact vertical size class Acknowledge and Snooze move into the navigation bar's trailing group and Start maintenance into its menu. Pending incidents show "Opens at {time} if still failing" and no actions. Resolved shows no actions. Ack errors stay on screen with Retry; the state word changes only after the server answers.

**M3-12 MaintenanceStartSheet.** Opens at `.large` (it has text entry). Fields: Name (required, prefilled "Maintenance {node} {time}", editable, the server's length limit enforced on device), subject (node or group, preselected from the caller), duration presets 30 min, 1 h, 4 h, Until (time picker), optional note (sent as `reason`). Validates on device that `ends_at` is in the future and at most 30 days after `starts_at`. Start is pinned in the bottom inset and is T2: "Start maintenance on {node}? Incidents for {node} are held and no alerts are sent until {time}. monitor:admin." Body `{name, node_ids or group_ids, starts_at, ends_at, reason}`. "Schedule on web" for anything else.

**M3-13 MaintenanceWindowScreen.** Window facts (subject, start, end, note, created by), incidents it holds. Actions: End now (T2; re-sends the full window as loaded with only `ends_at` set to now), Delete (T2 naming the window), Edit on web.

### 5.5 M4 Activity: tasks and audit

**M4-01 TasksScreen.** Gate task:read. Rows (`TaskRow`): task label or first script line, origin (`direct`, `approval` with `SealLabel`, `rerun`), status word, progress "12 ok, 2 failed", age. Running tasks first. Toolbar: range menu, "New task on web". Search tokens `status:`, `origin:`, `node:`, `approval:`. Data `/api/tasks` (envelope with filters), `/api/tasks/counts`.

**M4-02 TaskRunScreen.** Header: status word, origin (approval link with seal, rerun of a task, direct), creator, created, duration, script name, node count; progress line while live ("9 of 12 finished, 1 failed"). Per-node rows sorted failed, stalled, expired, running, finished, cancelled: node, status, exit code, attempts, lease age ("No heartbeat for 4 min" in warn for an old lease), duration, first stderr line. Swipe: Rerun on this node (T3). Toolbar: Cancel while running (T2); menu with Rerun (T3), Rerun failed nodes (T3; sequential `rerun-node` calls with per-node outcomes, and the sheet says "Each node becomes a separate task run"), Reveal script (S), Delete (T4), Open on web. Polls every 3 s while running and visible. Data: the task row from the TasksStore page that linked here, or, for a deep link, `/api/tasks?limit=200` searched by id (the endpoint has no id filter; show "Task not found in the last 200" with Open on web when absent), plus `/api/task-results?task_id={id}&omit_output=1`.

**M4-03 TaskNodeOutputScreen.** Full output for one node from `/api/task-results?task_id&node_id` in the read-only find-enabled text view (`code` style), with exit code and timing header; toolbar Copy, Share, Jump to end. Empty: "No output captured."

**M4-04 AuditScreen.** Gate audit:read. `.searchScopes`: Changes, All, Integrity (console `view=`). Rows: action in words, actor, object, decision, time. Integrity shows the last verification result and "Verify now" > M4-07. Toolbar: `RangeMenu` (sent as `at_from`, `at_to`), Export menu (CSV, NDJSON, audit head) building the file on device and presenting `ShareLink`. NDJSON lines are each event's raw JSON slice as received (Shared `fetchAudit` keeps it); CSV metadata comes from the raw `metadata` slice. The export pages to the end of the filtered range with a progress row; when `complete` is false the file's first line and the share title say "Partial: scanned {N} events". Search tokens `action:`, `actor:`, `decision:`, `node:`, `scope:`, `trace:`. Data Shared `fetchAudit` with `action`, `actor_id`, `decision`, `node_id`, `scope`, `correlation_id`, `q`, `limit=100`, offset paging; footer says when `complete` is false ("Scanned 10 000 events; refine to see older").

**M4-05 AuditEventScreen.** All event fields as DetailRows (action, actor, token, scope, decision, node, correlation id, time in both zones), the approval seal when the event references an approval, links to the node, task, approval and trace > M4-06.

**M4-06 CorrelationTraceScreen.** All events sharing a correlation id (`correlation_id` filter) in order, as a timeline.

**M4-07 AuditVerifySheet.** Runs `/api/audit/verify` and shows head hash, events checked, result (ok or the first broken link). Non-mutating, no confirm.

### 5.6 M5 Inventory and upcoming

**M5-01 InventoryScreen.** Fleet scope "Machines". Gate inventory:read. First row: "Upcoming: {n} due in 30 days" > M5-05. Header: monthly spend total in the primary currency, per-currency totals when mixed. Group menu (Region, Country, Role, Group, Status, Tag, None). Row: machine name, vendor, monthly equivalent, renewal countdown ("renews in 6 days" in warn under 7 days, fail when overdue). Swipe Renew (T2 > M5-03). Toolbar: Reminders (M5-04), "New machine on web". Search: `vendor:`, `region:`, `node:`, free text. Data `/api/machines`, `/api/machine-vendors`.

**M5-02 MachineDetailScreen.** Vendor, plan, price and cycle, monthly equivalent, next renewal, linked nodes (StatusRows), notes. Actions: Renew (T2), Reveal console link (S; the value step offers Copy and "Open" in `SFSafariViewController`, never `openURL`), Delete (T4), Edit on web.

**M5-03 RenewSheet.** Medium detent. Machine name, current renewal date, new date prefilled from the cycle, editable date picker. Save is T2 ("Record renewal of {machine} until {date}").

**M5-04 RemindersSheet.** The preview (which machines a reminder fires for today, and the next reminder date when none does) is computed on device from `/api/machines` by AstraCore `ReminderSchedule`, a port of the console's `views/fleet/reminderModel.ts` (default offsets 14, 7, 3, 1, 0 days). "Send reminders" is T2 naming the count and calls `POST /api/machines/reminders/run`; results list each fired reminder from the `fired` array.

**M5-05 UpcomingScreen.** Pushed from Machines, Inbox and Browse. Gate any read scope of the item kinds. Kind filter in a toolbar `FilterMenu`: All (default), Machines, VPN users, Shares, Certificates (console `kind`). Rows by due date: item name, kind glyph, due in words. Machine rows swipe Renew (T2). Footer lists hidden kinds the token cannot read. Data `/api/expiring?within=30d` (`{items, totals, hidden_kinds}`).

### 5.7 M6 Networking

**M6-01 OutboundPolicyScreen.** Gate netpolicy:read. `AdaptiveSegmentedPicker`: Policies, Nodes, Matrix (console `view=`). Toolbar: "Plan all group policies" (P, as in M6-02). Policies: group policies with member count and last plan state. Nodes: per-node policy (manual, outbound, none) with state. Matrix: egress or ingress reachability (`/api/netpolicy/matrix?direction`) rendered as a list per source ("tokyo-1 can reach 12 of 34") > NodePolicy. Data `/api/netpolicy`, `/api/group-policies`, `/api/netpolicy/matrix`.

**M6-02 PolicyDetailScreen.** Group policy rules (read), member nodes, last plan per node. Actions: "Plan all group policies" (P; `POST /api/group-policies/plan {}` plans every node covered by any enabled group policy, so the ConfirmSheet says so and lists covered nodes as "will try"; the result step lists filed approvals, conflicts, orphaned nodes and selector impacts, and any conflict or orphan is `.partial`), Edit on web, Delete on web.

**M6-03 NodePolicyScreen.** One node's policy and rules; actions Plan node policy (P), Convert manual policy (T3 then P, shown when the node has a manual policy: "Creates group policy {name} directly, then files a plan for {node}"; `name` and `priority` optional; the result shows the created policy and the approval if one was filed), Edit on web.

**M6-04 DNSScreen.** Gate dns:admin. Deployments with drift state, certificate watch (days left), publish errors. Data `/api/dns/deployments`.

**M6-05 DNSDeploymentScreen.** Deployment fields, allowed clients, drift details, certificate, publish history. Actions: Plan (P; 409 lockout findings listed; "Accept lockout risk" toggle unchecked), Publish IPs (T3, body `{id}`; hidden for external-engine or disabled deployments; the preview is computed on device and labelled as such: old is the deployment's `last_ipv4`/`last_ipv6`, new is the node's `public_ip`/`public_ipv6`, "Will publish the node's current address {ip}; the provider has {last_ipv4}"), Measure certificate (T2: "Creates a TLS check on {host}:{port} and links it to {deployment}"; needs dns:admin and monitor:admin on a token without a node allowlist; disabled with that reason for confined tokens; marks checks dirty), Edit and Delete on web.

**M6-06 DDNSScreen.** Gate ddns:admin. Sections Failing, Stale, Current (Shared `DDNSProfile.health(now:)`). Row: profile name, record, provider, last run, last error. Swipe Run now (T3). Data `/api/ddns`.

**M6-07 DDNSProfileScreen.** Profile fields (record, type including CNAME, provider), last runs. Actions: Run now (T3 naming profile and record, with the on-device preview of the address it will publish), Delete (T4), Save on web.

**M6-08 GeoRoutingScreen.** Gate geo:read. Routes with their DNS nodes. Data `/api/geo-routing`.

**M6-09 GeoRouteScreen.** Route fields, DNS nodes, Preview config (read, monospaced view). Actions: Delete (T4), Edit on web.

**M6-10 TunnelsScreen.** Gate tunnel:admin. cloudflared tunnel profiles with node and ingress count. Data `/api/tunnels`.

**M6-11 TunnelScreen.** Ingress rules, node, last plan. Actions: Plan (P), Delete (T4), Create on web.

**M6-12 InboundFirewallScreen.** Gate netguard:read for groups, zones and nodes; the bindings and node-group-bindings sections need netguard:admin (ScopeDeniedRow otherwise). Opened with a node id from NodeNetwork, it filters to that node. Security groups, zones, bindings and node-group bindings, reality-check state per node. Data `/api/netguard/groups`, `/zones`, `/nodes`, `/bindings`, `/node-group-bindings`. Toolbar "Open plugin page on web". All writes on web.

**M6-13 SecurityGroupScreen.** Group rules and bound nodes or node groups. Read only, Open on web.

### 5.8 M7 SSH Guard and agent updates

**M7-01 SSHGuardBoardScreen.** Gate `sshguard:read` and `network:plan` (sshguard:admin satisfies the read); without both the whole screen is `ContentUnavailableView("Needs sshguard:read and network:plan")`, never an empty list. Under `server_allowlist` the header reads "Visible nodes only". Filter: a toolbar `FilterMenu` with Posture (All, Password login open, Partial, Unknown, Secured) and Coverage (All, Reverting, Arm pending, Not armed, Failed, Confirmed, Excluded) sections, both default All and not restored, shown as tokens and in `.navigationSubtitle`. Sections: Confirm needed (`reverting` with the countdown to `revert_deadline`), Password login open, Partial, Secured, Excluded. Row: node, posture word, coverage word, knock state. Swipes (only with sshguard:admin): Arm (opens M7-05) or Confirm (P; when `actionable_approval_id` is set it opens that approval in Review instead of filing a duplicate). Data Shared `fetchSSHGuardStatus` and its derivation.

**M7-02 SSHGuardNodeScreen.** Same gate. Posture facts (sshd settings from `SSHGuardSSHDFacts`), knock view, arm and confirm history, revert countdown from `revert_deadline` while `reverting`. Actions: Arm (M7-05), Confirm (P, prominent while reverting; opens `actionable_approval_id` when set; Review then states "Must be approved and applied before {deadline}"), Reveal knock sequence (S; sshguard:read plus network:plan on the session), Rotate knock (M7-05 in rotate mode), Exclude node (T3 via capability, M2's `POST /api/nodes/capabilities`).

**M7-03 AgentUpdatesScreen.** Gate node:admin. `AdaptiveSegmentedPicker`: Nodes, Distribution, Mirrors; opened with a node id it filters Nodes to that node. Nodes: per-node running version against target, last fetch, behind count, policy; toolbar "Plan all behind (n)" (P; one intent whose `perform` posts `{node_id, force: false}` per node sequentially through Shared `planAgentUpdate`; the ConfirmSheet lists the nodes as "will try"; per-node 409s are the refused half; the filed approvals open in BatchReview with the refusals in its header); swipe Plan update (P). Distribution: releases and artifacts > M7-04. Mirrors: registry and each node's source order (read), "Mirror plan on web". Data `/api/nodes/agent-updates`, `/releases`, `/artifacts`, `/mirrors`.

**M7-04 AgentReleaseScreen.** Release version, artifacts by platform with digests, compatibility floors. Read only.

**M7-05 SSHGuardArmSheet.** Opens at `.large`. Arm mode: node (fixed), `ssh_port` shown explicitly, `enable_knock`, `mgmt_sources`, `confirm_window_sec` and `out_of_band_fallback`, prefilled from the server's verified defaults (the console's default arm form) or this node's last arm parameters, each shown field by field with its consequence ("Password login stays open until you confirm"). File plan is P: `POST /api/sshguard/plan`; a 409 with lint findings moves to the Findings step listing them with an unchecked "Accept findings" toggle, and `accept_findings: true` is sent only when it is checked. Rotate mode: the sheet reads knock state (`POST /api/sshguard/knock`); when `rotateEligibility` needs the current digest it runs a RevealIntent for `sequence_sha256` first (S, steps inside this sheet), then files `POST /api/sshguard/plan` with the body from `buildRotationRequest` (`rotate_from_sha256`). No second sheet opens.

### 5.9 M8 Platform

**M8-01 PluginsScreen.** Gate audit:read (the `/api/plugins` route requires it; plugin:admin alone gets 403). Rows: plugin name, version, lifecycle state, health, risk level. Data `/api/plugins`, `/api/plugin-contributions`, `/api/plugin-trust`.

**M8-02 PluginDetailScreen.** Manifest facts, capabilities and scopes per method, risk, contributions (pages, approvals kinds), health history. Actions: Activate or Disable (T3), Install and Verify on web. Plugin pages it contributes: native kinds > M8-03, others Open on web.

**M8-03 ExtensionPageScreen.** Renders a third-party plugin page of kind table or detail natively from the manifest model used by `PluginView.vue` (columns, fields, actions that call `/api/plugins/call`). Actions in the manifest that write are W. Unknown kinds show "Open on web".

**M8-04 PublishingScreen.** Gate any of kv:read, static:read, proxy:admin. `AdaptiveSegmentedPicker`: Overview, Routes, Tokens, Buckets; origin filter in a toolbar `FilterMenu` (All, KV, Static, Share), shown as a token. Share rows need proxy:admin (`/api/subscription-shares`); without it they are a ScopeDeniedRow. Routes: published routes and shares; swipe Delete binding (T4). Tokens: storage tokens; swipe Revoke (T4). Buckets: list > M8-09. Data `/api/publishing/records`, `/api/storage/{buckets,bindings,tokens}?kind`, `/api/subscription-shares`.

**M8-05 ShareDetailScreen.** Share facts (owner identity, expiry, interval, last refresh, hits). Actions: Reveal URL (S, then Share), Rotate (T3), Refresh (T2), Delete (T4), Edit expiry on web.

**M8-06 BindingDetailScreen.** Route, bucket, origin, created. Delete (T4).

**M8-07 StorageTokenDetailScreen.** Token name, buckets, scopes, created, last used. Revoke (T4).

**M8-08 StoreScreen.** Gate kv:read or static:read. KV and Static buckets. Data `/api/storage/buckets?kind`.

**M8-09 StoreBucketScreen.** Keys or objects with size and modified time; search by key prefix. Data `/api/kv?bucket`, `/api/static?bucket`.

**M8-10 StoreEntryScreen.** Metadata; the value loads on tap into the find-enabled text view (text) or a size and type summary (binary). Never cached. Put and Delete on web.

**M8-11 SystemScreen.** Gate `*`. Control-plane host, process, data files, store sizes, HTTP routes with latency, plugin performance, probe status, from `/api/system/health` and `/api/system/series` (range menu 1h to 5y). Read only.

**M8-12 ExtensionsScreen.** Every plugin page contribution from `/api/plugin-contributions`, grouped by plugin; table and detail kinds push M8-03, other kinds are WebLinkRows.

### 5.10 M9 Notifications and webhooks

**M9-01 NotificationsScreen.** Gate notify:admin (every `/api/notify` read requires it). `AdaptiveSegmentedPicker`: Routing, Sent. Routing: channels (telegram, bark, discord, webhook) with health and fallback, rules (event, channels, quiet hours), witness status with "Plan witness" (P). Sent embeds M9-02. Data `/api/notify/channels`, `/api/notify/rules`, `/api/notify/witness`, `/api/notify/catalogue`.

**M9-02 SentLogScreen.** Deliveries newest first: title, channel, outcome word (sent, failed, held, not routed), time, repeats. Filters in a toolbar `FilterMenu`: outcome, channel, event type, sent as `outcome`, `channel_id`, `event_type` (console URL names mapped once in Shared `DeliveryQuery`). Data Shared `fetchDeliveries`. Footer: stored count and durability ("History is lost on restart" when not durable).

**M9-03 DeliveryDetailScreen.** Title and body as sent (truncation noted), channel, rule, role and fallback, attempts with outcomes and times, held until, linked incidents > IncidentDetail.

**M9-04 ChannelDetailScreen.** Kind, health, last delivery, fallback. Actions: Send test (T2), Delete (T4), Edit on web. "Test send (needs notify:send) on web" row.

**M9-05 RuleDetailScreen.** Rule fields, channels, quiet hours, recent matches. Edit and delete on web.

**M9-06 WebhooksScreen.** Gate notify:admin. Inbound webhooks with last delivery and "reaches nobody" warning. Data `/api/notify/webhooks`.

**M9-07 WebhookDetailScreen.** Fields (no secret), recent deliveries (`/api/notify/webhooks/deliveries`). Actions: Test (T2), Delete (T4); create, edit, rotate secret on web.

### 5.11 M10 Evidence

**M10-01 EvidenceScreen.** Pushed from Browse > Platform. Gate log:read. Recording readiness per node (ready, missing, recording), active capture sessions with node, start and remaining time, budget use. Row swipe: Start capture (T2, duration presets 5, 15, 60 min; body `{name: "phone {node} {time}", filter: that node's id, level: the console's default, ttl_seconds: the preset}`; dialog "Records connection metadata for users on {node} for {duration}") or Stop (T2). Collection layer "Open on web". Data `/api/trace/sessions`, `/api/logs/sources`, `/api/logs/stats`, `/api/evidence/settings` (budgets, read when allowed).

**M10-02 ConnectionsScreen.** Connection records with filters node, user, dst, line, session (console filter names) in a toolbar `FilterMenu` and as search tokens; rows: src to dst, protocol, bytes, duration, time. Data `/api/trace/connections`.

**M10-03 ConnectionDetailScreen.** Record fields, hops (`/api/trace/hops`), markers, links to node, line and user.

**M10-04 LogExplorerScreen.** Source picker, query field (`/api/logs/query` search), log lines in `code` style, newest at the bottom with "Load older" (`before_seq`), find, copy line.

### 5.12 M11 Account and access

**M11-01 SecurityScreen.** Pushed inside the Settings sheet. Session endpoints: requires a session credential; with PAT only, `ContentUnavailableView("Needs a signed-in session")` linking to F-06. Shows TOTP state, MFA required, passkeys list. Change password, TOTP enroll, activate, disable and Add passkey are W rows.

**M11-02 PasskeyDetailScreen.** Name, created, last used. Rename (T2), Delete (T4 plus step-up when TOTP is on: confirm, Face ID and code are steps of one ConfirmPage flow inside the Settings sheet).

**M11-03 AccessScreen.** Pushed inside the Settings sheet. `AdaptiveSegmentedPicker`: Users, Tokens, SSO (gates user:admin, token:admin, oidc:admin). Users: name, role, MFA. Tokens: name, scopes count, allowlist, last used, revoked state; swipe Revoke (T4). SSO: providers with test state. Create rows are W.

**M11-04 UserDetailScreen.** Fields read only; Edit and Delete on web.

**M11-05 TokenDetailScreen.** Scopes (with descriptions from the scope catalogue in AstraCore), allowlist, created, last used. Actions: Revoke (T4), Delete (T4). If it is the token this phone uses, the confirm sheet says "This is the token this iPhone uses. You will be signed out."

**M11-06 SSOProviderScreen.** Provider fields (no secrets), last test. Edit, delete, test on web.

### 5.13 M12 Terminal

**M12-01 TerminalSessionsScreen.** Gate terminal:open (also required to list sessions and read transcripts; only the Operator plus root preset holds it). Sessions with node, creator, state (open, closed), transport (stream, poll), started, last activity. Swipe Close (T2). Toolbar "New session on web" (`/terminal?node_id=`). Data `/api/terminal/sessions`.

**M12-02 TerminalTranscriptScreen.** Read-only transcript from `/api/terminal/sessions/{id}/events?cursor`, polled every 3 s while the session is open and visible. ANSI escape sequences are stripped by AstraCore `TranscriptCleaner` (CSI, OSC and charset sequences removed, carriage-return overwrite resolved per line); when an alternate-screen sequence (`ESC[?1049h`) appears, a row says "A full-screen program is running. Open on web to see it." Find, copy. Toolbar: Close session (T2), Open on web.

### 5.14 M13 VPN

**M13-01 VPNUsersScreen.** Gate proxy:read or vpncore:read. Identities with status (active, expired, over quota), bound lines, usage this period, expiry. Data Shared `callPlugin(id: "latticenet.vpn-core", service: "latticenet.vpn-core/users", method: "list")`, falling back to `/api/proxy/users`. Decode failures show companion behind.

**M13-02 VPNUserDetailScreen.** Identity fields, bound lines, devices, usage summary. Link status from `GET /api/vpn/users/{id}/link`. Actions: Reveal subscription link (S; `POST /api/vpn/users/{id}/link/reveal {step_up_grant}`, vpncore:admin or proxy:admin on an unconfined session; Share allowed), Reveal credentials (S; `POST /api/proxy/users/reveal-credentials`, proxy:admin), Rotate link (T3, "The old link stops working at once"; `POST /api/vpn/users/{id}/link/rotate`), Revoke link (T4; `DELETE /api/vpn/users/{id}/link`); create, bind and cutover on web.

**M13-03 VPNLinesScreen.** Lines with chain health (M3's `/api/network/lines/chains` call) and user counts.

**M13-04 VPNLineDetailScreen.** Line facts and its chain hops with path states (links to PathDetail). Plans and rollouts on web.

---

## 6. Interaction patterns

### 6.1 Approval review (the hash-bound contract, preserved exactly)

The v3 sheet is a port of `ApprovalReviewView` in `AstraApp/App/ReviewSheet.swift`. The AstraCore pieces stay as they are, moved but not changed in behavior: `PlanHasher.sha256Hex`, `Approval` (`isHumanPending`, `isApprovable`, `isAutoApprovedLineMeta`, `isSSHGuardConfirm`, `isSSHGuardArm`, `planHashMatchesServer`, `reviewedPlanSHA256()`, `proofLine`), `ApprovalWaiting` (including `dismissible`), `ApprovalReviewError`, `ApprovalReviewDecoder`, and the client calls `fetchApproval(id:)`, `approveApproval(approvalID:queueApply:planSHA256:)`, `approveReviewed(_:queueApply:)`, `rejectApproval(approvalID:)`, `dismissApproval(approvalID:note:)`, `listHumanPendingApprovals()`, `countApprovals()`. Their names are frozen (section 8.4). The sequencing below lives in AstraCore `DecisionFlow` (Domains/Approvals, M1) with an injected `DecisionAuthenticator`, so a MockTransport check proves that a cancelled authentication sends zero requests; the sheet is the UI around it.

The sequence, step by step:

1. **Load by id.** `GET /api/network/approvals?id={id}` decoded with `ApprovalReviewDecoder.decodeEnvelope` (fail-closed on missing `id`, `plan_sha256` or `status`). A listing row's `plan` is never displayed or hashed. A 404 reads "Not found, or not visible to this token" with a "Token scopes" button.
2. **Companion behind.** If the body cannot be decoded (`LatticeAPIError.invalidResponse` or a decoding error), the sheet shows "This app is behind the server. The approval could not be read, so Approve is off." with Reload and Open on web, and no decision buttons. `SessionStore.markCompanionBehind()` records it for Diagnostics.
3. **Hash what is on screen.** The plan view's text is exactly `approval.plan`. `approval.reviewedPlanSHA256()` runs on load. Success sets the proof strip to verified (`checkmark.seal.fill`). `ApprovalReviewError.emptyPlan` or `.hashMismatch` sets it to mismatch (`xmark.seal.fill`), disables Approve, and shows the error text with Reload. Reject stays available on mismatch (rejecting what you cannot verify is safe).
4. **Eligibility.** Approve is enabled only when all hold: `approval.isApprovable` (human pending, not stale, has a body), the hash verified, not companion behind, the token holds `network:apply` and the plugin's decision scope from `ApprovalVisibility.decisionScope(for:)` (section 6.12), and no decision is in flight. When disabled, the decision panel states why in wrapping text: "Stale: inspect only", "This app is behind the server", "Plan does not match its hash", "Deciding needs network:apply and sshguard:admin", "No longer pending". Face ID never runs for a decision the token cannot make.
5. **Stale rows are inspect-only for approve and reject.** No Approve or Reject. "Inspect-only" means exactly that; two other actions are allowed and recorded in 10.2 for sign-off: Dismiss when `canDismiss` (the server restricts dismissal to stale agent-update and SSH Guard rows), and "Replan" on a stale agent-update row (P tier: the ConfirmPage is pushed inside the Review sheet's own stack, and on `.filed` the sheet replaces its target with the new approval and reloads, never opening a second sheet).
6. **Before authentication.** The object (action, node or target count) and the seal are already visible in the sheet. Face ID devices do not display `localizedReason`, so the screen carries that information, not the prompt.
7. **Authenticate.** `IntentAuth.confirm(reason:)` with `.deviceOwnerAuthentication` and a fresh `LAContext` per decision. Reasons: "Approve {action} on {node}, plan {seal}", "Reject {action} on {node}", "Dismiss {action} on {node}". The reason appears on Touch ID devices (iPhone SE) and on the passcode fallback. `.failure(.cancelled)` sends nothing, shows nothing, and plays no haptic. `.failure(.failed)` shows the message in place.
8. **Send.** Approve posts `{approval_id, queue_apply, plan_sha256}` where `plan_sha256` is `reviewedPlanSHA256()` recomputed at send time from the same on-screen body, and `queue_apply` is the visible "Apply after approval" toggle (replacing today's "Queue apply after approval" toggle, same meaning, same default on).
9. **Verify the transition.** After every decision the sheet reloads by id and compares the reloaded `status` and the decider fields the view carries (`approved_by`, `rejected_by`, whatever `api-shapes.md` records for dismissal) with the transition requested and this credential's actor, because the server answers 200 with the unchanged view when the approval was already decided. On a match: `waiting` shows "Approved, waiting: {reason}" when `blocked`, "Approved, apply in progress: {reason}" otherwise, "Approved and queued." or "Approved; apply not queued." when there is no waiting record; "Rejected."; "Dismissed.". On a mismatch the outcome is `.refused(.alreadyDecided(status:by:at:))`: "Not recorded: this plan was already {status} by {who} at {time}.", haptic `.error`, never green. `ChangeLog.record(.approvals)` refreshes Inbox and the badge either way.
10. **Stale on the server.** On approve, 409 `approval_stale` reads "This plan changed since you opened it." The sheet reloads by id, re-hashes, and returns to the undecided state. It never retries the decision. Haptic `.error`. On dismiss, 409 `approval_stale` means the row is not dismissible ("approval is not stale"): "Not dismissible: approve or reject it."
11. **Reject.** Face ID, then `POST /reject {approval_id}`, then step 9.
12. **Dismiss.** Shown only when `canDismiss(approval)`: `approval.waiting?.dismissible` when a waiting record exists, otherwise the fallback (`isStale`, or plugin `sshguard` or `agentupdate`). Choosing Dismiss reveals a required note field in the sheet (prefilled "No longer needed", must be non-empty after trimming), then Face ID, then `POST /dismiss {approval_id, note}`, then step 9.
13. **In flight.** `.interactiveDismissDisabled(true)` and the Close button disabled while a decision runs. `Router.present` requests and deep links arriving now are queued until the decision ends.
14. **Read-only tokens.** Without the decision scopes the plan, proof strip and waiting section render normally and the decision panel names both missing scopes; the toolbar holds no decision buttons.

### 6.2 Batch review

- **Grouping.** AstraCore `ApprovalEvents.group(_:)` ports `groupApprovalsIntoEvents` from `lattice-dashboard/src/views/operations/approvalsModel.ts`: key `writer | plugin | actionPrefix | kind | current→target`, with the agent-update version transition parsed from plan text the same way. A golden check feeds the console's test cases.
- **Entry.** An Inbox group row with more than one approval, the Approvals "Needs you" group rows, and the P-tier outcome of "Plan all behind" (the ConfirmSheet dismisses, then BatchReview is presented from its `onDismiss`).
- **Load and hash every body.** Each id is loaded by `GET ?id=` (at most four requests in flight) and hashed with `reviewedPlanSHA256()`. A row that fails to load, mismatches, is stale, or lacks the decision scope is marked with its reason and excluded; the button count drops ("Approve 13") and the excluded rows stay visible.
- **On screen.** Every distinct body (grouped by `plan_sha256`) is shown inline in a non-scrolling `PlanTextView`, each with its seal and the list of nodes that share it. Offline target nodes are flagged. Everything being approved is on the sheet.
- **One decision.** One Face ID with reason "Approve 13 plans: {group title}". Then approve each included row (two in flight), each with its own `plan_sha256`, and verify each transition as in 6.1 step 9. Reject all works the same way.
- **Results.** Each row shows done, refused (with the code, including already decided by someone else) or failed. Mixed results produce `.partial` (haptic `.warning`, banner "11 approved, 2 not recorded" with a chevron to the sheet). No green outcome on partial success. Each approved row is reloaded by id for `waiting`.

### 6.3 Face ID

`IntentAuth` (moved to `Safety/IntentAuth.swift`, unchanged API, conforming to AstraCore's `DecisionAuthenticator` and `WriteAuthenticator`) gates every D, T3 and T4 action, T3 and T4 undo, and the app lock. Rules: a fresh `LAContext` per action, no reuse window; the object is visible before authentication; cancelled sends nothing; when device authentication is unavailable the action is refused with the system's message (the app never falls back to "no authentication"). `NSFaceIDUsageDescription`: "Lattice uses Face ID to confirm approvals and privileged changes." In demo mode only, `-AstraAuth succeed|cancel` substitutes a stub authenticator so agents can capture after-states (section 9.2).

### 6.4 Step-up with TOTP

- Needed for every S action. The server accepts step-up only on a session (cookie plus `X-Lattice-CSRF`), so S requests always run on `revealClient`, never the PAT client.
- `ActionRunner.reveal(_ intent: RevealIntent)` presents F-13 at the root (or pushes its steps inside the current sheet) and drives `StepUpCoordinator` (M0b, `Session/`), which exposes `func grant(for purpose: StepUpPurpose) async throws -> StepUpGrant`. If a grant is held and `expires_at` is more than 5 s away, it is reused (the server's `stepUpGrantHeld` does not consume grants). Otherwise the Code step posts `POST /api/security/step-up {code}` and keeps `{grant, expires_at}` in memory only.
- The S request carries `step_up_grant` in its JSON body (for example `POST /api/sshguard/knock/reveal {node_id, step_up_grant}`).
- Errors are decoded from the server's envelope for every status (section 8.3). A 401 from `/api/security/step-up` is `.refused(.validation("Wrong code"))` and never marks the session expired. A refusal with `step_up_required` clears the grant and returns to the Code step once; a second refusal shows the server's message. `secret_reveal_scope_required` shows the missing scope.
- TOTP replay protection is per account across devices: the coordinator remembers the 30 s step of the last code this phone sent and shows "Wait for the next code"; a code used in the console the same step is refused as wrong and the copy says so (F-13).
- Without a session: F-13 offers "Sign in for reveals", then continues to the Code step with the next code. Accounts without TOTP or with `mfa_required` get the explicit states of F-06. Nothing fails silently.
- A revealed value goes straight into F-14 and is never stored.

### 6.5 Write tiers and confirmation

| Tier | Used for | Gate before the request | After |
|---|---|---|---|
| T1 | Acknowledge, unacknowledge, snooze, end snooze, from a row or detail toolbar that names the incident. This is the brief's one exception to stating scope before a write: the swipe label and its accessibility hint state the consequence ("Snooze 1 h: no repeat alerts until {time}"), and the banner restates it. | The swipe or button itself | OutcomeBanner with Undo (verified inverse) |
| T2 | Consequential, reversible writes (enable node, bulk enable, edit identity, add or remove static group members, geo clear and resolve, agent debug, cancel task, renew, reminders send, check pause and resume, maintenance start, end and delete, channel test, webhook test, share refresh, capture start and stop, terminal close, passkey rename, measure certificate, sign out) | `confirmationDialog` with `titleVisibility: .visible`, attached to the list or screen (never to a row), whose title names verb and object and whose message states the consequence and the scope ("Pause check tls-api? No results or incidents until resumed. monitor:admin.") | Banner; undo only where a verified inverse exists |
| T3 | Privileged writes (disable node, bulk disable, rotate node token, capability enroll or exclude, beacon rotate, gate enforce, plugin activate or disable, task rerun, rerun node, DDNS run, publish DNS IPs, share rotate) | ConfirmSheet (object, consequence, scope, blast radius) then Face ID | Banner; the object is re-read and shows the server's new state |
| T4 | Irreversible writes (delete node, machine, check, definition, group, DDNS profile, geo route, tunnel, task, binding, share, channel, webhook, passkey; revoke or delete token; revoke storage token) | ConfirmSheet with the dry run first where the server has one (`/api/nodes/delete/plan`), the primary button carrying the object name ("Delete node edge-tyo-3"), destructive role, a typed object name where the intent sets `confirmPhrase`, then Face ID | Banner; the row disappears only after the server confirms |
| P | Plan filing ([A] actions) | ConfirmSheet listing what will be filed and for which nodes ("will try" where the server decides per node), explicit acceptance toggles, and the 409 findings loop (8.3). No Face ID: the approval is the gate | `.filed(approvalIDs:refused:notes:)`: one id and no refusals opens Review; several open BatchReview with refusals listed; any refusal or orphan is `.partial` styling (warning haptic, no green) |
| D | Approve, approve only, reject, dismiss | Section 6.1 | Reload by id, verify the transition, show waiting |
| S | Reveals | Step-up (6.4) inside RevealFlow | F-14 |

Every tier except T1 states object, scope and consequence before the request. Offline disables the primary button with "No connection". A write that needs a missing scope never reaches the gate: its control is disabled with "Needs {scope}".

**One sheet at a time.** A flow presents once and advances in place: ConfirmSheet steps (confirm, authenticate, findings, result or one-time reveal); RevealFlow steps (code, value). An action started inside a sheet pushes `ConfirmPage` or the RevealFlow steps on that sheet's own stack. A sheet that must hand off to another (ConfirmSheet to BatchReview) dismisses and presents the next from `onDismiss`. `Router.present` dismisses whatever is presented first (2.4).

### 6.6 Undo

- Verified inverses only: acknowledge and unacknowledge (unack returns 409 once the incident closed; the banner then says "Already resolved"); snooze and its inverse (if the incident was snoozed before, the inverse re-snoozes to the previous `snoozed_until`, minutes rounded up from now; otherwise `minutes: 0`); disable and enable.
- Undo inherits the tier of the inverse action. T1 and T2 inverses run from the banner without another dialog (the banner names the object). A T3 inverse (undoing Enable runs Disable) runs `IntentAuth` with the reason "Disable edge-tyo-3" before sending; no sheet is needed because the banner already names the object and consequence.
- The banner shows Undo for 10 s with the timer rules of F-16, and the accessibility announcement reads the outcome and "Undo available".
- After the banner goes, the inverse stays reachable in the object's row menu and detail toolbar.

### 6.7 Outcomes and partial failure

- `WriteOutcome` and `RefusalCode` are defined in section 8.3. Refusal codes: `stepUpRequired`, `secretRevealScopeRequired`, `approvalStale`, `alreadyDecided(status:by:at:)`, `notDismissible`, `forbidden(scope: String?)`, `conflict(findings: [String])`, `managed(by: String)` (generated checks), `versionConflict`, `notFound`, `validation(String)`.
- `approval_stale` maps per endpoint: on approve it is `approvalStale` (re-review); on dismiss it is `notDismissible`.
- A timeout or lost connection after the request was sent is `.unknown`: the runner calls the intent's `verify` closure and reports what the server now says ("Could not confirm. edge-tyo-3 is now disabled."), and never retries a non-idempotent call. Idempotent writes (ack, unack, snooze, enable, disable, renew with an explicit date, pause, resume) may be retried once by the operator from the banner; rotations, reruns, plan filings, reveals and deletes are never retried automatically.
- Reads (GET) retry twice with 1 s and 3 s backoff, each with the client's 15 s timeout.
- Bulk actions show per-item results; the list updates item by item as the server confirms.
- A 403 after load re-fetches `/api/me` for that client, switches that section to denied, and drops its data so nothing stale looks current.

### 6.8 Refresh and polling

Only visible screens poll, in the foreground, through the fixed idiom `.task(id: PollKey(changes.version(.nodes), interval)) { await store.refresh() }` driven by `Polling.every(_:)`, so polling stops when the view disappears or the scene leaves `.active`, and a ChangeLog bump refetches at once.

| Surface | Normal | Low Power Mode | Notes |
|---|---|---|---|
| Inbox | 15 s | 60 s | Also refreshes the badge; stable-list rule (5.0) |
| Running TaskRun, open terminal transcript | 3 s | 10 s | Stops when the task finishes or the session closes |
| NodeDetail Overview | 15 s | 60 s | |
| Paths, Matrix, PathDetail | 60 s | 120 s | Heavy payload (`/api/monitors/paths`) |
| Incidents, Checks, Overview | 30 s | 60 s | Stable-list rule |
| Every other list and detail | 60 s | 120 s | |
| Anything in background | none | none | BGAppRefresh badge only |

Pull to refresh is always immediate. After a failed poll the interval doubles up to 5 min and resets on success. Returning to the foreground triggers an immediate refresh of the visible screen. `ProcessInfo.isLowPowerModeEnabled` is observed through `NSProcessInfoPowerStateDidChange`.

### 6.9 Background badge refresh

- Registered task `org.roobli.astra.refresh` (already in `Info.plist`), scheduled with `BGAppRefreshTaskRequest` and `earliestBeginDate` 15 minutes out, only while Badge refresh is on and badge authorization is granted. iOS decides whether it runs.
- The handler reads only the PAT from the Keychain (`AfterFirstUnlockThisDeviceOnly`, so it works while the phone is locked after first unlock; it never reads a session), fetches human-pending approvals and `GET /api/incidents?state=open,acknowledged`, computes the badge with Shared `BadgeCount.compute(approvals:incidents:)` (the same function Inbox uses), calls `UNUserNotificationCenter.current().setBadgeCount(_:)`, stores `badgeSourceAt` in `UserDefaults`, reschedules, and finishes before expiration (the expiration handler cancels the requests).
- In the foreground, every Inbox refresh updates the badge too. Without `monitor:read`, the badge counts approvals only, and approvals hidden by `ApprovalVisibility` are not counted; BadgeRefresh says both. Sign out sets the badge to 0.
- The app never posts local notifications and never claims to alert.

### 6.10 Contextual permissions

- Badge authorization: only from BadgeRefresh (F-08), options `[.badge]`.
- Face ID: the system prompt appears at the first decision, with the usage description.
- No camera, location, contacts or local network permission in v3.

### 6.11 Offline and stale data

- `NetworkMonitor` (M0b) wraps `NWPathMonitor` behind a `NetworkPathSource` protocol so demo can substitute it. Unsatisfied: polling stops, every freshness footer switches to "Offline. Showing data from {time}", write buttons disable with "No connection", the verdict line says "Cannot confirm. Offline since {time}."
- Stale is defined once, in AstraCore `Freshness`: data is stale when `now - loadedAt > 3 × pollInterval` or the last attempt failed. Every module uses it.
- Server data is held in memory only. Nothing from the server is written to disk in v3, so a relaunch starts with placeholders and refreshes.

### 6.12 Scope model

- `SessionStore` holds `tokenScopes` and `sessionScopes`, each from `/api/me` on its own client (`scopes[]`, `server_allowlist[]`). AstraCore `ScopeSet` ports `rbac.directlyAllows` and `rbac.compatibleScopes` exactly: `*`, `<area>:*` prefix wildcards, the explicit-only rule (`secrets:reveal` is satisfied only by naming it), and the alias table (`sshguard:admin` satisfies `sshguard:read`; `vpncore:read` satisfies `proxy:read`; `proxy:read` satisfies `vpncore:read` and `substore:read`; the same three for `:admin`). No other admin scope implies read. Golden cases come from `internal/rbac` tests.
- Each `WriteIntent` and `RevealIntent` declares the client it runs on (`.primary` or `.session`) and all scopes it needs; S intents and session-only account endpoints are gated by `sessionScopes`, everything else by the scopes of the primary client. Non-S writes never run on the session while a PAT exists.
- AstraCore `ApprovalVisibility` mirrors `approvalPrimaryScopeAllows` and `approvalDecisionExtraScope` from `server.go` as a table keyed by plugin and action: the read scope that lets a token list an approval (for example `sshguard` needs `sshguard:read` plus `network:plan` on every target; `agentupdate` `node:admin` plus `network:plan`; `nftpolicy` `netpolicy:admin`; `selfdns` `dns:admin` plus `network:plan`; proxy and line plans an unconfined `proxy:read` plus `network:plan`; witness `notify:admin` plus `network:plan`; beacon `monitor:read` plus `network:plan`; `cftunnel` `tunnel:admin`) and the extra decision scope (`netguard:admin`, `sshguard:admin`, `netpolicy:admin`, `node:admin`, `dns:admin` and the rest as the function lists). Golden checks pin it against cases copied from the server tests. It drives the Needs you footer, the badge note, the verdict's partial coverage and Approve eligibility.
- Each screen and section declares `ScopeRequirement` derived from the server's route wrappers and handler checks (section 8.9), for example `/api/plugins` needs `audit:read`, `GET /api/netguard/bindings` needs `netguard:admin`, `/api/subscription-shares` needs `proxy:admin`, every `/api/notify` read needs `notify:admin`, SSH Guard status needs `sshguard:read` plus `network:plan`, and terminal session lists and transcripts need `terminal:open`.
- Tabs and directory rows never disappear. Unreadable sections render ScopeDeniedRow; unreadable directory pages move to the collapsed "Not available with this token" group; unavailable actions stay visible in menus, disabled, with "Needs {scope}".
- A token confined by `server_allowlist` shows "Confined to {n} nodes" in Fleet's header and "of visible nodes" in counts; actions that need an unconfined token (measure certificate, proxy plans) are disabled with "Needs a token without a node allowlist".
- `ScopeCatalogue` in AstraCore holds the scope descriptions from `lib/scopes.ts` for ScopeSummary and TokenDetail.
- **Token presets.** AstraCore `TokenPresets` derives the presets from the parity matrix (each N-* row's scopes are data in AstraCore `ParityMatrix`), and a check asserts that every N-* row's scopes belong to some preset or to `TokenPresets.deliberatelyExcluded` (`token:admin`, `user:admin`, `plugin:admin`, `oidc:admin`, `notify:send`, `secrets:reveal`). The resulting presets:
  - **Triage** (read and acknowledge; cannot change configuration or see approvals): `node:read`, `group:read`, `inventory:read`, `monitor:read`, `monitor:admin`, `audit:read`, `task:read`, `netpolicy:read`, `geo:read`, `log:read`.
  - **Operator**: Triage plus `network:plan`, `network:apply`, `node:admin`, `group:admin`, `sshguard:admin`, `inventory:admin`, `ddns:admin`, `dns:admin`, `geo:admin`, `tunnel:admin`, `netpolicy:admin`, `netguard:read`, `notify:admin`, `proxy:read`, `proxy:admin`, `log:admin`, `kv:read`, `kv:write`, `static:read`, `static:write`.
  - **Operator plus root**: Operator plus `task:run` and `terminal:open`, shown with "This token can run scripts as root on every node it can see and open root shells through the API."
  - Actions that need an excluded scope (plugin lifecycle, token revoke and delete, user detail) work only when the operator deliberately added it, and ScopeSummary warns about it.

### 6.13 Revealed secrets

Covered by F-13 and F-14. In addition: reveal results are delivered to the step through a one-shot value, never stored in a store property that outlives the sheet; the value is cleared on the `.inactive` transition, so the ShieldWindow (F-18) covers the snapshot and no value is left behind it; while the screen is captured or mirrored (`sceneCaptureState == .active`) the value stays masked. `.privacySensitive()` is not relied on: it only redacts in privacy-redaction contexts (widgets, a locked Lock Screen), not in recordings or mirroring.

### 6.14 Search and query syntax

AstraCore `LatticeQuery` ports `lib/query/syntax.ts`, `engine.ts` and `values.ts`: `field:value`, `=` and `:=` for exact match, `>`, `>=`, `<`, `<=`, `OR` and `|`, parentheses, `-term` and `NOT`, quoted values, `sort:-field`, and value coercion as the engine does it. Each domain provides a `QueryFieldProvider` mapping field names to values on its rows (nodes use the fields in `lib/query/nodeFields.ts`). Lists filter on device with the parsed query; where the server accepts a filter (`q`, `status`, `node_id`), the store sends it. Unknown fields are shown as a token with a warning style and ignored, matching the console. The golden is the console's portable vector file `src/lib/query/vectors.json` (shared byte for byte with lattice-plugin-bridge), copied into `Checks/AstraCoreCheck/Fixtures/query-vectors.json` and run in full except the `complete` (autocomplete) cases.

### 6.15 Open on web

"Open on web" builds the URL with `LatticeConsolePath` from the console URL (Settings > Connection; defaults to the server URL) and opens it with `openURL` in the default browser, so the operator's existing console session is reused. Rows that are web-only are `WebLinkRow`s showing the console path. The app never embeds the console in a web view. Secret-bearing links (a revealed machine console link) never go through `openURL` (F-14).

### 6.16 Time display

AstraCore `TimeDisplay` is pure: every function takes an explicit `TimeZoneMode` (`.local` or `.utc`) and a `Locale`, and formats with `Date.FormatStyle` (`.dateTime.hour().minute()` and friends) so the locale and the 12 or 24-hour setting apply. Views get the mode from the environment value `\.timeZoneMode`, set at the root from Settings. In UTC mode the visible text adds "UTC" and VoiceOver phrases say "UTC", never a bare "Z". Relative ages ("12 min ago", "in 3 days") use `RelativeDateTimeFormatter`. Detail rows that show an absolute time add the other zone on a secondary line. Countdowns use `Text(timerInterval:)`. Copy examples in this document that show a clock time are placeholders for this formatting.

---

## 7. Onboarding and auth

### 7.1 First run

WelcomeFlow (F-02) is a full-screen cover with its own stack. No permission prompts anywhere in it. Each step's primary action is a `.bottomBar` toolbar button.

1. **Welcome.** App name, one sentence ("The phone for your Lattice control plane: triage, decide, investigate."), primary "Connect to a server", secondary "Explore with demo data".
2. **Server.** URL field (`.keyboardType(.URL)`, autocorrect and autocapitalization off), normalized by `AstraURLNormalizer.serviceURL`. Continue calls `/api/health` and `/api/version` and shows the server build. Errors in place (cannot reach, not a Lattice server, TLS failure).
3. **Credential.** Two choices:
   - "API token (recommended)": a `PasteButton` (no paste-permission alert) plus a secure field for typing. The token is validated with `/api/me`. Copy under the field: "Create a token in the console under Settings > Access > Tokens." with an "Open token page" button (`/settings/access?view=tokens`) and a "Suggested scopes" disclosure showing the Triage, Operator and Operator plus root presets (F-05).
   - "Sign in with password": username and password, then a TOTP step when `/api/login` returns `{totp_required, challenge_id}` (`.textContentType(.oneTimeCode)`, auto-submit at six digits, "Use a recovery code" link). A 403 `mfa_required` shows "Two-factor enrollment is required. Enroll on the web first."
4. **Scope summary.** F-05 in onboarding mode: what this credential can and cannot do, confinement, hidden approval plugins, and missing recommended scopes with their consequence. With a PAT, an optional "Also sign in for reveals" row runs the password plus TOTP flow for the reveal session (held in memory unless the operator turns on "Keep the session on this iPhone"). "Done" lands on Inbox.

### 7.2 Credential storage

- PAT: Keychain generic password, service `org.roobli.astra`, account `pat`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, never synchronized. It is the only credential BGAppRefresh reads.
- Session: the operator's interactive user session, usually scope `*` with a fixed 12-hour lifetime (`auth.NewSession(user.ID, 12*time.Hour)`). By default its cookie value and CSRF token are held in memory only, so each reveal sitting signs in, and "End session after each reveal" (on by default) calls `POST /api/logout` when the reveal closes. If the operator turns on "Keep the session on this iPhone", it is a Keychain item under account `session` with `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly` and `SecAccessControl` `.userPresence`, read only in the foreground after authentication, never from BGAppRefresh. F-06 shows the real expiry from the cookie's `Expires`. The actor id and username are not secret and live in `UserDefaults`.
- `LatticeCredential` stays the value type. `SessionStore` builds two `LatticeClient`s: `client` (PAT if present, else the session) and `revealClient` (session only, nil without one). With a PAT present, only S intents and session-only account endpoints use `revealClient`.
- A 401 on `client` shows "Your token was rejected" with "Change credential". A 401 on `revealClient` marks the session expired ("Session expired. Sign in again for reveals.") without touching the PAT, except a 401 from `/api/security/step-up`, which is a wrong code (6.4).
- Sign out (T2) calls `POST /api/logout` for a session, deletes both Keychain items, clears the badge, clears every store and the step-up grant, and returns to WelcomeFlow.

### 7.3 Demo mode

- Entered from Welcome ("Explore with demo data") or Settings > Connection ("Switch to demo data"), and by the launch argument `-AstraDemo YES` (used by `scripts/sim.sh demo`). The demo-only launch arguments are listed in section 9.2 (`-AstraRoute`, `-AstraDemoScenario`, `-AstraDemoNow`, `-AstraPresent`, `-AstraAuth`, `-AstraOrientation`, `-AstraColorFilter`, `-AstraBoldText`, `-AstraDifferentiateWithoutColor`); outside demo they are ignored.
- `SessionStore` builds `client` as `LatticeClient(baseURL: https://demo.lattice.invalid, transport: DemoTransport(identity: .pat))` and, except in the No session scenario, `revealClient` as a second DemoTransport client (`identity: .session`). `/api/me` returns the Operator preset on `client` (Triage in Limited token) and `*` on `revealClient`.
- Clearly labeled: a "Demo" bar button (`theatermasks`) sits beside the Settings button on every tab root, Settings shows a "Demo data" section at the top, and the verdict line is unchanged (it is built from demo data on screen).
- Writes and reveals go through the real ActionRunner, confirmation, Face ID and step-up paths; DemoTransport answers them (step-up accepts any six digits except `000000`, which returns 401; every reveal returns an obviously fake value such as `demo-knock-7000-8000-9000`), and the `DemoState` actor applies the obvious change (an acknowledged incident stays acknowledged) for the session.
- "Leave demo" returns to WelcomeFlow. Demo never touches the Keychain.

### 7.4 Passkeys and SSO

Out of v3. Passkey login and passkey step-up need Associated Domains (`webcredentials:`) on a signed build matching `LATTICE_PUBLIC_URL`. SSO login (`/api/auth/oidc/start`) needs a test of `ASWebAuthenticationSession` cookie capture against the server. Both are listed in section 10.

---

## 8. Architecture

### 8.1 Rules

- `Sources/AstraCore/` has no SwiftUI or UIKit imports. It compiles into both the app target (through the synchronized root group) and the SwiftPM targets `AstraCore` and `AstraCoreCheck`.
- The app target compiles AstraCore sources directly, so app files do not `import AstraCore`. Both the app and AstraCore are one module each, so names must be unique twice over: every Swift file basename must be unique across `AstraApp/App` and `Sources/AstraCore` (Xcode refuses two `Models.swift` in one target), and every type name must be unique across both.
- **Type namespace.** Every non-private type, extension method and global function under `AstraApp/App/Features/<Module>/` and `Sources/AstraCore/Domains/<Domain>/` is one of: a type whose name equals the basename of its file as listed in 9.5 (`NodesScreen` in `NodesScreen.swift`; these names are unique by construction), a name prefixed with its feature folder or domain name (`FleetDisableRequest`, `MonitoringStripCell`, `func fleetDisableNode`), or `private`/`fileprivate`. New `LatticeClient` methods and DTOs are domain-prefixed. Unprefixed names belong to Shared, Design, Shell, Safety, Session and Settings only. Section 9.2 runs a grep that fails on unprefixed internal types.
- **Access.** Every type, initializer, property and function in `Shared/`, `Domains/` and `Demo/` that a check touches is `public` (`AstraCoreCheck` sees AstraCore through `import AstraCore`). This is harmless for the app, which compiles the sources directly.
- **Build settings.** Both builds use Swift 6 language mode and nonisolated default actor isolation: `Package.swift` declares no `defaultIsolation`, and the app target keeps `SWIFT_VERSION = 6.0` with no `SWIFT_DEFAULT_ACTOR_ISOLATION` and no Approachable Concurrency upcoming-feature flags. No lane changes these.
- New files go under `AstraApp/App/` or `Sources/AstraCore/` at any depth and need no `project.pbxproj` edit. No lane edits `project.pbxproj` or `Package.swift`. Color sets go into `AstraApp/Assets.xcassets` (an asset catalog folder, no project edit), owned by M0b.
- List stores are `@Observable @MainActor final class`. Per-object detail models (NodeDetail, TaskRun, PathDetail and the like) are view-owned `@State` `@Observable` instances built from `SessionStore`, never registered. Views read stores from the environment. No `ObservableObject`, no `@EnvironmentObject`, no custom `EnvironmentKey` for a main-actor object. `DashboardModel` is deleted in M0.
- All network calls go through `LatticeClient` extensions. All writes go through `ActionRunner.run`; all reveals through `ActionRunner.reveal`.

### 8.2 Directory layout

```
Sources/AstraCore/
  Shared/                         M0a. Frozen after M0 except in integration windows (9.3).
    Transport.swift               LatticeClient, HTTPTransport, buildRequest, validate, perform helpers, error-envelope decoding
    Errors.swift                  LatticeAPIError (section 8.3)
    Bodies.swift                  IDBody, NodeIDBody and other generic request bodies
    Credentials.swift             LatticeCredential, login and TOTP, session cookie extraction and expiry
    Decoding.swift                DateValue, AstraDateParser, list envelope decoding (bare array or envelope)
    Formatting.swift              Byte, Percent, Duration, Currency, Uptime formatters
    TimeDisplay.swift             TimeZoneMode, FormatStyle-based formatting, relative ages
    ResourceState.swift           ResourceState<Value>
    Freshness.swift               stale rule
    ScopeSet.swift                ScopeSet (directlyAllows, compatibleScopes, explicit-only), ScopeRequirement, ScopeCatalogue
    ApprovalVisibility.swift      read and decision scope table mirrored from server.go
    TokenPresets.swift            ParityMatrix rows as data, TokenPresets, deliberatelyExcluded
    WriteIntent.swift             WriteIntent, RevealIntent, WriteTier, ClientKind, ObjectRef, ConfirmToggle, ConfirmChoices, DryRunReport
    WriteOutcome.swift            WriteOutcome, RefusalCode, ObjectFailure, RevealedSecret
    WriteFlow.swift               pure sequencing of an intent with injected WriteAuthenticator (cancel sends nothing)
    StepUp.swift                  StepUpGrant, StepUpPurpose, TOTPStep
    QuerySyntax.swift             LatticeQuery parser, engine and values ports, QueryFieldProvider
    PlanSeal.swift                compact and grouped seal formatting
    DisplayStates.swift           NodeHonesty, PathDisplayState (with PathReason), IncidentDisplayState, TaskRunState, ApprovalDisplayState, SSHGuardCoverage
    Verdict.swift                 InboxSnapshot (plain counts and coverage), VerdictBuilder, Verdict
    BadgeCount.swift              BadgeCount.compute(approvals:incidents:)
    DeepLinks.swift               LatticeDeepLink (all cases), LatticeConsolePath builders, NodeDetailTab, ApprovalsScope, MonitorSegment, FleetScope, ActivityScope
    PathKey.swift                 PathAddress, encodePathKey, decodePathKey
    Identity.swift                LatticeIdentity (/api/me), LatticeServerVersion, ServerHealth, PluginTrust and their fetches
    Nodes.swift                   LatticeNode and nested types, honesty, fetchNodes, NodeGeoView, fetchNodeGeo
    Approvals.swift               Approval, ApprovalWaiting, ApprovalReviewDecoder, fetchApproval, listHumanPendingApprovals, countApprovals, listApprovals(query:)
    AuditEvents.swift             AuditEvent, AuditQuery, fetchAudit(query:) (raw JSON slice kept per event)
    Incidents.swift               Incident, MaintenanceWindow, IncidentListResponse, IncidentFilter (console chip names to predicates, isSnoozed, incidentActions); list, ack, unack, snooze; windows list, upsert, delete
    Paths.swift                   PathsResponse, PathView, path state derivation from pathsModel.ts, PathReason.sentence(for:), fetchPaths(window:)
    TaskRuns.swift                LatticeTask, LatticeTaskResult, TaskCounts, TaskRunState derivation; list, query, counts, results
    Expiring.swift                ExpiringItem, ExpiringResponse, fetchExpiring(within:)
    DDNSProfiles.swift            DDNSProfile, DDNSProfile.health(now:), listDDNS
    SSHGuardStatus.swift          SSHGuardNodeStatus (stage, posture, revert_deadline, actionable_approval_id), SSHGuardSSHDFacts, SSHGuardKnockView, boardStage, coverageBucket, revertingNodes, revertDeadline; fetchSSHGuardStatus (all and one)
    NotifyDeliveries.swift        NotifyDelivery, NotifyDeliveriesResponse, DeliveryQuery (real filter names), fetchDeliveries
    PlanFiling.swift              planBeacon (BeaconPlanRequest: action enable|disable|change, port, bind, endpoint), planAgentUpdate(nodeID:force:), and their approval-id extraction
    PluginCall.swift              callPlugin(id:service:method:body:) for POST /api/plugins/call
  Domains/
    Approvals/ApprovalsDecisions.swift, ApprovalEvents.swift, DecisionFlow.swift      M1
    Fleet/FleetModels.swift, FleetAPI.swift, MapClusters.swift                         M2
    Monitoring/MonitoringModels.swift, MonitoringAPI.swift                              M3
    Tasks/TasksAPI.swift                                                               M4
    Audit/AuditAPI.swift, AuditExport.swift                                            M4
    Inventory/InventoryModels.swift, InventoryAPI.swift, ReminderSchedule.swift        M5
    Networking/NetworkingModels.swift, NetworkingAPI.swift                             M6
    SSHGuard/SSHGuardAPI.swift, SSHGuardRotation.swift                                 M7
    AgentUpdates/AgentUpdatesModels.swift, AgentUpdatesAPI.swift                       M7
    Platform/PlatformModels.swift, PlatformAPI.swift, ExtensionPageModel.swift         M8
    Notify/NotifyModels.swift, NotifyAPI.swift                                         M9
    Evidence/EvidenceModels.swift, EvidenceAPI.swift                                   M10
    Access/AccessModels.swift, AccessAPI.swift                                         M11
    Terminal/TerminalModels.swift, TerminalAPI.swift, TranscriptCleaner.swift          M12
    VPN/VPNModels.swift, VPNAPI.swift                                                  M13
  Demo/
    DemoTransport.swift, DemoRoute.swift, DemoScenario.swift, DemoState.swift, DemoClock.swift   M0a
    DemoWorld.swift               M0a: the invented fleet (ids, names, regions, IPs) every fixture uses
    DemoFixtures.swift            M0a: `static var all: [DemoRoute] { SharedFixtures.routes + ApprovalsFixtures.routes + ... }` (computed)
    Fixtures/SharedFixtures.swift M0a
    Fixtures/<Domain>Fixtures.swift  one per domain, `public enum <Domain>Fixtures { public static let routes: [DemoRoute] }`, owned by that domain's module

Checks/AstraCoreCheck/
  main.swift                      M0a, frozen: calls every check function in order (8.5)
  CheckSupport.swift              M0a: expect helpers, MockTransport (records every request), `fixture(_ name:)` loading JSON from `Fixtures/` relative to `#filePath`
  Fixtures/                       JSON fixtures for checks (query-vectors.json, console export goldens); each module adds files prefixed with its domain
  SharedChecks.swift, ContrastChecks.swift, DemoChecks.swift   M0a
  <Domain>Checks.swift            one per domain, owned by that domain's module

AstraApp/App/
  Shell/        AstraApp.swift, SceneDelegate.swift, RootTabs.swift, AppState.swift, AppRoute.swift, SettingsRoute.swift,
                AppRouteDestination.swift, SettingsDestination.swift, Router.swift, DeepLinkRouter.swift, ScopeRoots.swift,
                BrowseRoot.swift, BrowseDirectory.swift, SearchRegistry.swift, StoreRegistry.swift, GlobalSheets.swift,
                PrivacyCover.swift (ShieldWindow), BannerWindow.swift, BackgroundRefresh.swift, LaunchArguments.swift   (M0b)
  Design/       Tokens.swift, StatusStyle.swift, Typography.swift, Spacing.swift, Rows.swift, ObjectRows.swift,
                Controls.swift, FlowLayout.swift, StateViews.swift, ChartStyle.swift, StateStrip.swift, SealLabel.swift,
                VerdictView.swift, Haptics.swift, A11yOverrides.swift, StatusSampler.swift (debug only)            (M0b)
  Safety/       ActionRunner.swift, ActionHost.swift, ConfirmSheet.swift, ConfirmPage.swift, RevealFlowSheet.swift,
                SecretRevealStep.swift, OutcomeBanner.swift, IntentAuth.swift, ChangeLog.swift                    (M0b)
  Session/      SessionStore.swift, KeychainStore.swift, StepUpCoordinator.swift, Polling.swift,
                NetworkMonitor.swift, NodeDirectory.swift                                                       (M0b)
  Settings/     WelcomeFlow.swift, SettingsScreen.swift, ConnectionScreen.swift, ScopeSummaryScreen.swift,
                SessionForRevealsScreen.swift, DeviceSecurityScreen.swift, BadgeRefreshScreen.swift,
                DisplayScreen.swift, DiagnosticsScreen.swift, DemoScenarioScreen.swift, AboutScreen.swift         (M0b)
  Features/<Module>/   one folder per module (section 9)
```

`Design/ObjectRows.swift` holds the rows more than one module shows, each taking Shared models or display-state enums and the intents it can offer: `IncidentRow` (with the T1 acknowledge and snooze swipe intents built from Shared incident calls), `ApprovalRow` (with `SealLabel`), `TaskRow`, `PathRow`, `NodeRow`, `AuditRow`. `Design/Controls.swift` holds `AdaptiveSegmentedPicker`, `FilterMenu`, `RangeMenu` and `PagedListLoader` (offset paging with a "Load more" fallback row). `Design/A11yOverrides.swift` defines `\.astraDifferentiateWithoutColor` (system value, or the demo override) which every module reads instead of the system key.

### 8.3 Core primitives

```swift
public enum LatticeAPIError: Error, Sendable, Equatable {
    case unauthorized(message: String)                 // 401; step-up 401 is mapped by its caller (6.4)
    case forbidden(code: String, message: String)      // 403 with the envelope's code and message; the envelope names no scope, so callers take it from their requirement
    case notFound                                      // 404
    case conflict(code: String, message: String, findings: [String])  // 409 with the envelope's code, message and findings
    case server(status: Int, code: String?, message: String)
    case transport(URLError.Code)                      // timeout, offline, TLS; before or after send is recorded by the runner
    case invalidResponse                               // undecodable body (companion behind)
}

public enum ResourceState<Value: Sendable>: Sendable {
    case idle
    case loading(previous: Value?, previousAt: Date?)
    case loaded(Value, at: Date)
    case failed(LatticeAPIError, last: Value?, lastAt: Date?)
    case denied(scope: String)
    case companionBehind(surface: String)
}

public enum Freshness: Sendable, Equatable { case fresh, stale(since: Date?), unknown }
// Freshness.of(_ state:, now:, interval:) -> stale when now - at > 3 * interval or the last attempt failed.

public enum WriteTier: Sendable { case t1, t2, t3, t4, plan }
public enum ClientKind: Sendable { case primary, session }

public struct ConfirmToggle: Sendable, Hashable {
    public var id: String                 // "accept_lockout_risk"
    public var label: String              // "Accept lockout risk"
    public var consequence: String
    public var revealedByConflict: Bool   // shown only after a 409 with findings
}
public struct ConfirmChoices: Sendable { public var accepted: Set<String> }   // ids of checked toggles

public struct DryRunReport: Sendable {
    public var lines: [DetailLine]        // label, value, consequence group
    public var blocking: Bool             // true disables the primary action
    public var fingerprint: String        // re-checked immediately before send; a change stops the write
}

public struct WriteIntent: Sendable {
    public var tier: WriteTier
    public var client: ClientKind
    public var verb: String               // "Disable node"
    public var object: ObjectRef          // kind, id, display name
    public var scopes: [String]           // every scope the write needs, evaluated on `client`
    public var consequence: String        // one sentence
    public var affected: [ObjectRef]      // blast radius; for P, the nodes the server will try
    public var toggles: [ConfirmToggle]
    public var confirmPhrase: String?     // T4: the operator types this (the object name)
    public var dryRun: (@Sendable (LatticeClient) async throws -> DryRunReport)?
    public var verify: (@Sendable (LatticeClient) async throws -> String)?   // post-state sentence for .unknown
    public var inverse: (@Sendable () -> WriteIntent)?                        // verified inverses only
    public var idempotent: Bool
    public var changes: [ChangeKind]
    public var perform: @Sendable (LatticeClient, ConfirmChoices) async throws -> WriteOutcome
}

public struct RevealIntent: Sendable {
    public var purpose: StepUpPurpose
    public var object: ObjectRef
    public var scopes: [String]           // evaluated on sessionScopes
    public var shareable: Bool            // share URLs and VPN subscription links only
    public var perform: @Sendable (LatticeClient, StepUpGrant) async throws -> RevealedSecret
}

public struct ObjectFailure: Sendable { public var object: ObjectRef; public var reason: String }

public enum WriteOutcome: Sendable {
    case done(String, secret: RevealedSecret? = nil)
    case partial(succeeded: [ObjectRef], failed: [ObjectFailure], message: String)
    case refused(RefusalCode, String)
    case unknown(String)
    case filed(approvalIDs: [String], refused: [ObjectFailure], notes: [String])
}
```

`ActionRunner` (M0b, `@MainActor @Observable`):

```swift
func run(_ intent: WriteIntent) async -> WriteOutcome     // presents the tier's gate in the topmost action host
func reveal(_ intent: RevealIntent) async                 // RevealFlow; the value never leaves the sheet
var isBusy: Bool { get }
```

- Presentation goes through `.actionHost()`, a modifier that RootTabs and every sheet root apply. Hosts register on appear in a stack; `run` uses the topmost. At RootTabs a T3, T4 or P gate is the ConfirmSheet; inside a sheet it is `ConfirmPage` pushed on that sheet's own `NavigationStack` (every sheet root is a `NavigationStack`). T2 dialogs attach to the host's root view.
- The sequencing (dry run, toggles, authenticate, perform, verify on `.unknown`, findings loop) lives in AstraCore `WriteFlow` with an injected `WriteAuthenticator`, so a check proves that cancelling authentication sends zero requests.
- Findings loop: a P `perform` that gets `LatticeAPIError.conflict(code, findings)` with non-empty findings returns `.refused(.conflict(findings:), message)`; the ConfirmSheet stays open on its Findings step with the findings and the toggles whose `revealedByConflict` is true; a second tap calls `perform` again with those toggles in `ConfirmChoices`, and `perform` adds the acceptance flag (`accept_findings`, `accept_lockout_risk`) only when the toggle is checked.
- Approval-id extraction for `.filed` lives next to each plan API function, because plan endpoints answer in five shapes: `{approval, findings}`, a bare `ApprovalView`, `{approval}`, `BeaconPlanResponse`, and `GroupPolicyPlanResult {affected, conflicts, orphaned, selector_impacts}` (8.9 says which endpoint returns which).
- Bulk and "Plan all behind" intents are one intent whose `perform` loops sequentially and returns `.partial` or `.filed` with the refused half.
- Decisions (D) do not use `WriteIntent`; they stay in `DecisionFlow` and the Review and BatchReview code of 6.1 and 6.2.

### 8.4 Stores, data flow and endpoint ownership

- One `SessionStore` (M0b) owns the server and console URLs, credentials, both clients, `tokenScopes` and `sessionScopes`, `/api/version`, demo flag, companion-behind flag, and network state.
- `NodeDirectory` (M0b) holds the node list keyed by id for name lookup across modules; any visible screen that needs node names calls `nodeDirectory.refreshIfOlder(than: 15)`.
- `ChangeLog` (M0b) is an `@Observable` counter per `ChangeKind`; M0a enumerates every case in `WriteIntent.swift`: `approvals, incidents, maintenance, nodes, groups, gates, paths, checks, definitions, tasks, audit, machines, upcoming, policies, dns, ddns, geo, tunnels, netguard, sshguard, agentUpdates, plugins, publishing, store, notify, webhooks, evidence, account, tokens, terminal, vpn, session`. `ActionRunner` bumps the kinds an intent declares; screens refetch through the fixed idiom of 6.8.
- List stores only are registered: each module owns its list stores (section 9), every list store has `init(session: SessionStore, changes: ChangeLog)`, and `StoreRegistry` (M0b) creates them at launch and injects them with `.environment(_:)`. Detail models are view-owned (8.1).
- **Frozen API.** Every AstraCore type and function that exists at the start of a wave is frozen for that wave: additive changes only, no renames or signature changes, until the next integration window. M0's ported names (including `listHumanPendingApprovals`, which BackgroundRefresh calls) are frozen permanently.
- **Endpoint ownership.** Exactly one owner per method and path. Every other module calls the owner's function, and only once it exists at the start of that module's wave. Paths are relative to `/api`.

| Owner | Endpoints |
|---|---|
| Shared (M0a) | GET `me`, `version`, `health`, `plugin-trust`; GET `nodes`, `nodes/geo`; GET `network/approvals` (list, `?id`, `?count=1`, filters); GET `audit`; GET `incidents`; POST `incidents/ack`, `incidents/unack`, `incidents/snooze`; GET and POST `maintenance-windows`, POST `maintenance-windows/delete`; GET `monitors/paths`; GET `tasks`, `tasks/counts`, `task-results`; GET `expiring`; GET `ddns`; GET `sshguard/status`; GET `notify/deliveries`; POST `nodes/beacon/plan`, `nodes/agent-updates/plan`; POST `plugins/call`; POST `login`, `login/totp`, `logout`, `security/step-up` |
| M1 | POST `network/approvals/approve`, `/reject`, `/dismiss` |
| M2 | GET `nodes/status-history`, `nodes/history`, `nodes/network`, `nodes/duplicates`, `nodes/beacon`; GET and POST `nodes/capabilities`; POST `nodes/update`, `nodes/disable`, `nodes/rotate-token`, `nodes/delete/plan`, `nodes/delete`, `nodes/debug`, `nodes/geo`, `nodes/geo/resolve`, `nodes/beacon/rotate`; GET and POST `capabilities`; GET `groups`, `groups/used-by`; POST `groups/delete`, `groups/members` |
| M3 | GET `monitors`, `monitors/results`, `monitors/series`, `monitors/latency/series`, `monitors/latency/rollups`, `monitors/definitions`; POST `monitors/update`, `monitors/delete`, `monitors/definitions/delete`; GET `network/lines/chains` |
| M4 | POST `tasks/rerun`, `tasks/rerun-node`, `tasks/cancel`, `tasks/delete`, `tasks/reveal-script`; GET `audit/verify` |
| M5 | GET `machines`, `machine-vendors`; POST `machines/delete`, `machines/renew`, `machines/reminders/run`, `machines/reveal-link` |
| M6 | GET `netpolicy`, `netpolicy/matrix`, `netpolicy/graph`, `group-policies`, `dns/deployments`, `geo-routing`, `tunnels`, `netguard/{groups,zones,nodes,bindings,node-group-bindings}`; POST `netpolicy/plan`, `netpolicy/convert`, `group-policies/plan`, `dns/plan`, `dns/publish`, `dns/measure-cert`, `ddns/delete`, `ddns/run`, `geo-routing/delete`, `geo-routing/plan`, `tunnels/delete`, `tunnels/plan` |
| M7 | POST `sshguard/plan`, `sshguard/confirm`, `sshguard/knock` (knock-state read), `sshguard/knock/reveal`; GET `nodes/agent-updates`, `nodes/agent-updates/releases`, `nodes/agent-updates/artifacts`, `nodes/agent-updates/mirrors` |
| M8 | GET `plugins`, `plugin-contributions`, `publishing/records`, `storage/{buckets,bindings,tokens}`, `subscription-shares`, `kv`, `static`, `system/health`, `system/series`; POST `plugins/lifecycle`, `storage/bindings/delete`, `storage/tokens/revoke`, `subscription-shares/{id}/rotate`, `/refresh`, `/reveal`; DELETE `subscription-shares/{id}` |
| M9 | GET `notify/channels`, `notify/rules`, `notify/catalogue`, `notify/witness`, `notify/webhooks`, `notify/webhooks/deliveries`; POST `notify/channels/delete`, `notify/channels/test`, `notify/witness/plan`, `notify/webhooks/delete`, `notify/webhooks/test` |
| M10 | GET `logs/sources`, `logs/query`, `logs/stats`, `trace/connections`, `trace/sessions`, `trace/hops`, `trace/markers`, `evidence/settings`; POST `trace/sessions`, `trace/sessions/stop` |
| M11 | GET `security/webauthn/credentials`, `users`, `tokens`, `auth/oidc/providers`; POST `security/webauthn/credentials/rename`, `/delete`, `tokens/revoke`, `tokens/delete` |
| M12 | GET `terminal/sessions`, `terminal/sessions/{id}/events`; POST `terminal/sessions/{id}/close` |
| M13 | GET `proxy/users`; POST `proxy/users/reveal-credentials`; GET and DELETE `vpn/users/{id}/link`; POST `vpn/users/{id}/link/rotate`, `vpn/users/{id}/link/reveal` (and `callPlugin` with the vpn-core strings of 8.9) |

Consumers by wave: M2 (wave 1) reads Shared paths, approvals, audit and tasks for NodeDetail; it shows no NetGuard summary of its own and links to `NetworkingRoute.inboundFirewall(nodeID:)` (M6, wave 3) instead. M7 (wave 2) uses M2's capabilities calls. M13 (wave 5) uses M3's chains call. M9 (wave 3) and M3 use the Shared deliveries call.

### 8.5 Registries M0 pre-populates

These are the only shared files after M0. M0 writes them complete, referencing module-owned types that M0 also stubs; modules never edit them.

| Registry | File | Contents |
|---|---|---|
| App routes | `Shell/AppRoute.swift`, `Shell/SettingsRoute.swift`, `Shell/AppRouteDestination.swift`, `Shell/SettingsDestination.swift` | One case and one destination per module |
| Deep links | `Sources/AstraCore/Shared/DeepLinks.swift`, `Shell/DeepLinkRouter.swift` | Every row of 2.5 mapped to an `AppRoute`, a Settings path or a sheet |
| Scope roots | `Shell/ScopeRoots.swift` | Fleet, Monitor and Activity segments mapped to module root views. Every scope root is frozen as `init()` reading `AppState` and its store from the environment: `NodesScreen`, `GroupsScreen`, `MapScreen`, `InventoryScreen`, `MonitorOverviewScreen`, `PathsScreen`, `ChecksScreen`, `IncidentsScreen`, `TasksScreen`, `AuditScreen`, `ApprovalsScreen`, `SentLogScreen` |
| Browse directory | `Shell/BrowseDirectory.swift` | Every directory row with its requirement and route, Settings path, tab switch or console path |
| Search providers | `Shell/SearchRegistry.swift` | `[InboxSearch.self, FleetSearch.self, ...]`, each conforming to `@MainActor protocol SearchProvider { static func results(for query: LatticeQuery, context: SearchContext) async -> [SearchResult] }`. `SearchContext` carries `SessionStore` and `NodeDirectory`. Each provider fetches its list once per Browse search session (60 s cache) and filters with `LatticeQuery` on device. |
| Stores | `Shell/StoreRegistry.swift` | Every list store instantiated and injected |
| Global sheets | `Shell/GlobalSheets.swift` | Review, `maintenanceStart` (M3), `renew` (M5) |
| Demo fixtures | `Sources/AstraCore/Demo/DemoFixtures.swift` | computed `all` concatenating `SharedFixtures.routes, ApprovalsFixtures.routes, FleetFixtures.routes, MonitoringFixtures.routes, TasksFixtures.routes, AuditFixtures.routes, InventoryFixtures.routes, NetworkingFixtures.routes, SSHGuardFixtures.routes, AgentUpdatesFixtures.routes, PlatformFixtures.routes, NotifyFixtures.routes, EvidenceFixtures.routes, AccessFixtures.routes, TerminalFixtures.routes, VPNFixtures.routes` |
| Checks | `Checks/AstraCoreCheck/main.swift` | Calls, in order: `checkShared, checkContrast, checkDemo, checkApprovals, checkFleet, checkMonitoring, checkTasks, checkAudit, checkInventory, checkNetworking, checkSSHGuard, checkAgentUpdates, checkPlatform, checkNotify, checkEvidence, checkAccess, checkTerminal, checkVPN` |

### 8.6 DemoTransport

- `struct DemoTransport: HTTPTransport` serves `DemoFixtures.all`. Matching: HTTP method, then `pathPattern` (segments may be `*`), then the route's required query items (a subset match), then `bodyMatch` (top-level JSON keys and string values of the request body); the most specific route wins. Unmatched requests return 404 with the server's error envelope so missing fixtures look like a missing endpoint, never like an empty list.
- `struct DemoRoute: Sendable { method: String; pathPattern: String; query: [String: String]; bodyMatch: [String: String]; status: Int; body: String; emptyBody: String?; respond: (@Sendable (DemoRequest, DemoState) async -> DemoResponse)? }`. `DemoRequest` carries method, path segments, query and decoded JSON body. `body` is JSON in a Swift raw string literal shaped exactly like the server response (from `api-shapes.md`). Routes that depend on session state (writes, and reads such as `?id=` after a decision or incidents after an acknowledgment) use the async `respond`, which may read and mutate the `DemoState` actor. The incidents route answers 400 "unknown state" for a `state` value outside the server's four, as the server does.
- `DemoState` is an actor holding in-memory overrides for the session (acknowledged incidents, disabled nodes, decided approvals, filed plans).
- **Time tokens.** Fixture bodies never contain literal timestamps. DemoTransport substitutes `{{now}}`, `{{now-12s}}`, `{{now+3d}}` and similar tokens at serve time as RFC 3339 UTC, anchored to one `DemoClock` per launch; `-AstraDemoNow <RFC3339>` pins the clock for reproducible screenshots.
- `DemoScenario`: Normal, Quiet, Failing, Stale, Offline, Limited token, Confined token, No session, Forbidden, Empty, Companion behind. Failing returns 503 for the routes under a path prefix (default incidents and tasks; `-AstraDemoScenario failing:/api/monitors` picks another); Stale lets the first request per route succeed and fails the rest with a timeout; Offline makes the demo `NetworkPathSource` report unsatisfied and the transport throw `.notConnectedToInternet`; Limited token swaps `/api/me` to Triage; Confined token keeps the Operator preset with a 12-node `server_allowlist` and lists only those nodes; No session leaves `revealClient` nil; Forbidden answers 403 with `forbidden` for a path prefix after the first load; Empty serves `emptyBody` (or `[]` for array routes); Companion behind serves an undecodable body for a path prefix (default the approval `?id=` route).
- **Fixture coverage.** M0a's `DemoWorld` and `SharedFixtures` contain every state the 9.5 screenshots need: nodes in all five honesty states; incidents open critical, warning and info, acknowledged, snoozed, held, derived `pending:`, flapping and resolved, including a path-kind incident; tasks in every `TaskRunState` including pending, stalled and expired; SSH Guard nodes in each server stage, one `reverting` with `revert_deadline` minutes ahead and an `actionable_approval_id`; DDNS profiles current, failing and stale; deliveries sent and failed. Modules add only routes with a distinct `query` or `bodyMatch` key and request Shared fixture changes through the integration window.
- Latency: a random 80 to 300 ms delay per request so loading states are visible (0 ms when `-AstraDemoNow` is set, for stable screenshots).
- `DemoWorld` defines 35 invented nodes across invented regions (for example `edge-tyo-1`, `relay-fra-2`, `home-nas`), IPv4 from 192.0.2.0/24, 198.51.100.0/24 and 203.0.113.0/24, IPv6 from 2001:db8::/32, hostnames under `example.net` and `example.org`, tokens like `lat_demo_0001.notasecret`. No real names, addresses, hostnames or tokens.
- Approval fixtures carry real SHA-256 values of their plan text (computed by `PlanHasher` and asserted by `DemoChecks`), plus one deliberate mismatch fixture for the mismatch screenshot.
- `DemoChecks` asserts: the uniqueness key (method, pathPattern, query, bodyMatch) has no duplicates; every GET route whose body is a JSON object has an `emptyBody`; no fixture contains a literal `20xx-` timestamp outside an allowlist; every approval fixture hashes to its `plan_sha256` except the flagged mismatch.

### 8.7 AstraCoreCheck

- One check file per domain, each exposing `public func check<Domain>() async throws`, called from `main.swift` in the order of 8.5.
- Each domain check decodes every response type it uses (the demo fixtures and edge-case JSON loaded with `fixture(_:)` from `Checks/AstraCoreCheck/Fixtures/`, resolved relative to `#filePath`, since `Package.swift` declares no resources), checks request bodies built for writes against goldens, and checks the domain logic (for example `ApprovalEvents.group`, `ReminderSchedule`, `TranscriptCleaner`, query field mappings).
- M0a moves today's checks into `SharedChecks.swift`, `ApprovalsChecks.swift`, `FleetChecks.swift`, `InventoryChecks.swift`, `NetworkingChecks.swift`, `AuditChecks.swift` and `TasksChecks.swift` mechanically, placing each assertion with the domain whose code it tests. `checkLatticeMonitorEngine`, `checkBarkRequest` and `checkBarkNetworkFlow` are deleted together with `MonitorEngine` and `BarkClient`, which the app no longer uses.
- `swift run --scratch-path .build AstraCoreCheck` must pass at the end of every module.

### 8.8 Xcode project

Already converted (`cdb93de`). Nothing to convert. M0b verifies that a new file in a nested folder under `AstraApp/App/Features/` and under `Sources/AstraCore/Domains/` is compiled by `xcodebuild` without a project edit, and records that in its acceptance notes. Build settings are pinned as in 8.1. `Info.plist` is foundation-owned (URL scheme `lattice` and the BG task id already exist; M0b adds `NSFaceIDUsageDescription` if missing). `SceneDelegate` is attached through `@UIApplicationDelegateAdaptor`, whose `application(_:configurationForConnecting:options:)` returns a `UISceneConfiguration` with `delegateClass = SceneDelegate.self`, so no plist scene manifest change is needed.

### 8.9 API shapes and traps

M0a generates `docs/design/api-shapes.md` from `lattice-dashboard/src/lib/api/index.ts` with `scripts/api-shapes.mjs`: one row per endpoint with method, query or body, the TS response type, the Go handler `file:line`, and the read or write requirement taken from the server's route wrapper and handler checks. It marks dual-shape and envelope-on-query endpoints. Each module's check file decodes every response type in its rows. The traps every lane must know:

- `GET /api/tasks` returns a bare array without query parameters and `{tasks, total, limit, offset}` with any (`server.go:3886`, `task_queries.go`). Task `origin` is `approval|rerun|direct`; statuses include `pending`.
- `/api/machines`, `/api/monitors` and `/api/task-results` each have a bare and an envelope shape. The Shared list decoder accepts both.
- `GET /api/incidents` state values are only `pending,open,acknowledged,resolved` (section header facts).
- Plan endpoints answer in five shapes (8.3); `api-shapes.md` records which one each returns. `POST /api/netpolicy/convert {target_node_id, name?, priority?}` returns `NetPolicyConvertResult {group_policy, approval|null}`: it creates a group policy directly, then files a plan. `POST /api/group-policies/plan` takes `{}` and plans every node covered by any enabled group policy.
- vpn-core reads use `callPlugin(id: "latticenet.vpn-core", service: "latticenet.vpn-core/users", method: "list" | "get", body:)` (`server_vpncore.go:34,61`).
- `GET /api/sshguard/status` rows carry `stage`, a `posture` object, `revert_deadline` and `actionable_approval_id`; the read needs `sshguard:read` plus `network:plan` per node and silently skips the rest.
- Notify delivery filters are `channel_id`, `event_type`, `outcome`, `event_id`, `source`, `source_id`; console URL names map to them in `DeliveryQuery` only.
- `/api/audit` filters are `action`, `actor_id`, `at_from`, `at_to`, `correlation_id`, `decision`, `exclude_action`, `exclude_decision`, `node_id`, `scope`, `token_id`, `q`, `limit`, `offset`; there is no id filter.
- `/api/network/approvals` list filters are `status`, `plugin`, `node_id`, `since`, plus `limit`, `offset`, `include_dismissed`, `count`; there is no `until`.
- Shapes needing a careful read: `/api/monitors/series` (`PathSeriesResponse` query), `/api/capabilities` (`CapabilityImpact`), `/api/system/health|series` (`systemTypes.ts`), `/api/publishing/records`, `/api/trace/connections|hops|markers`, and the extension-page manifest model in `PluginView.vue`.

---

## 9. Feature modules

### 9.1 Ownership rules

- A module owns its folder `AstraApp/App/Features/<Module>/`, its domain folders under `Sources/AstraCore/Domains/`, its fixture files under `Sources/AstraCore/Demo/Fixtures/`, its check files and the check fixtures it adds (prefixed with its domain). It may add files inside those folders. It edits nothing else.
- M0 creates every file listed below as a compiling stub (an empty list store, a placeholder screen with `ContentUnavailableView("Not built yet", systemImage: "hammer")`, empty route destinations, an empty `routes` array, an empty check function, an empty search provider). After M0, the registries in 8.5 never change.
- Modules navigate across boundaries only with the Router and `AppRoute` values, show shared rows only from `Design/ObjectRows.swift`, and present global sheets only through M0 APIs (`ActionRunner`, `Router.present`).
- Each module merges with `git merge --no-ff` into the v3 integration branch (`feature/20261028_astra-console-parity`), from its own branch `feature/20261028_astra-v3-<id>-<slug>` in its own worktree (`scripts/sim.sh` isolates simulators per worktree and base device and caps concurrent builds at three).

### 9.2 Acceptance common to every module

Agents cannot tap, swipe or rotate a simulator, and the project has no UI test target. Acceptance therefore drives the app only through demo launch arguments and simctl, and leaves what needs a person to an operator checklist.

**Demo launch arguments** (M0b `Shell/LaunchArguments.swift`, honored only in demo mode):

| Argument | Effect |
|---|---|
| `-AstraRoute <lattice:// URL>` | Opens a route after launch, including the scope and segment links of 2.5 (`lattice://monitor?segment=paths&view=chains`) |
| `-AstraPresent <sheet>[:<args>]` | Opens any global or module sheet: `review:<id>`, `batch:<groupKey>`, `confirm:<intentID>` (each module registers its intents' ids in its route file), `reveal:<intentID>`, `renew:<machineID>`, `maintenanceStart:<nodeID>`, `settings:<page>`, and module sheets by name (`sshguardArm:<nodeID>`, `nodeIdentity:<nodeID>`, `reminders`) |
| `-AstraAuth succeed\|cancel` | Stub authenticator for D, T3, T4 and unlock |
| `-AstraAutoConfirm YES` | After `-AstraPresent`, runs the primary action once (with `-AstraAuth succeed`) so after-states can be captured |
| `-AstraDemoScenario <name>[:<path prefix>]` | Scenario of 8.6 |
| `-AstraDemoNow <RFC3339>` | Pins the demo clock |
| `-AstraOrientation landscape` | Calls `UIWindowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))` |
| `-AstraColorFilter grayscale\|deuteranopia` | Applies a `.colorMatrix` to the root view |
| `-AstraBoldText YES` | Sets `\.legibilityWeight` to `.bold` at the root |
| `-AstraDifferentiateWithoutColor YES` | Sets `\.astraDifferentiateWithoutColor` |

Text size and contrast use `xcrun simctl ui <udid> content_size accessibility-extra-extra-extra-large` (AX5) or `extra-extra-extra-large`, and `xcrun simctl ui <udid> increase_contrast enabled`; appearance uses `xcrun simctl ui <udid> appearance dark`.

**Every module:**

1. `swift run --scratch-path .build AstraCoreCheck` passes, including the module's check file with decode checks for every response type in its `api-shapes.md` rows, request-body goldens for every write, and logic checks for every pure function it adds.
2. `xcodebuild ... -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build` succeeds with zero Swift 6 concurrency warnings in the module's files.
3. Every screen renders in demo mode with realistic fixtures, and every state of 5.0 is reachable through a scenario and launch arguments.
4. Screenshots with `scripts/sim.sh demo <route> [scenario]` and `scripts/sim.sh shot <module>/<name> [--dark] [--text ax5|xxxl] [--contrast]`, saved under `${ASTRA_SHOTS:-$HOME/Library/Caches/AstraShots}/<branch>/<module>/` (outside every worktree, not committed): each listed screen on iPhone 17 Pro in light default and dark default; on an iPhone SE (3rd generation) at AX5 in portrait and in landscape (`-AstraOrientation landscape`); Inbox, Review and ConfirmSheet also in dark with Increase Contrast; one Bold Text pass (`-AstraBoldText`) over the module's screens; paths, matrix and strips also with `-AstraDifferentiateWithoutColor`; each listed state screenshot in light default.
5. No raw colors, no materials in content, no emoji, no looping animation (grep the module folder for `Color(red`, `Color.green`, `ultraThinMaterial`, `glassEffect`, `.glassProminent` outside toolbars, `.pulse`, `.bounce`, `repeatForever`).
6. Namespace grep (M0a ships it as `scripts/check-names.sh`): every top-level non-private `struct`, `class`, `enum`, `protocol`, `actor`, `typealias` and `extension LatticeClient` function in the module's folders satisfies the rule of 8.1. It fails the module otherwise.
7. Operator checklist (`docs/design/operator-checklist.md`, a file M0b creates and each module appends its screens to; run by the operator on the iPhone, not module acceptance): VoiceOver itself on each listed screen (rotor headings, each swipe action listed once, focus stays put across a poll), Voice Control "Show names" finds no unlabeled icon buttons, Button Shapes and Reduce Transparency pass, and for M14 the Shortcuts action list.

### 9.3 Order and integration windows

| Wave | Modules (at most three concurrent xcodebuilds) |
|---|---|
| 0 | M0a Core foundation, then M0b App foundation (M0b starts once M0a has pushed its public API skeleton; the two folders are disjoint, so they then run in parallel) |
| 1 | M1 Inbox and approvals, M2 Fleet, M3 Monitoring |
| 2 | M4 Activity, M5 Inventory and upcoming, M7 SSH Guard and agent updates |
| 3 | M6 Networking, M8 Platform, M9 Notifications |
| 4 | M10 Evidence, M11 Account and access, M12 Terminal |
| 5 | M13 VPN, M14 App Intents |

Between waves there is a short serial integration window in which one lane may change Shared files (8.2), Shared fixtures or registries, for example to add a field or a fixture state a module found missing. Requests are collected during the wave; modules work around them with domain-local detail models until then. Everything in AstraCore that exists at the start of a wave is frozen for it (8.4).

### 9.4 M0 Foundation (M0a and M0b)

- **Goal.** Everything every module needs, plus stubs for all of them, so later modules only edit their own files.
- **M0a Core foundation. Work.**
  1. Split `AstraCore.swift`, `LatticeModels.swift`, `LatticeAPI.swift`, `LatticeNetwork.swift`, `LatticeAnalytics.swift` and `LatticeDeepLink.swift` mechanically into `Shared/` and `Domains/` per 8.2 (no behavior change), delete `MonitorEngine`, `BarkClient` and their checks, and delete the old files. Delete the NFT inputs API (`NFTInputs` and its fetch): the v2 nft inputs read view is retired in v3 and nothing consumes it.
  2. Add the Core primitives of 8.3 (including the extended `LatticeAPIError`, envelope decoding for every status and URLError mapping), `WriteFlow`, `QuerySyntax` (syntax, engine and values), `PlanSeal`, `DisplayStates`, `Verdict`, `BadgeCount`, `PathKey`, `TimeDisplay`, `ScopeSet` with `ScopeCatalogue`, `ApprovalVisibility`, `TokenPresets` with `ParityMatrix`, the full `LatticeDeepLink` and `LatticeConsolePath` builders (2.5), and the Shared models and fetches listed in 8.2 with full server shapes.
  3. DemoTransport, DemoRoute, DemoScenario, DemoState, DemoClock, DemoWorld, DemoFixtures registry, SharedFixtures with the coverage of 8.6, and the approvals fixtures needed for Review (moved to M1's file but authored here as a starting point).
  4. `scripts/api-shapes.mjs` and the generated `docs/design/api-shapes.md` (8.9); `scripts/check-names.sh`.
  5. `scripts/sim.sh`: key the clone on checkout and base device (`Astra-<hash>-<device slug>`); create the base device on demand (`xcrun simctl create 'iPhone SE (3rd generation)' com.apple.CoreSimulator.SimDeviceType.iPhone-SE-3rd-generation <iOS 26.5 runtime id>`); `demo ROUTE [SCENARIO] [-- extra launch args]`; `shot` creates the parent directory of `<module>/<name>`, writes to the shared location of 9.2, and accepts `--text`, `--dark` and `--contrast` by calling `simctl ui`.
  6. Checks: SharedChecks (ScopeSet against rbac cases, ApprovalVisibility, TokenPresets coverage, IncidentFilter, SSH Guard derivation from `__tests__/sshGuardBoardModel.test.ts`, path derivation and `PathReason`, `BadgeCount`, `DDNSProfile.health`, `VerdictBuilder` snapshots, error mapping including a 401 with the step-up message and a 409 with `findings`, `WriteFlow` cancel sends nothing, query vectors, deep-link goldens, a check that no Shared function sends `state=active`, `all` or `snoozed`), ContrastChecks, DemoChecks.
- **M0a owns.** Every file under `Sources/AstraCore/Shared/`, `Sources/AstraCore/Demo/` except other modules' `Fixtures/<Domain>Fixtures.swift`, `Checks/AstraCoreCheck/{main,CheckSupport,SharedChecks,ContrastChecks,DemoChecks}.swift` and `Checks/AstraCoreCheck/Fixtures/query-vectors.json`, `scripts/`, `docs/design/api-shapes.md`.
- **M0a acceptance.** AstraCoreCheck passes; the API skeleton (every public signature in Shared and the stubs for every domain file) is pushed first so M0b can start; `api-shapes.md` covers every endpoint named in this document.
- **M0b App foundation. Work.**
  1. App shell (`Shell/`, including ShieldWindow, BannerWindow, SceneDelegate wiring, Router, DeepLinkRouter, BrowseRoot, launch arguments), design system (`Design/`, color sets in `Assets.xcassets`, ObjectRows, Controls, FlowLayout, StateStrip, A11yOverrides, StatusSampler), safety layer (`Safety/`: ActionRunner, ActionHost, ConfirmSheet and ConfirmPage, RevealFlowSheet, SecretRevealStep, OutcomeBanner, IntentAuth, ChangeLog), session layer (`Session/`), settings and welcome (`Settings/`), app lock, BGAppRefresh port.
  2. Delete `DashboardModel.swift`, `DesignSystem.swift` and every old view file (`ContentView`, `InboxView`, `ReviewSheet`, `NodesView`, `ServerDetailView`, `MoreHubView`, `OverviewView`, `MonitorsView`, `InventoryView`, `ActivityView`, `TasksView`, `LogsView`, `NetworkView`, `NotificationsView`, `AccountView`, `SettingsView`, `NodeActions`, `AppSettings`); their behavior is re-specified in modules. `ReviewSheet.swift` stays in git history as the reference M1 ports from.
  3. Stubs for every app file of M1 to M14 below, and the app registries of 8.5.
  4. Update `README.md`, `docs/v2-architecture.md` (rename to `docs/architecture.md` describing v3) and `docs/project-structure.md` to match; create `docs/design/operator-checklist.md`.
- **M0b owns.** `AstraApp/App/{Shell,Design,Safety,Session,Settings}/`, `AstraApp/Assets.xcassets`, `AstraApp/Info.plist`, the docs above.
- **M0 acceptance (both lanes at the end of wave 0).** Common acceptance; every stubbed route reachable by deep link in demo mode; WelcomeFlow, Settings, RevealFlow (code and value steps, with and without session), ConfirmSheet (T3, T4 with dry run and typed name, P with findings), OutcomeBanner over an open sheet, and Browse directory screenshots per 9.2; dark Increase Contrast screenshots of the Review toolbar panel stub and ConfirmSheet; grayscale and deuteranopia screenshots of `StatusSampler` (a debug-only view showing every vocabulary state); state restoration verified with the procedure of 2.6; the privacy and lock acceptance: present Review (`-AstraPresent review:<id>`), background the app with `simctl launch ... com.apple.Preferences`, capture the app-switcher snapshot file from the simulator's data container or a screenshot of the switcher, confirm it shows the cover; relaunch with Face ID to open on and confirm the lock covers the sheet; repeat with RevealFlow and Settings.

### 9.5 Module list

Each module lists the screens it builds, the endpoints it **owns** (8.4) and the ones it **uses** from others, its files, and its acceptance beyond 9.2.

**M1 Inbox and approvals**
- Screens: M1-01 to M1-04.
- Owns: POST `/api/network/approvals/approve`, `/reject`, `/dismiss`. Uses Shared approvals list, incidents, nodes, tasks, audit, expiring, sshguard status, ddns, deliveries, trust, health.
- Files: `Features/Inbox/{InboxRoute,InboxDestination,InboxSearch,InboxStore,ApprovalsStore,InboxScreen,InboxAttentionSection,InboxAllAttentionScreen,ApprovalReviewSheet,ProofStrip,PlanTextView,DecisionPanel,BatchReviewSheet,ApprovalsScreen}.swift`; `Domains/Approvals/{ApprovalsDecisions,ApprovalEvents,DecisionFlow}.swift`; `Demo/Fixtures/ApprovalsFixtures.swift`; `Checks/AstraCoreCheck/ApprovalsChecks.swift`.
- Reads from foundation: VerdictBuilder, BadgeCount, ApprovalVisibility, ObjectRows, SealLabel, ActionRunner, IntentAuth, Router, ChangeLog.
- Acceptance: every step of 6.1 and 6.2 covered by checks where pure (eligibility with decision scopes, `canDismiss`, grouping, hash binding, request bodies, transition verification including both idempotent-200 cases and `approval_stale` on dismiss); `DecisionFlow` check proves a cancelled authentication sends zero requests. Screenshots: Inbox normal, quiet, failing (verdict "Cannot confirm"), Triage token (qualified quiet), stable-list pending row; Review verified, mismatch, stale, companion behind, read-only, already decided by someone else, after approve with waiting, AX5 with wrapped plan and stacked decision panel; BatchReview with one and with several distinct bodies; Approvals needs, history, stuck (`lattice://activity?scope=approvals&view=...`).

**M2 Fleet**
- Screens: M2-01 to M2-15.
- Owns: the M2 row of 8.4. Uses Shared nodes, paths, approvals, audit, tasks, beacon and agent-update plan filing.
- Files: `Features/Fleet/{FleetRoute,FleetDestination,FleetSearch,FleetStore,GroupsStore,NodesScreen,DuplicatesScreen,NodeDetailScreen,NodeOverviewSection,NodeActivitySection,NodeSettingsSection,NodeHistoryScreen,NodeNetworkScreen,NodeCapabilitiesScreen,NodeBeaconScreen,NodeIdentitySheet,NodeDeleteIntent,GroupsScreen,GroupDetailScreen,MapScreen,UnlocatedNodesScreen,CapabilityGatesScreen,GateDetailScreen}.swift`; `Domains/Fleet/{FleetModels,FleetAPI,MapClusters}.swift`; `Demo/Fixtures/FleetFixtures.swift`; `Checks/AstraCoreCheck/FleetChecks.swift`.
- Acceptance: node query fields match `nodeFields.ts`; disable, enable, bulk disable and enable, rotate (secret step, copy only), delete (dry run with every counter, re-plan before send, typed name, `log_store_purge_errs` as partial) demonstrated; request-body goldens for each write. Screenshots: Nodes grouped, with duplicate banner, confined token; NodeDetail Overview online, offline (last facts, no zeros), never reported, disabled; Activity; Settings with and without node:admin; delete ConfirmSheet with dry run; Map and its List view with dashed arcs and legend; Gate detail would-refuse.

**M3 Monitoring**
- Screens: M3-01 to M3-13.
- Owns: the M3 row of 8.4. Uses Shared paths, incidents, windows, deliveries, beacon plan filing.
- Files: `Features/Monitoring/{MonitoringRoute,MonitoringDestination,MonitoringSearch,MonitoringStore,MonitorOverviewScreen,PathsScreen,PathMatrixScreen,PathDetailScreen,PathCharts,ChainDetailScreen,ChecksScreen,CheckDetailScreen,CheckResultsScreen,DefinitionDetailScreen,IncidentsScreen,IncidentDetailScreen,MaintenanceStartSheet,MaintenanceWindowScreen}.swift`; `Domains/Monitoring/{MonitoringModels,MonitoringAPI}.swift`; `Demo/Fixtures/MonitoringFixtures.swift`; `Checks/AstraCoreCheck/MonitoringChecks.swift`.
- Acceptance: charts show gaps and never interpolate; check pause sends `{id, version, enabled}` and a 409 reloads; generated checks show no Pause or Delete; definition delete sends the exact monitor list and version; maintenance start sends `name`, scope, `starts_at`, `ends_at` within 30 days, and End now resends the full window; request-body goldens for each. Screenshots: Paths problems, all, chains; Matrix portrait, landscape, and per-source list at AX5; PathDetail degraded, source offline (sentence replaces chart), compare on; Checks; CheckDetail generated and ordinary; Incidents with each search scope; IncidentDetail open with deliveries, acknowledged, held, pending, resolved, and the toolbar beside the tab bar in portrait (on device for the operator checklist); MaintenanceStart.

**M4 Activity: tasks and audit**
- Screens: M4-01 to M4-07.
- Owns: the M4 row of 8.4. Uses Shared tasks, task results and audit list.
- Files: `Features/Activity/{ActivityRoute,ActivityDestination,ActivitySearch,TasksStore,AuditStore,TasksScreen,TaskRunScreen,TaskNodeOutputScreen,AuditScreen,AuditEventScreen,CorrelationTraceScreen,AuditVerifySheet}.swift`; `Domains/Tasks/TasksAPI.swift`; `Domains/Audit/{AuditAPI,AuditExport}.swift`; `Demo/Fixtures/{TasksFixtures,AuditFixtures}.swift`; `Checks/AstraCoreCheck/{TasksChecks,AuditChecks}.swift` (functions `checkTasks`, `checkAudit`).
- Acceptance: task run state derivation matches `lib/taskLease.ts` cases (pending, stalled, expired); NDJSON export lines are the raw event slices, and CSV and NDJSON match, line by line, a golden produced by running the console's export code with Node on the same fixture (committed under `Checks/AstraCoreCheck/Fixtures/audit-export-*`); a partial scan is labelled "Partial: scanned N events". Screenshots: Tasks; TaskRun running (count, no spinner), finished with failures, expired node; output; Audit changes, integrity; AuditEvent with seal; trace.

**M5 Inventory and upcoming**
- Screens: M5-01 to M5-05.
- Owns: the M5 row of 8.4. Uses Shared expiring.
- Files: `Features/Inventory/{InventoryRoute,InventoryDestination,InventorySearch,InventoryStore,InventoryScreen,MachineDetailScreen,RenewSheet,RemindersSheet,UpcomingScreen}.swift`; `Domains/Inventory/{InventoryModels,InventoryAPI,ReminderSchedule}.swift`; `Demo/Fixtures/InventoryFixtures.swift`; `Checks/AstraCoreCheck/InventoryChecks.swift`.
- Acceptance: `ReminderSchedule` matches `reminderModel.ts` test cases; monthly-equivalent cost matches `inventoryCostModel.ts`. Screenshots: Machines grouped by region with the Upcoming header row; MachineDetail; Renew; Reminders preview; Upcoming with hidden kinds footer.

**M6 Networking**
- Screens: M6-01 to M6-13.
- Owns: the M6 row of 8.4.
- Files: `Features/Networking/{NetworkingRoute,NetworkingDestination,NetworkingSearch,NetworkingStore,OutboundPolicyScreen,PolicyDetailScreen,NodePolicyScreen,DNSScreen,DNSDeploymentScreen,DDNSScreen,DDNSProfileScreen,GeoRoutingScreen,GeoRouteScreen,TunnelsScreen,TunnelScreen,InboundFirewallScreen,SecurityGroupScreen}.swift`; `Domains/Networking/{NetworkingModels,NetworkingAPI}.swift`; `Demo/Fixtures/NetworkingFixtures.swift`; `Checks/AstraCoreCheck/NetworkingChecks.swift`.
- Acceptance: DNS plan 409 findings decode and drive the Findings step with the unchecked acceptance toggle; publish preview is computed on device and labelled; group-policy plan results render filed, conflicts and orphans; convert says it creates a group policy first. Screenshots: each list; group-policy plan result; DNS plan with findings; DDNS failing; InboundFirewall.

**M7 SSH Guard and agent updates**
- Screens: M7-01 to M7-05.
- Owns: the M7 row of 8.4. Uses Shared SSH Guard status and derivation, agent-update plan filing, M2 capabilities.
- Files: `Features/SSHGuard/{SSHGuardRoute,SSHGuardDestination,SSHGuardSearch,SSHGuardStore,AgentUpdatesStore,SSHGuardBoardScreen,SSHGuardNodeScreen,SSHGuardArmSheet,AgentUpdatesScreen,AgentReleaseScreen}.swift`; `Domains/SSHGuard/{SSHGuardAPI,SSHGuardRotation}.swift`; `Domains/AgentUpdates/{AgentUpdatesModels,AgentUpdatesAPI}.swift`; `Demo/Fixtures/{SSHGuardFixtures,AgentUpdatesFixtures}.swift`; `Checks/AstraCoreCheck/{SSHGuardChecks,AgentUpdatesChecks}.swift` (functions `checkSSHGuard`, `checkAgentUpdates`).
- Acceptance: arm request bodies (defaults, `accept_findings` only when checked) and rotation bodies (`rotate_from_sha256`, `rotateEligibility`, `buildRotationRequest` cases) match goldens; arm then confirm in demo files two approvals and Inbox shows the `reverting` countdown; a node with `actionable_approval_id` opens Review instead of filing; knock reveal requires the session and step-up; "Plan all behind" opens BatchReview with refusals listed. Screenshots: board in each search scope; ScopeDenied without network:plan; node reverting with countdown; arm sheet with findings; reveal without session; AgentUpdates nodes, distribution, mirrors.

**M8 Platform**
- Screens: M8-01 to M8-11 and the Extensions list.
- Owns: the M8 row of 8.4. Uses Shared `callPlugin`.
- Files: `Features/Platform/{PlatformRoute,PlatformDestination,PlatformSearch,PlatformStore,PublishingStore,PluginsScreen,PluginDetailScreen,ExtensionsScreen,ExtensionPageScreen,PublishingScreen,ShareDetailScreen,BindingDetailScreen,StorageTokenDetailScreen,StoreScreen,StoreBucketScreen,StoreEntryScreen,SystemScreen}.swift`; `Domains/Platform/{PlatformModels,PlatformAPI,ExtensionPageModel}.swift`; `Demo/Fixtures/PlatformFixtures.swift`; `Checks/AstraCoreCheck/PlatformChecks.swift`.
- Acceptance: extension table and detail kinds decode from manifest fixtures modelled on `PluginView.vue`; share reveal goes through step-up and offers Share; section gates follow the server wrappers (`/api/plugins` needs `audit:read`). Screenshots: Plugins, PluginDetail, an extension table page, Publishing routes and tokens, ShareDetail, Store bucket, System.

**M9 Notifications and webhooks**
- Screens: M9-01 to M9-07.
- Owns: the M9 row of 8.4. Uses Shared deliveries.
- Files: `Features/Notify/{NotifyRoute,NotifyDestination,NotifySearch,NotifyStore,NotificationsScreen,SentLogScreen,DeliveryDetailScreen,ChannelDetailScreen,RuleDetailScreen,WebhooksScreen,WebhookDetailScreen}.swift`; `Domains/Notify/{NotifyModels,NotifyAPI}.swift`; `Demo/Fixtures/NotifyFixtures.swift`; `Checks/AstraCoreCheck/NotifyChecks.swift`.
- Acceptance: the test-send row is web-only; deliveries link back to incidents; Sent filters send `channel_id`, `event_type`, `outcome`. Screenshots: Routing, Sent filtered by failed, DeliveryDetail with attempts, ChannelDetail, Webhooks with "reaches nobody".

**M10 Evidence**
- Screens: M10-01 to M10-04.
- Owns: the M10 row of 8.4.
- Files: `Features/Evidence/{EvidenceRoute,EvidenceDestination,EvidenceSearch,EvidenceStore,EvidenceScreen,ConnectionsScreen,ConnectionDetailScreen,LogExplorerScreen}.swift`; `Domains/Evidence/{EvidenceModels,EvidenceAPI}.swift`; `Demo/Fixtures/EvidenceFixtures.swift`; `Checks/AstraCoreCheck/EvidenceChecks.swift`.
- Acceptance: capture start sends the specified defaults (`name`, node filter, default level, `ttl_seconds`) with the T2 dialog; stop with T2; log paging by `before_seq`. Screenshots: readiness, connections, connection detail with hops, log explorer with find.

**M11 Account and access**
- Screens: M11-01 to M11-06, all inside the Settings sheet's stack.
- Owns: the M11 row of 8.4.
- Files: `Features/Account/{AccountRoute,AccountDestination,AccountSearch,AccessStore,SecurityScreen,PasskeyDetailScreen,AccessScreen,UserDetailScreen,TokenDetailScreen,SSOProviderScreen}.swift`; `Domains/Access/{AccessModels,AccessAPI}.swift`; `Demo/Fixtures/AccessFixtures.swift`; `Checks/AstraCoreCheck/AccessChecks.swift`.
- Acceptance: revoking the phone's own token warns and signs out after success; Security without a session shows the explanation; passkey delete runs confirm, Face ID and step-up inside one flow in the Settings sheet. Screenshots: Security with and without session, Access tokens, TokenDetail own-token warning.

**M12 Terminal**
- Screens: M12-01, M12-02.
- Owns: the M12 row of 8.4.
- Files: `Features/Terminal/{TerminalRoute,TerminalDestination,TerminalSearch,TerminalStore,TerminalSessionsScreen,TerminalTranscriptScreen}.swift`; `Domains/Terminal/{TerminalModels,TerminalAPI,TranscriptCleaner}.swift`; `Demo/Fixtures/TerminalFixtures.swift`; `Checks/AstraCoreCheck/TerminalChecks.swift`.
- Acceptance: `TranscriptCleaner` golden cases (colors, cursor moves, carriage-return progress bars, alternate screen detection); no input path exists in the code; without `terminal:open` the screens show the whole-screen denied state. Screenshots: sessions, transcript, full-screen-program notice.

**M13 VPN**
- Screens: M13-01 to M13-04.
- Owns: the M13 row of 8.4. Uses Shared `callPlugin` (vpn-core strings of 8.9) and M3's chains call.
- Files: `Features/VPN/{VPNRoute,VPNDestination,VPNSearch,VPNStore,VPNUsersScreen,VPNUserDetailScreen,VPNLinesScreen,VPNLineDetailScreen}.swift`; `Domains/VPN/{VPNModels,VPNAPI}.swift`; `Demo/Fixtures/VPNFixtures.swift`; `Checks/AstraCoreCheck/VPNChecks.swift`.
- Acceptance: fixtures built from `server_vpncore.go` responses; a decode failure shows companion behind, never an empty list; link reveal posts `{step_up_grant}` to `.../link/reveal`; rotate and revoke request goldens. Screenshots: users, user detail with reveal, lines, line detail.

**M14 App Intents**
- Screens: none.
- Work: `OpenNodeIntent` (parameter: node, from `NodeDirectory`), `ReviewApprovalIntent` (opens the Review sheet only; never approves), both routed through `DeepLinkRouter`. No Spotlight indexing, no widgets, no AstraCore code and no check file.
- Files: `Features/Intents/{OpenNodeIntent,ReviewApprovalIntent,LatticeShortcuts}.swift`.
- Acceptance: both intents build and route correctly when invoked through `-AstraRoute` equivalents in demo mode; the Shortcuts action list is on the operator checklist.

---

## 10. Risks, open questions, and out of scope

### 10.1 Risks

1. **Reveals need a second credential.** The PAT cannot step up, so every S action needs the optional session. If the operator declines it, S actions show the explanation. Minting `secrets:reveal` onto a phone token remains an operator decision the design does not recommend.
2. **Plugin RPC payloads are not versioned.** vpn-core reads go through `/api/plugins/call`. Fixtures come from `server_vpncore.go`; decode failures show companion behind.
3. **The console changes weekly.** Incidents, check definitions and topology changed throughout October. Native writes are kept to endpoints whose shapes are verified in this document; tolerant decoders keep unknown additive fields from breaking reads.
4. **Polling cost.** `/api/monitors/paths` for about 200 paths is heavy on cellular. Mitigated by visible-only polling, 60 s cadence, Low Power doubling, and backoff. Battery use is unmeasured until M3 runs on the device.
5. **Badge truth.** iOS schedules background refresh, possibly hours apart. Inbox shows the badge's source time so a stale badge is not trusted.
6. **Server notify templates** link only `lattice://approvals/{id}` today. Incident, task and node links in Bark messages need a server template change to benefit from the new deep links.
7. **File and type name uniqueness** across the app and AstraCore is easy to break in parallel lanes. The namespace rule of 8.1, `scripts/check-names.sh`, the endpoint ownership table of 8.4 and the shared rows in `Design/ObjectRows.swift` avoid it; any remaining collision fails the build immediately.
8. **Agents cannot exercise real VoiceOver, Voice Control, Button Shapes or touch.** Module acceptance covers what launch arguments and simctl can reach; the operator checklist covers the rest on the iPhone, so some accessibility defects surface only there.
9. **The server's approval filter can hide work.** A token without a plugin's read scope never sees its approvals. Inbox names the hidden plugins and the verdict qualifies itself, but it cannot count what it cannot see.

### 10.2 Open questions for the operator

1. Batch approve on the phone follows the console's grouped event with every body on screen and one Face ID. If the operator prefers no batch decisions on the phone, M1 drops BatchReviewSheet and "Plan all behind" opens the console's approvals page instead.
2. Is publishing DNS IPs and running DDNS from the phone (both T3, direct writes to an external provider) acceptable for failover, or should they be web-only?
3. Should the accent stay cobalt, or move to a darkened teal that passes the grayscale and deuteranopia check against `status.ok.fill`? M0 implements cobalt unless told otherwise.
4. Should the server gain an incident `?open=` parameter, and should `AccessView`, `UsersView`, `TokensView` and `SsoView` read `?open=`, so "Open on web" lands on the object instead of a list?
5. The brief calls stale approvals inspect-only. This spec reads that as no approve or reject, and still allows Dismiss (the server allows it only on stale agent-update and SSH Guard rows) and Replan (P) from a stale row (6.1 step 5). Confirm.
6. T1 swipes (acknowledge, snooze) state their consequence in the label but not the scope before the write, as an exception to the brief's rule (6.5). Confirm.
7. Triage omits `network:plan`, so a Triage token sees no approvals at all. Should Triage gain `network:plan` (which also lets it file plans that still need approval) so the Inbox can show what waits?

Defaults taken for implementation (2026-10-28), so no module waits on these. The operator can reverse any of them later; each is local to one module.

1. Batch approve stays native as specified (M1 builds BatchReviewSheet).
2. DNS publish and DDNS run stay native at T3: failover is a tier 2 to 3 job.
3. The accent stays cobalt.
4. No server or console change is part of v3. "Open on web" lands on the list where the console reads no `?open=`, exactly as 2.5 says.
5. Confirmed as written: a stale approval cannot be approved or rejected; Dismiss and Replan stay available where the server allows them.
6. Confirmed as written: T1 swipes state the consequence in the label.
7. Triage stays without `network:plan`. Inbox names the hidden approval plugins and the verdict qualifies itself; the "Operator" preset carries `network:plan`.

### 10.3 Out of scope for v3

Lock Screen widget and other WidgetKit surfaces; Spotlight `IndexedEntity` indexing; App Group and shared Keychain; Live Activities and actionable notifications (the server sends no push); Universal Links and passkey login or step-up (need a signed build with Associated Domains); SSO login; native terminal session creation and typing; native script-task authoring; QR scanning of tokens; zoom transitions; the topology force graph; a disk cache of server data; the console's zh-CN localization; iPad-specific layouts beyond the adaptive sidebar; a UI test target; any client-side alerting (`MonitorEngine` and `BarkClient` are removed); the v2 nft inputs read view (retired, its API deleted in M0a).
