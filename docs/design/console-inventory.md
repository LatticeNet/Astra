# Lattice console and API inventory (2026-10-28)

Source for the Astra parity design. Console paths are under `lattice-dashboard/src/`, server paths under `lattice-server/internal/server/`. **[A]** files an approval, **[D]** acts directly, **[S]** needs a step-up grant.

**Key:** **[A]** files an approval (a plan that someone must approve before anything reaches a node). **[D]** acts directly. **[S]** needs a fresh step-up grant.

## 0. How the API works (applies to every page)

- **Session login:** `POST /api/login` sets the `lattice_session` cookie (HttpOnly, SameSite=Strict). Every POST/PUT/PATCH/DELETE on a cookie session must send the `X-Lattice-CSRF` header, using the `csrf_token` from login or `/api/me` (`lib/api/client.ts`).
- **API tokens:** send `Authorization: Bearer <token_id>.<secret>`. Bearer requests skip CSRF.
- **Secrets:** anything secret goes through one gate (`secret_reveal.go`). An interactive session needs a step-up grant. A token needs the `secrets:reveal` scope, which only a full admin can add.
- **Scopes:** the full list is `rbac.KnownScopes` in `internal/rbac/rbac.go`, mirrored with descriptions in `lib/scopes.ts`. `*` means full administrator. `proxy:*` and `vpncore:*` are interchangeable. Scopes can be confined to a node allowlist.
- **Approvals:** you approve by sending `plan_sha256` = lowercase hex SHA-256 of the UTF-8 `plan` string, exactly as received (`composables/usePlanDigest.ts`).
- **List shapes vary.** Many lists come back as a bare array (nodes, monitors, machines, ddns, tunnels, plugins, tokens, notify channels, subscription shares, geo). Approvals and tasks return an array with no params, but an envelope `{approvals|tasks, total, limit, offset}` once you add any filter.
- **Streaming:** the only browser streaming endpoint is the terminal WebSocket at `/api/terminal/sessions/{id}/attach`. A missing Origin header is accepted, so a native client works. There is no SSE. Everything else is polled (about every 1–60 s, `composables/useAsyncData.ts`). `/api/agent/*` (including control and terminal streams) is for node agents only.

## 1. Navigation map

Routes are built from `router/nav.ts`; the view for each route is in `router/routeComponents.ts`. Pages with layers use `?view=` (`composables/useLayer.ts`). Side sheets open with `?open=<id>`. Each page remembers its last view (`router/viewMemory.ts`).

