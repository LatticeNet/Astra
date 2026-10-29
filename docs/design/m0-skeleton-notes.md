# M0 skeleton notes

Written at the end of the M0 skeleton step (commit `5e3a3e8`, 2026-10-28) for the M0a and M0b lanes. The design specification (`astra-v3-design.md`) stays the source of truth; this file records what the skeleton already provides, what is still a placeholder, and where the skeleton had to choose between readings of the spec.

The public signatures listed here are the frozen API of wave 0: M0a fills in bodies and may add members, but does not rename or re-type what exists. A body that is still a placeholder carries the comment `// M0a: implement` (Shared, Demo, checks) or `// M<n>: implement` (module-owned domain files). `grep -rn "implement" Sources Checks` lists every one.

## State at the end of M0 skeleton

`swift run --scratch-path .build AstraCoreCheck` passes and `scripts/sim.sh build` succeeds. The old v2 views still compile and launch; they were changed only where a removed API forced it (`AppSettings`, `DashboardModel`, `NetworkView`, `OverviewView`, `SettingsView`). M0b deletes them. The remaining build warnings are all in those v2 files and predate this step; AstraCore compiles without warnings.

The six v2 core files are gone. Their code lives in `Sources/AstraCore/Shared/` and `Sources/AstraCore/Domains/<Domain>/` as section 8.2 assigns it. `MonitorEngine`, `BarkClient`, `BarkDeviceKeyNormalizer`, `NFTInputs` and `listNFTInputs` are deleted with their checks.

## Placeholders M0a fills in

Shared:

- `ScopeCatalogue.entries` is empty. Port every entry of `lattice-dashboard/src/lib/scopes.ts`.
- `ParityMatrix.rows` is empty. Add one `ParityMatrixRow` per row of section 3.2 (and the scoped reads of 3.1); `TokenPresets.uncoveredScopes()` then backs the coverage check.
- `LatticeQuery.parse(_:)` returns the whole input as one bare text node, `LatticeQuery.withoutSorts(_:)` returns its input, and `LatticeQueryEngine.compile(_:provider:)` matches bare text only; `apply(_:to:now:)` does not sort. Port `syntax.ts`, `engine.ts` and `values.ts` and run `query-vectors.json`.
- `VerdictBuilder.verdict(for:now:mode:locale:)` always answers "Checking the fleet." with no segments. Implement rules 1 to 5 of section 4.8 and the golden cases.
- `LatticeTask.runState(now:)` only maps the server status word. Port `lib/taskLease.ts` (pending, stalled, expired).
- `DDNSProfile.health(now:)` reads only `last_error`. Port the console's freshness rule for `stale`.
- `PathsResponse` does not decode `beacon_replans` yet.
- `fetchAudit(query:)` does not keep each event's raw JSON slice yet (needed by the NDJSON export).
- `DemoTransport.answer(_:)` applies only Offline, Failing and Empty. Quiet, Stale, Limited token, No session, Forbidden and Companion behind are still to do (`DemoState.recordHit(_:)` exists for Stale and Forbidden).
- `DemoWorld.nodes` and `SharedFixtures.routes` are empty.
- `checkContrast()` is empty; `checkDemo()` checks route uniqueness, time tokens, scenario parsing and the 404 for an unmatched route, but not the `emptyBody`, literal timestamp or approval hash rules.

Implemented in full and covered by a first check each (extend the checks, do not rewrite the code): `ScopeSet` with `ScopeRequirement`, `ApprovalVisibility`, `TokenPresets` presets, `WriteFlow` (cancel sends nothing), error envelope mapping, `PlanSeal`, `encodePathKey` and `decodePathKey`, `PathReason` sentences and aliases, `PathDisplayState`, `IncidentFilter` and `IncidentActions`, `BadgeCount`, `SSHGuardBoard`, `LatticeDeepLink` parse and build, `LatticeConsolePath` builders, `DemoClock` time tokens, `DemoRoute` matching.

Module-owned domain placeholders (each module implements its own): `ApprovalEvents.group(_:)` and `DecisionFlow` (M1), `MapClusters` (M2), `AuditExport` (M4), `ReminderSchedule` (M5), `SSHGuardRotation` (M7), `ExtensionPageModel` (M8), `TranscriptCleaner` (M12), and the empty model and API files of AgentUpdates, Platform, SSHGuard, Terminal and VPN.