| Section | Label → path | View | Gate (any of) | Sub-views / query modes |
|---|---|---|---|---|
| Overview | Overview `/` | `views/OverviewView.vue` | none | — |
| Fleet | Nodes `/nodes` | `views/fleet/NodesView.vue` | node:read | `layout=card\|list`, `q`, `agent`, `tag`, `os`, `group`, `status` |
| | Node `/nodes/:id` | `views/fleet/NodeDetailView.vue` | node:read | `view=overview\|activity\|settings` |
| | Node groups `/node-groups` (old `/groups` redirects) | `views/fleet/GroupsView.vue` | group:read | `q`, `open` |
| | Map `/map` | `views/fleet/MapView.vue` | node:read | `layer=latency` turns on latency arcs |
| | Inventory `/inventory` | `views/fleet/InventoryView.vue` | inventory:read | `q`, `group=region\|country\|role\|group\|status\|tag\|none`, `machine`, `node` |
| | Upcoming `/upcoming` | `views/fleet/UpcomingView.vue` | any read scope of the item kinds | `kind` |
| | Monitoring `/monitoring`, `/monitoring/:id` | `views/fleet/MonitoringView.vue` | monitor:read | see next row |
| | ↳ Monitoring modes | | | `view=overview\|topology\|checks\|incidents`. Topology: `as=graph\|list`, `topo=all\|paths\|chains`, `topo.sources`, `paths.q`, `paths.unmeasured`, `path`, `peek`, `compare`. Checks: `monitors.q`, `node`, `open`. Incidents: `state=active\|open\|acknowledged\|snoozed\|pending\|resolved\|all`, `kind`, `q`. All: `window=1h\|6h\|24h\|3d\|7d\|14d`. Old `?view=paths\|latency\|network` redirects. |
| VPN | Section exists only to hold plugin pages (`PLUGIN_HOST_SECTIONS`) | | | vpn-core Lines/Users/Node Profiles/Usage and Sub-Store (§4) |
| Operations | Approvals `/approvals` | `views/operations/ApprovalsView.vue` (+`ApprovalReview.vue`) | network:plan, netpolicy:admin, node:admin, dns:admin, proxy:read, tunnel:admin | `view=needs\|history\|stuck` (bare URL picks one automatically), `range=1h\|24h\|7d\|30d\|all\|custom`, `since`, `until`, `offset`, query tokens `status:`/`plugin:`/`node:` |
| | Tasks `/tasks` | `views/operations/TasksView.vue` (+`TaskComposer.vue`, `TaskRunDetail.vue`) | task:read | `view=runs\|new`, range/offset, tokens `status:`/`origin:`/`node:`/`approval:` |
| | Terminal `/terminal` | `views/operations/TerminalView.vue` | terminal:open | `node_id`, `session_id`, `connect` |
| | Audit `/audit` | `views/operations/AuditView.vue` | audit:read | `view=changes\|all\|integrity`, range, tokens `action:`/`actor:`/`decision:`/`node:`/`scope:`/`trace:` |
| Networking | Outbound policy `/network/outbound` (old `/network/policy` redirects) | `views/networking/PolicyView.vue` | netpolicy:read | `view=policies\|nodes\|matrix`, `policy` (sheet) |
| | Self-host DNS `/network/dns` | `views/networking/DnsView.vue` | dns:admin | `open` |
| | DDNS `/network/ddns` | `views/networking/DdnsView.vue` | ddns:admin | `open` |
| | Geo-Routing `/network/geo-routing` | `views/networking/GeoRoutingView.vue` | geo:read | `open` |
| | Tunnels `/network/tunnels` | `views/networking/TunnelsView.vue` | tunnel:admin | `open` |
| | SSH Guard `/network/ssh-guard` | `views/networking/SshGuardView.vue` | sshguard:admin | `q`, posture `secured\|password_open\|partial\|unknown`, coverage `confirmed\|reverting\|armPending\|open\|failed\|excluded`, `node_id` |
| | Inbound firewall and WireGuard mesh | plugin pages | | ordered first and third in this section (`layout/navigationModel.ts`) |
| Platform | Plugins `/platform/plugins` | `views/platform/PluginsView.vue` | audit:read, plugin:admin, plugin:verify | `open` |
| | Publishing `/platform/publishing` | `views/platform/PublishingView.vue`, `PublishingSharesPane.vue` | kv:read, static:read, proxy:admin | `view=overview\|routes\|tokens\|buckets`, `origin=all\|kv\|static\|share`, `open`, `create`, `for` |
| | Store `/platform/store` (`/platform/kv` and `/platform/static` redirect) | `views/platform/StoreView.vue` | kv:read/write, static:read/write | `kind=kv\|static`, `bucket` |
| | Evidence `/platform/evidence` (`/platform/logs` and `/platform/trace` redirect) | `views/platform/EvidenceView.vue` + `Evidence*.vue` | log:read | `view=overview\|explore\|collection`, `lens=connections\|log`, `q`, `source`, `conn`, filters `node`/`user`/`dst`/`line`/`session`, `collection.q` |
| | Notifications `/platform/notifications` | `views/platform/NotificationsView.vue` | notify:admin | `view=routing\|sent`, `channel`, `event`, `outcome`, `open` |
| | Webhooks `/platform/webhooks` | `views/platform/WebhooksView.vue` | notify:admin | `open` |
| | Agent Updates `/platform/agent-updates` | `views/platform/AgentUpdatesView.vue`, `AgentMirrorsLayer.vue` | node:admin | `view=nodes\|distribution\|mirrors`, `q` |
| | System `/platform/system` | `views/platform/SystemView.vue` | `*` | `view=plugins\|http\|store`, `range=1h…5y` |
| | Plugin page `/plugins/:pluginId/:route*` | `views/platform/PluginView.vue`, `PluginFrameHost.vue` | the plugin's own scopes | — |
| Settings | Security & 2FA `/settings/security` | `views/settings/SecurityView.vue` | none (forced here if MFA is required) | — |
| | Capability Gates `/settings/capabilities` | `views/settings/CapabilitiesView.vue` | node:read | — |
| | Access `/settings/access` (old users/tokens/sso URLs redirect) | `views/settings/AccessView.vue` → `UsersView`, `TokensView`, `SsoView` | user:admin, token:admin, oidc:admin | `view=users\|tokens\|sso` |
| | Appearance, About | `views/settings/AppearanceView.vue`, `AboutView.vue` | none | — |
| (no page) | Login `/login` | `views/auth/LoginView.vue` | public | `redirect`, `mfa` |

**Shell features** (`layout/`):
- Command palette (`components/common/CommandPalette.vue`): jump to pages, nodes, approvals, VPN identities and shares; can batch-approve system events.
- Trust banner (`/api/plugin-trust`) and a recent-errors panel.
- Sidebar badges from `layout/useNavSignals.ts`: approval counts, task counts, nodes.

**List search syntax** (`lib/query/syntax.ts`):
- `field:value`, with `=`/`:=` for exact match and `>`, `>=`, `<`, `<=` for comparisons.
- `OR` or `|`, parentheses, `-term` or `NOT` to negate, quoted values.
- `sort:-field`.
- Node fields (`lib/query/nodeFields.ts`): name, ip, tag, group, provider, country, region, os, agent, cap, status, cpu, mem, disk, rx, tx, last_seen, and others.

## 2. Pages: what you can read and do

| Page | Read | Do |
|---|---|---|
| Overview | Active incidents, attention rows (offline nodes, stalled tasks, failing DDNS), four counts (online nodes / approvals waiting / tasks failed in 24h / due in 7 days), due this week, map thumbnail, recent changes | Acknowledge or snooze an incident (`POST /api/incidents/ack\|snooze`, monitor:admin) [D] |
| Nodes | Grouped table or cards: status, agent version, rx/tx and CPU/memory metrics, last seen, duplicate-node report; node side sheet with machine, SSH Guard status, tasks | Enroll (`POST /api/nodes/enroll-token`) [D]; disable/enable, including bulk (`/api/nodes/disable`) [D]; rotate token [D]; open terminal. All node:admin |
| Node detail | **Overview:** facts, history charts (`/api/nodes/history?range`), effective network (`/api/nodes/network`), paths, beacon. **Activity:** timeline of audit, tasks and approvals. **Settings:** identity, capabilities, geo, IP config, debug, auto-update | Edit identity (`/api/nodes/update`) [D]; per-node capability enroll/exclude (`/api/nodes/capabilities`) [D]; geo set/clear/resolve [D]; IP-discovery override (`/api/nodes/ip-config`, node:admin+network:plan) [D]; agent debug [D]; generate reconfigure command [D]; rotate token [D]; delete with dry-run preview (`/delete/plan`, `/delete`) [D, irreversible]; auto-update policy (`/api/nodes/agent-updates`) [D] and update plan / force plan [A]; beacon plan [A] and rotate [D] |
| Node groups | Groups with member health and "Used by" | Create/edit with a selector or static members (`POST /api/groups`) [D]; preview selector; delete (group:admin) |
| Map | Status clusters, latency arcs, list of nodes with no location | Locate missing nodes (`/api/nodes/geo/resolve`, node:admin) [D] |
| Inventory | Machines grouped with vendor, price, monthly equivalent, group spend, renewal countdowns and reminders | Create/edit/delete machine profile, renew, upsert vendor [D]; preview then send reminders (`/api/machines/reminders/run`) [D]; reveal console/detail link [S]. All inventory:admin |
| Upcoming | One list of what runs out: machine renewals, VPN users, shares, TLS certificates (`/api/expiring?within`) | Record a renewal (`/api/machines/renew`) [D] |
| Monitoring | **Overview:** health and degraded verdicts. **Topology:** paths matrix and line chains as graph or list, path chart. **Checks:** monitors and check definitions. **Incidents:** incidents and maintenance windows | Check create/edit/delete (`/api/monitors`, `/update`, `/delete`) [D]; check definitions create/update/preview/delete/forget [D]; latency probe plan (`PUT /api/monitors/latency`) [D]; retention (`/settings/update`) [D]; beacon replan [A]; incident ack/unack/snooze [D]; maintenance window upsert/end/delete [D]. Writes need monitor:admin |
| Approvals | Needs-you / history / stuck lists, plan text, waiting reasons, staleness | Approve and apply (`queue_apply=true`), or approve without applying; reject; dismiss; batch approve/reject; replan a stale agent update. Needs network:apply plus the plugin's decision scope |
| Tasks | Runs with per-node results, exit codes, attempts and lease age | Create a script task (`POST /api/tasks`, task:run, optionally confined by capability) [D]; rerun, rerun one node, cancel, delete [D]; reveal script [S] |
| Terminal | Session tabs; transport is stream or poll | Create a session [D]; type, resize, close; attach over WebSocket. terminal:open |
| Audit | Event table with filters; hash-chain verification | Verify the chain (`/api/audit/verify`); export CSV, NDJSON and the audit head (built in the browser) |
| Outbound policy | Group policies, per-node policies, egress/ingress reachability matrix, policy graph | Upsert/delete a group policy [D] then plan it, one approval per node [A]; edit node policy [D] then plan it [A]; convert a node's manual policy into an outbound policy [A]. netpolicy:admin |
| Self-host DNS | Deployments, drift, certificate watch, publish errors | Upsert/delete [D]; plan (409 lockout findings unless accepted) [A]; publish IPs to the DNS provider [D]; measure an external engine's certificate [D] |
| DDNS | Profiles: current / failing / stale | Save, delete, run now (writes to the DNS provider) [D] |
| Geo-Routing | Routes and the DNS nodes behind them | Upsert/delete (geo:admin) [D]; preview config (no approval) |
| Tunnels | cloudflared tunnel profiles | Create/delete [D]; plan [A] |
| SSH Guard | Per-node SSH posture board, knock state, arm/confirm history | Arm (`/api/sshguard/plan`) [A]; confirm, which cancels the automatic revert (`/confirm`) [A]; reveal knock sequence [S]; rotate knock [A]; exclude a node via capability [D] |
| Plugins | Every plugin with health, capabilities and risk, contributions | Lifecycle verified → installed → active ⇄ disabled (`POST /api/plugins/lifecycle`, plugin:admin) [D]; verify an uploaded bundle (plugin:verify) |
| Publishing | Every published route across origins, storage tokens, buckets, subscription shares | Delete a binding, revoke a token [D]; share create/edit expiry and interval/rotate/refresh/delete [D]; reveal share URL [S]; create bucket/binding/token (`components/platform/StorageCreateSheet.vue`) [D] |
| Store | Buckets and their KV entries or static objects | Put a KV entry or static object [D] |
| Evidence | Recording readiness per node, connection records, raw logs, hops, stats, budgets | Start/stop capture sessions (log:read to start, log:admin to stop) [D]; trace policy (log:admin) [D]; log sources [D]; evidence budgets (full admin only) [D] |
| Notifications | **Routing:** channels (telegram, bark, discord, webhook) with health and fallback; rules; witness status. **Sent:** delivery log | Channel upsert/delete/test [D]; test send (notify:send); rule upsert/delete [D]; witness plan [A] |
| Webhooks | Inbound webhooks, which ones reach nobody, deliveries | Create (shows the secret once), edit, rotate secret, delete, test [D] |
| Agent Updates | **Nodes:** per-node running vs. target version, last fetch. **Distribution:** releases and artifacts. **Mirrors:** registry and each node's source order | Policy upsert/delete [D]; plan one node or all behind nodes [A]; import/delete artifacts [D]; mirror plan [A] |
| System | Control-plane host, process, data files, store, HTTP routes, plugin performance, probe | Read only |
| Security | Account 2FA and passkeys | Change password; TOTP enroll/activate/disable; passkey add/delete (step-up if TOTP is on) and rename |
| Capability Gates | Each gate and what turning it on would refuse | Toggle enforced (node:admin) [D] |
| Access | Users, tokens, SSO providers | User create/update/delete; token create (secret shown once)/revoke/delete; OIDC provider upsert/delete/test |
| About / Appearance | Server build info vs. dashboard version; theme, palette, language (en, zh-CN) | Appearance is stored on the device only |