## Public surface M0b builds on

- Writes: `WriteIntent`, `RevealIntent`, `WriteTier`, `ClientKind`, `ObjectRef`, `ConfirmToggle`, `ConfirmChoices`, `DetailLine`, `DryRunReport`, `ChangeKind` (all 32 cases of 8.4) in `WriteIntent.swift`; `WriteOutcome`, `RefusalCode`, `ObjectFailure`, `RevealedSecret` in `WriteOutcome.swift`.
- `WriteFlow(intent:client:authenticator:)` with `dryRun()` and `commit(choices:reviewed:) -> WriteFlowResult` (`.cancelled`, `.authenticationFailed`, `.dryRunChanged(DryRunReport)`, `.finished(WriteOutcome)`). `ActionRunner` drives the ConfirmSheet steps around it.
- Authentication: `DeviceAuthOutcome` (`.confirmed`, `.cancelled`, `.failed(String)`). `WriteAuthenticator` and `DecisionAuthenticator` both require `func authenticate(reason: String) async -> DeviceAuthOutcome`, so one `IntentAuth` method satisfies both. Today `IntentAuth` is an enum with a static `confirm`; M0b gives it an instance that conforms.
- Step-up: `StepUpGrant` (`isUsable(now:margin:)`), `StepUpPurpose`, `TOTPStep`, and `LatticeClient.stepUp(code:)`. The caller maps a 401 from it to a wrong code.
- Session: `LatticeClient.login`, `loginTOTP`, `logout`; `LatticeLoginSession.expiresAt` from the cookie's `Expires` or `Max-Age` (`LatticeSessionCookie`); `LatticeIdentity.serverAllowlist` and `.scopeSet`.
- State: `ResourceState` (with `value`, `loadedAt`, `reloading`, `failing(_:surface:)`), `Freshness.of(_:now:interval:)`.
- Display: the enums of `DisplayStates.swift` (`NodeHonesty`, `PathDisplayState` with `PathReason`, `IncidentDisplayState`, `TaskRunState`, `ApprovalDisplayState`, `SSHGuardCoverage`, plus `SSHGuardPostureState`), `PlanSealState`, `TimeZoneMode` and `TimeDisplay`.
- Inbox: `InboxSnapshot`, `InboxSection`, `SectionCoverage`, `VerdictProblem`, `VerdictSegment` (with a `Target` the app maps to a route), `Verdict`, `BadgeCount.compute(approvals:incidents:now:)`.
- Navigation: `NodeDetailTab`, `FleetScope`, `MonitorSegment`, `ActivityScope`, `ApprovalsScope`, `LatticeDeepLink`, `LatticeConsolePath`.
- Demo: `DemoTransport(identity:scenario:clock:state:routes:)`, `DemoIdentity`, `DemoScenario(argument:)` and `.argument`, `.title`, `.allCases`; `DemoClock(pinned:)`; `DemoState`; `DemoWorld.baseURL` and `.token`.

## Spec readings the skeleton chose