## 3. Server API

The paths below are what the console calls (mapped in `lib/api/index.ts`). "In handler" means the scope is checked per HTTP method inside the handler rather than by the route wrapper.

| Area | Endpoints (methods) | Scope | Shape notes |
|---|---|---|---|
| Login and session | `POST /api/login`, `GET\|POST\|DELETE /api/login/totp`, `GET /api/me`, `POST /api/logout`, `POST /api/auth/password` | public / session | Login returns `{csrf_token, actor_id}` or `{totp_required, challenge_id}`. `/me` returns `{actor_id, username, scopes[], server_allowlist[], csrf_token, totp_enabled, mfa_required}` |
| 2FA and passkeys | `/api/2fa/totp/{enroll,activate,disable}`; `/api/auth/webauthn/login/{begin,finish}`; `/api/security/webauthn/{register/begin,register/finish,credentials,credentials/rename,credentials/delete}` | session | Enroll returns `{secret, otpauth_uri, recovery_codes}` |
| Step-up | `POST /api/security/step-up {code}`, `/step-up/webauthn/{begin,finish}` | session | Returns `{ok, grant, expires_at}`; send the grant as `step_up_grant` |
| SSO | `GET /api/auth/oidc`, `/start?provider=`, `/callback`; `/api/auth/oidc/providers[/delete\|/test]` | public / oidc:admin | `{providers:[…]}` |
| Users and tokens | `/api/users[/update\|/delete]`; `/api/tokens[/revoke\|/delete]` | user:admin; token:admin | `{users}`; tokens are a bare array; create returns `{id, token, view}` |
| Nodes | `GET /api/nodes`, `/status-history`, `/history?node_id&range`, `/network?node_id[&rules=1]`, `/duplicates`; `POST /update`, `/disable`, `/rotate-token`, `/enroll-token`, `/reconfigure-command`, `/delete[/plan]`, `/debug`, `/ip-config`, `/terminal-transport`; `GET\|POST /geo`, `/geo/resolve`; `GET\|POST /capabilities`; `GET\|POST /api/capabilities` | node:read / node:admin | Node: `id, name, tags, role, public_ip, online, status, metrics, host_facts, geo, agent_runtime, loop_health, group_ids, beacon` |
| Beacon | `GET /api/nodes/beacon`, `POST /plan`, `POST /rotate` | monitor:read; plan needs monitor:admin+node:admin+network:plan | Plan returns 409 with `findings` when something blocks it |
| Agent updates | `/api/nodes/agent-updates` (GET\|POST), `/releases`, `/delete`, `/plan`, `/artifacts[/import\|/delete]`, `/mirrors[/plan]` | node:read / node:admin+network:plan | `{policies}`; plan returns an ApprovalView |
| Approvals | `GET /api/network/approvals` (`?id`, `?count=1`, filters `status,plugin,node_id,since,limit,offset,include=plan,include_dismissed`); `POST /approve {approval_id, queue_apply, plan_sha256}`, `/reject`, `/dismiss` | Visibility depends on the plugin (`approvalPrimaryScopeAllows`, server.go:7949); deciding needs network:apply | `{approval}` / `{counts}` / bare array / `{approvals,total,…}`; 409 `approval_stale` |
| Tasks | `GET\|POST /api/tasks`, `/counts`, `/cancel`, `/delete`, `/rerun`, `/rerun-node`, `/reveal-script`; `GET /api/task-results` (`omit_output=1`) | task:read / task:run | Filters `status, since, node_id, origin, approval_id, limit, offset` |
| Terminal | `GET\|POST /api/terminal/sessions`; `/sessions/{id}/{events?cursor, input, resize, close}`; **WebSocket** `/sessions/{id}/attach` | terminal:open | `{sessions}`; events return `{session, events}` |
| Audit | `GET /api/audit` (`action, decision, node_id, actor_id, token_id, scope, correlation_id, q, at_from, at_to, exclude_action, exclude_decision, limit, offset`), `/verify` | audit:read | `{events, total, limit, offset, scanned, complete}` |
| Monitoring | `/api/monitors` (GET\|POST), `/update`, `/delete`, `/results`, `/series`, `/paths?window`, `/settings[/update]`, `/latency` (GET\|PUT), `/latency/{rollups,series}`, `/definitions[/update\|/preview\|/delete\|/forget]` | monitor:read / monitor:admin | Paths return `{window, sources, targets, paths, degraded_at, beacon_replans}`; check types `tcp\|http\|icmp\|tls\|beacon\|dns` |
| Incidents | `/api/incidents`, `/ack`, `/unack`, `/snooze`; `/api/maintenance-windows[/delete]` | monitor:read / monitor:admin | `{incidents, windows, durable, now}` |
| Inventory | `/api/machines[/update,/delete,/renew,/reminders/run,/reveal-link]`, `/api/machine-vendors[/delete]`, `GET /api/expiring?within` | inventory:read / inventory:admin | Costs are `price_cents` + `currency`; expiring returns `{items, totals, hidden_kinds}` |
| Groups | `/api/groups` (GET\|POST), `/delete`, `/reorder`, `/members`, `/preview`, `/used-by`, `/seed` | group:read / group:admin | — |
| Outbound policy | `/api/netpolicy[/plan,/delete,/convert,/graph,/matrix?direction]`, `/api/group-policies[/delete,/plan]` | netpolicy:read / netpolicy:admin | — |
| NetGuard | `/api/netguard/{groups,zones,nodes,reality,review,bindings,nodes/adopt,plan,node-group-bindings[/plan,/delete]}` | netguard:read / netguard:admin | Normally reached through the plugin page |
| WireGuard, lines, nftables | `POST /api/network/wireguard/plan`; `/api/network/lines/{chains,chains/plan,chains/remove-plan,managed-rollout}`; `/api/network/nft/{plan,inputs}` | wireguard:admin; proxy:read / network:plan | — |
| SSH Guard | `/api/sshguard/{plan,confirm,knock,knock/reveal,status}` | sshguard:admin (+ network:plan per node) | Status returns `{ok, nodes}` |
| DNS, DDNS, geo, tunnels | `/api/dns/{deployments[/delete],plan,publish,measure-cert}`; `/api/ddns[/delete,/run]`; `/api/geo-routing[/delete,/plan]`; `/api/tunnels[/delete,/plan]` | dns:admin; ddns:admin; geo:read / geo:admin; tunnel:admin | DNS plan takes `accept_lockout_risk` |
| VPN / proxy core | `/api/proxy/{inbounds,users,users/reveal-credentials,usage,profiles,discovered,managed/*,nodes/…}`, `/api/vpn/users/{id}/link` (GET/POST/PATCH/DELETE), `/api/vpn/cutover` | proxy:* / vpncore:* | Mostly used through vpn-core's plugin RPC |
| Shares | `/api/subscription-shares` (GET\|POST), `/{id}` (PATCH\|DELETE), `/{id}/{rotate,refresh,reveal}`; public `/sub/<token>` | proxy:admin | — |
| Store and publishing | `/api/kv[/delete]`, `/api/static[/delete]`, `/api/storage/{buckets,bindings[/delete],tokens[/revoke]}?kind=`, `/api/publishing/records` | kv:* / static:* | — |
| Evidence | `/api/logs/{sources[/delete],query,stats}`; `/api/trace/{connections,lines,sessions[/stop],policy,markers,hops,stats,rollups}`; `/api/evidence/settings` | log:read / log:admin | — |
| Notifications | `/api/notify/{channels[/delete,/test],test,deliveries,catalogue,witness[/plan],rules[/delete],webhooks[/delete,/rotate,/deliveries,/test]}`; public `/api/hooks/<id>` | notify:admin (test send: notify:send) | — |
| Plugins | `GET /api/plugins`, `/api/plugin-contributions`, `/api/plugin-trust`, `/api/plugins/lifecycle`, `/verify`, `/invoke`; **`POST /api/plugins/call {id, service, method, payload}`**; `/api/plugins/assets/…` | audit:read / plugin:admin / per-method | — |
| System and version | `/api/system/{health,series}`, `/api/version`, `/api/health`, `/readyz`, `/metrics` | `*` for system; others public | — |

## 4. Plugin pages vs. core console

**Plugin pages.** These are sandboxed iframes from `/api/plugins/assets/<id>/<digest>/ui/`. They talk to the console over postMessage (`lattice.plugin.*` / `lattice.host.*`, see `views/platform/pluginBridgeModel.ts`) and the console forwards their calls to `/api/plugins/call`. Each plugin's methods and scopes are in its `manifest.json`:
- **latticenet.vpn-core**, in the VPN section: Lines, Users, Node Profiles, Usage. It covers lines, chains and rollouts; identity create/bind/rotate, subscription links and usage; profiles; and an outbound probe (needs `vpn:probe`).
- **latticenet.sub-store**, in the VPN section: Sub-Store. It covers subscriptions, rendering, import/export, shares, and fleet plans (`plans.propose` files an approval).
- **latticenet.netguard**, in Networking: Inbound firewall. It covers security groups, zones, bindings, adoption, plans and reality checks.
- **latticenet.wireguard**, in Networking: WireGuard mesh (overview and plan).

Most of these methods are implemented by the server itself, wrapping the REST handlers in §3 (`server_vpncore.go`, `server_network_plugins.go`). The sub-store `subscription` service is the exception: it runs in the plugin process.

**Third-party plugins** go in an Extensions area. Their pages are either sandboxed or one of three simple kinds (table, detail, form) that the console draws from the manifest (`PluginView.vue`). An iOS app could draw those three natively.