1. **Ported v2 names stay unprefixed.** Types moved into `Domains/` keep their v2 names (`LatticeToken`, `CreatedTokenResponse`, `MachineProfile`, `MachineProfileRequest`, `RenewalCycle`, `RenewalReminderFire`, `InventorySummary`, `Monitor`, `MonitorType`, `MonitorResult`, `MonitorStats`, `NotifyChannel`, `NotifyRule`, `LogSource`, `LogLine`, `LogQueryResponse`, `LogSourceStats`, `NetEndpoint`, `NetRule`, `NetPolicy`, `NetGraph`, `NetGraphNode`, `NetGraphEdge`, `NetGraphExternal`, `TunnelProfile`, `TunnelIngress`, `NodeCapabilityEffective`, `NodeCapabilitiesResponse`, `NodeTokenResponse`, `NodeGeoResolveResult`, `MetricSample`, `MetricsHistory`, `AuditChainStatus`). Section 8.4 freezes ported names and the split had to be mechanical, so `scripts/check-names.sh` must allowlist exactly these. New domain types follow the rule (`FleetThresholds`, `ApprovalEvents.Event`).
2. **`LatticeAPIError`** has the seven cases of 8.3 plus three client cases the login flow needs: `invalidURL(String)`, `missingSessionCookie`, `totpRequired(challengeID:)`. `serverError` and `httpStatus` are gone. A 409 written as `{"error": "<text>", "findings": [...]}` maps to `.conflict(code: "conflict", findings:)` with each finding's `message`; the envelope's text is not kept because the 8.3 case has no message. `.forbidden(scope:)` reads an optional `scope` key, which the server does not send today, so it is nil in practice. `LatticeAPIError(_ error:)` maps any thrown error (URLError to `.transport`, DecodingError to `.invalidResponse`), and `LatticeClient.send` maps transport errors for every request.
3. **`RefusalCode.notSent(String)`** is added beyond the list in 6.7. A write that failed before the request left the phone (no connection, host not found, TLS refused) must not read as `.unknown`, and none of the listed codes fits. Timeouts and lost connections still become `.unknown` with the intent's `verify` sentence.
4. **SSH Guard derivations** live in the `SSHGuardBoard` namespace (`boardStage`, `coverageBucket`, `coverage(for:scope:now:)`, `revertingNodes`, `revertDeadline`, `revertWindowPassed`). The server now sends `stage` and `revert_deadline`, so the deadline comes from the server rather than from plan text as the console's `sshGuardModel.ts` does. The server stages `hardened` and `in_force` count as confirmed. `SSHGuardScopeState` stands for the console's `ScopeState`.
5. **Deep links.** `.node(id:view:)` gained the view; `.monitor(id:)` stays for `lattice://monitors/{id}` and `.check(id:)` is new; the scope and segment links are `.fleet(scope:query:)`, `.monitoring(segment:view:query:)` and `.activity(scope:view:query:)`. HTTPS parsing is `init?(url:console:)` and needs the console origin; the old check that parsed a foreign HTTPS host was updated. Path segments keep RFC 3986 `pchar` characters unescaped, so `pending:`, `~`, `@` and `_` stay readable while `/`, `?`, `#` and spaces are escaped; the round-trip goldens should use the form `customURL` builds.
6. **`LatticeConsolePath`** is now a value (`path`, `query`, `url(console:)`) with one builder per row of 2.5, so `WebLinkRow(path:)` and `Router.openOnWeb(_:)` can take it. The three static `URL` helpers `approvals(_:dashboard:)`, `nodes(_:dashboard:)` and `monitors(_:dashboard:)` remain only for the v2 `DashboardModel`; delete them when M0b deletes that file.
7. **`StepUpPurpose`** is a client-side enum that names the secret in the copy; the server's step-up takes only `{code}`.
8. **`canDismiss`** is not in Shared. Section 6.1 makes it part of M1's decision logic, and its fallback reading ("isStale, or plugin sshguard or agentupdate") is M1's to pin with a check.
9. **Incident states** are the `IncidentServerState` enum, so a Shared call cannot send `active`, `snoozed` or `all`. `listIncidents(states:nodeID:limit:)` with no states asks for all four.
10. **Dual-shape lists** decode through `LatticeListDecoder.decode(_:from:key:)`. `listTasks(query:)` always asks for the envelope (it adds `limit=200` when no filter is set); the v2 `listTasks()` keeps the bare form.
11. **`ExpiringItem.id`** is `"<kind>:<id>"` because server ids are unique only within a kind; the server id is `objectID`.
12. **`FleetSummary`** takes `FleetThresholds` in place of the deleted `MonitorConfiguration`.
13. **Checks.** `RecordingTransport` is now `MockTransport` in `CheckSupport.swift`, next to `fixture(_:)` and `LatticeErrorProbe`. Section 8.7 names AuditChecks and TasksChecks as homes for moved checks, but the moved audit and task assertions test Shared code (`fetchAudit`), so they sit in SharedChecks; the monitor, notify and log assertions went to MonitoringChecks, NotifyChecks and EvidenceChecks with the code they test.
14. **`TokenPresets.operator`** is spelled with backticks because `operator` is a keyword; call sites write `TokenPresets.operator`.
15. **`scripts/sim.sh shot`** does not yet create the parent directory of a `<module>/<name>` shot (M0a work item 5).