**Everything else in §1 is core console.** Three core features also call vpn-core or sub-store: Publishing's share list, the command palette's VPN identities, and identity links.

## 5. What changed after early September (from git history)

If your app's baseline is about September 8, roughly 40% of today's console arrived after it:

- **Late September:**
  - New Upcoming page (`/api/expiring`).
  - Evidence split into its three layers.
  - Approvals, Tasks, Audit, Publishing and Node detail got the layers listed above; Nodes became a grouped table with a side sheet.
  - Users, Tokens and SSO merged into Access.
  - New `/api/tasks/counts`.
- **October 2–5:**
  - The official plugin pages moved into the VPN and Networking sections.
  - Notifications gained channel health, the Sent log, per-channel tests and the witness.
  - Incidents and maintenance windows were added.
  - Latency probes and the Topology view were added.
  - Platform › System and node long-term history were added.
  - Evidence budgets (`/api/evidence/settings`) were added.
  - The step-up rule for every secret reveal took effect (2026-10-02).
  - VPN identity links and cutover were added.
- **October 8–18:**
  - The shared list search syntax.
  - DDNS CNAME support and the `vpn:probe` scope.
  - The notification catalogue.
  - Monitoring rebuilt: `/api/monitors/paths`, `/series`, `/settings`, `/update`, and the beacon endpoints.
  - Agent fetch readout and agent mirrors.
  - SSO providers that can stand in for the local second factor.
- **October 24–28:**
  - Check definitions.
  - Node effective network (`/api/nodes/network`).
  - Policy renamed to Outbound policy (`/network/outbound`), plus `/api/netpolicy/convert`.
  - Groups renamed to Node groups (`/node-groups`), plus `/api/groups/used-by`.
  - NetGuard node-group bindings.
  - DNS allowed clients and `/api/dns/measure-cert`.
  - Topology direction arrows.

The intent behind the surfaces is in `lattice/docs/PRODUCT-VISION.md` (§1 axioms: nothing changes a machine without a plan) and `lattice/docs/DESIGN-PROGRAM-2026-09.md` (§2–9 cover the vpn-core and Sub-Store pages, SSH Guard, Terminal, NetGuard, and the platform/plugin boundary).