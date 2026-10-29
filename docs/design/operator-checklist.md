# Operator checklist

Agents cannot tap, swipe or rotate a simulator, and they cannot run VoiceOver, Voice Control, Button Shapes or Reduce Transparency. This list is what the operator checks on the iPhone (section 9.2, item 7). Each module appends its screens under its own heading. Mark a line with the date and build when it passes; write what failed when it does not.

## Every screen

- VoiceOver: the headings rotor jumps between sections; each swipe action is listed once in the actions rotor; focus stays where it is when a poll updates the list.
- Voice Control with "Show names": no icon button is unlabeled.
- Button Shapes: count buttons, toolbar buttons and the banner's Undo show their shapes.
- Reduce Transparency: bars and sheets stay legible; content never relied on glass.
- Reduce Motion: the banner fades instead of sliding; nothing pulses or loops.

## M0b foundation

- Welcome: "Connect to a server" reaches Server, Credential and the scope summary; Paste fills the token without a paste-permission alert; "Explore with demo data" lands on Inbox with the Demo button visible.
- Tab bar: tapping the selected tab pops to its root.
- Settings: opens from the button on every tab root; the close button dismisses it; every page opens.
- Device security: turning on "Require Face ID to open" asks for Face ID first; leaving the app and coming back after the chosen interval shows the lock above any open sheet; cancelling Face ID keeps it locked.
- App switcher: with Review, a RevealFlow or Settings open, the switcher card shows only the Lattice cover.
- Badge refresh: turning it on asks for badge permission once and never on first launch; turning it off stops scheduling.
- ConfirmSheet: Face ID shows before a privileged write; cancelling Face ID returns to the sheet and sends nothing; a write started inside Settings pushes its confirmation inside the sheet.
- Banner: appears above an open sheet; touching it or focusing it with VoiceOver keeps it up; Undo reverses the write.
- RevealFlow: the code field autofills from Passwords and submits at six digits; the value stays masked during screen recording; it clears after 60 seconds and when the app goes to the background.
- Deep links: a `lattice://` link from Notes or Safari opens the right tab and screen, and waits while a confirmation is open.

## M1 Inbox and approvals

- Inbox: the verdict line is the first thing VoiceOver reads and is a heading; the headings rotor jumps Incidents, Needs you, Attention, Due soon. Each incident row lists Acknowledge (or Unacknowledge) and Snooze once in the actions rotor. With VoiceOver on, a poll that adds or reorders rows shows "N updates. Show" at the top, announces it once, and focus does not move.
- Inbox: swiping Snooze opens one dialog naming the incident with 1 hour, 4 hours and until the next 08:00 (and End snooze when snoozed); the banner offers Undo, and Undo restores the earlier state.
- Inbox: the filter menu shows "Showing approvals only. Show all" while filtered; relaunching starts at All.
- Inbox: a grouped row ("Agent update to 0.3.10 on 3 nodes") opens BatchReview; a single row opens Review; there is no swipe to approve anywhere.
- Review: Face ID (Touch ID and the passcode on an SE, which show the reason "Approve ... plan 3f9a…c210") runs before every approve, reject and dismiss; cancelling sends nothing and plays no haptic.
- Review: the proof strip reads "Matches the plan below" with the filled green seal only after the plan loaded; the first and last eight characters of the hash match the console's digest by eye.
- Review: Approve lands with a success haptic and "Approved, apply in progress" or "Approved, waiting"; Reject and Dismiss land with a medium impact; "Not recorded: this plan was already approved by ..." plays an error haptic and is never green.
- Review: while a decision runs the sheet cannot be swiped away and Close is disabled; a deep link that arrives then opens afterwards.
- Review: Find in plan scrolls the sheet to each match; Wrap lines off lets the plan scroll sideways without the sheet scrolling sideways; Voice Control "Show names" labels Previous match, Next match and More.
- Review at AX5 on the iPhone SE: the toolbar is gone and the panel stacks the toggle, the primary button and Reject; every control is reachable by scrolling.
- BatchReview: one Face ID decides every included plan; rows another operator decided show "Not recorded"; the banner reads "N approved, M not recorded" with a warning haptic.
- Approvals (Activity): pulling down shows Search approvals with its Needs you, History and Stuck scopes; History loads more rows at the bottom and the range menu filters it.

## M2 Fleet

- Nodes: the headings rotor jumps between the status sections (Offline, Degraded, Never reported, Online, Disabled); each row's trailing swipe (Disable or Enable) is listed once in the actions rotor; a poll that moves a node between sections while VoiceOver runs shows "1 update. Show" instead of moving focus.
- Nodes: Select enters edit mode; picking rows enables "Disable n" and "Enable n" in the bottom bar; Disable opens one ConfirmSheet listing every node, Face ID, then per-node outcomes; Enable asks once in a dialog that names the count.
- Nodes: the Group menu (None, Status, Region, Provider, Group, Tag) regroups the list; a query such as `status:offline region:tokyo` or `sort:-cpu` filters, and a misspelt field (`stauts:offline`) shows a sentence under the header instead of an empty list.
- Nodes: long press a row shows the glance preview and Open, Copy link, Copy ID, Copy IP, Open terminal on web, Open on web and Disable; with a Triage token Disable stays in the menu, disabled, with "Needs node:admin".
- Node detail: the Overview, Activity and Settings control stays pinned under the bar while scrolling; at AX5 it becomes a menu; in landscape it moves into the navigation bar beside the More button and the node name stays as the title.
- Node detail Overview: swipe an open incident to Acknowledge (the label says "stops repeat alerts") and Snooze opens one dialog naming the incident; History chart scrubs only after a long press, and vertical scrolling and the edge swipe back still work over the chart.
- Node detail Settings: Edit identity opens the sheet at full height with the keyboard; Save asks in a dialog naming the node and the changed fields; a server refusal shows in the sheet and is announced.
- Node detail Settings: Agent debug toggles through a dialog and flips back when the dialog is cancelled; Rotate token runs Face ID, then shows the token once with Copy only (no Share), masked until Show, and it clears after 60 seconds or when the app goes to the background.
- Node delete: the ConfirmSheet lists the dry run grouped as Services, Configuration and History; for a DNS, geo, tunnel or line node the button stays off until the node name is typed; cancelling Face ID returns to the sheet and sends nothing; after a delete the node screen closes.
- Capabilities: swipe Exclude asks for a reason in an alert before the ConfirmSheet; Enroll goes straight to the ConfirmSheet; both run Face ID.
- Beacon: Plan beacon files an approval and opens it in Review; on a NetGuard node the sheet lists netguard:admin among the scopes.
- Groups: swipe Delete on a group that policies or checks still name shows the Used by list in the ConfirmSheet with the button off; on an unused group the delete runs after Face ID.
- Group detail: Add members opens a picker with multi-select; Add asks once naming the group and nodes; swipe Remove on a static member asks once.
- Map: each cluster is a button labelled like "Tokyo, 4 nodes, 1 offline"; tapping shows the member callout above the tab bar and its close button dismisses it; the tab bar stays reachable; with Latency on, degraded arcs are dashed and down arcs dotted, also in Grayscale, and the List view reads the problem paths.
- No location: Locate all asks once with the count; per-row Resolve is a swipe listed once in the actions rotor.
- Capability gate: Turn on runs a ConfirmSheet that lists the nodes it would refuse, then Face ID; with a token that has a node allowlist the button stays off with "Needs a token without a node allowlist".
- Voice Control "Show names": the Group menu, Select, Map options, Map or List (in landscape the single Show list or Show map button) and More buttons all have names.

## M3 Monitoring

- Overview: each health row opens its segment (Paths, Checks, Incidents) with the matching query; a recently degraded path pushes its detail.
- Paths: the view menu switches Problems, All and Chains and opens the Matrix; "Show unmeasured" brings back skipped pairs; Up stays collapsed in Problems until Show; a path row's context menu shows the glance preview and Open source node.
- Matrix: portrait and landscape keep the source column and target row pinned while the grid scrolls both ways; tapping a source name or a target name pushes Paths filtered to it; Fit to width fills the screen; with VoiceOver on, the grid is replaced by the per-source list and the "Problem paths" rotor jumps between sources with down or degraded paths.
- Path detail: long press then drag on the latency chart scrubs with a selection tick at each sample, while a plain vertical swipe still scrolls and the edge swipe still goes back; gaps in the line stay gaps; Audio Graphs is offered on both charts; Compare previous window draws the dashed previous line; Plan beacon replan files a plan and opens it in Review.
- Checks: Pause or Resume swipe asks once with the check named and monitor:admin stated; a generated check offers no swipe and its detail shows only the definition link; Delete on an operator check asks for Face ID; pausing a check another device just changed shows "changed since you opened it" and the current state.
- Definition: Delete lists every check that goes with the definition before Face ID and needs the definition name typed.
- Incidents: the search scopes switch Active, Acknowledged, Snoozed, Pending, Resolved and All; the Acknowledge swipe is listed once in the actions rotor; Snooze opens one dialog that names the incident; a poll that reorders the list while you scroll or while VoiceOver runs waits behind "n updates. Show" and focus stays put.
- Incident detail: the Acknowledge, Snooze and Start maintenance bar replaces the tab bar in portrait (the tab bar returns on back); in landscape Acknowledge and Snooze sit in the navigation bar and Start maintenance in its menu; a failed acknowledge stays on screen with Retry; pending and resolved incidents show no actions.
- Start maintenance: the node picker, name, presets and Until picker are reachable at AX5 with the keyboard up; Start asks once naming the node and the end time; the window appears under Incidents > Maintenance.
- Maintenance window: End now and Delete each ask once naming the window.

## M4 Activity: tasks and audit

- Tasks: the headings rotor jumps Running and waiting, then Finished and stopped; each row reads its id, state word, targets, the "9 ok, 1 failed" count, who queued it and the first failure line; a row filed by an approval offers "Plan seal" in the rotor's more content. A poll that reorders the list while VoiceOver runs waits behind "n updates. Show".
- Tasks: typing `status:failed origin:approval node:edge-tyo-1` filters, and a free word or an unknown status shows a sentence above the list saying it was left out; the range menu and "Show all" work; the Inbox "1 failed task" button lands here with `status:failed`.
- Tasks: long press a row shows the glance preview with Open, Copy link, Copy ID, Open on web, Cancel task (live runs) and Rerun; with a token without task:run those two stay in the menu, disabled, with "Needs task:run".
- Task run: while the run is live the count ("10 of 12 finished, 1 failed") updates every 3 s and nothing spins; failed, stalled and expired nodes come first; an expired node reads "Expired: the node never picked it up", never failed; a lease past the run's timeout reads "No heartbeat for ..." in the warning color.
- Task run, with an "Operator plus root" token: swipe "Rerun on this node" is listed once in the actions rotor and opens the ConfirmSheet naming the node, then Face ID (cancelling sends nothing); Cancel task asks once in a dialog naming the task and task:run; Rerun and "Rerun n failed nodes" open the ConfirmSheet, the second saying "Each node becomes a separate task run" and reporting per node; Delete task runs Face ID and closes the screen after the server confirms.
- Task run: Reveal script runs the code step, then shows the script masked until Show, Copy only, cleared after 60 seconds and when the app goes to the background.
- Task run: an approval-filed run shows the approval title and its plan seal with a Copy button; tapping the title opens Review.
- Output: Find opens the find bar and steps through matches; Jump to end scrolls to the last line and is announced; Copy and Share in the menu carry stdout then stderr; text is selectable and grows with Dynamic Type.
- Audit: pulling down shows the search field with the Changes, All and Integrity scopes; the range menu filters by time; the More menu exports CSV and NDJSON to the share sheet (Files names them lattice-audit.csv and lattice-audit.ndjson), and a capped scan's file and share title start with "Partial: scanned N events".
- Audit: the headings rotor jumps between day sections; long press a row shows Open, Copy link, Copy ID, Open on web and Open trace.
- Audit event: the time shows in both zones; an event that names an approval shows its seal with Copy; Node, Task and Trace push their screens.
- Trace: the timeline reads oldest first, each step one element with time, action, decision and actor; the rail is decorative and silent.
- Verify chain: opens from the More menu or Integrity's "Verify now", runs at once with no confirmation, announces "Chain intact" or "Chain broken", and the head hash copies on tap; Share audit head offers lattice-audit-head.json.
- Voice Control "Show names": Range, Export and verify, New task on web, Cancel task, More, Find and Jump to end all have names.

## M5 Inventory and upcoming

- Machines: the headings rotor jumps between the sections of the Group menu (Region, Country, Role, Group, Status, Tag, None), and each header reads its name, machine count and monthly spend ("Tokyo, 5 machines, USD 54.00 a month"), never "slash mo"; each row reads name, countdown, vendor and the monthly figure in one element.
- Machines: swipe Renew on a machine opens the Renew sheet and is listed once in the actions rotor; a free or one-time machine offers no swipe; with a Triage token there is no swipe and the context menu shows Record renewal disabled with "Needs inventory:admin".
- Machines: a query such as `vendor:fabrikam`, `renews_in<7d`, `is:autoroll` or `-is:profiled` filters, the subtitle reads "Filtered: ...", and a misspelt field (`vendr:x`) shows a sentence under the header instead of an empty list.
- Machines: while VoiceOver runs, a poll that moves a machine between Status sections shows "1 update. Show" instead of moving focus.
- Machine: the More menu holds Record renewal, Reveal console link, Copy link, Open on web, Edit on web and Delete machine profile; Delete runs the ConfirmSheet with what is removed, then Face ID, and the screen closes only after the server confirms.
- Machine: Reveal console link asks for the authenticator code (or Sign in for reveals first), shows the link masked until Show, opens it with Open in an in-app browser that keeps no history, and clears it after 60 seconds, on leaving the app, or when the sheet closes.
- Renew: opens at half height (full height at accessibility sizes) with the date one cycle on; Record asks in a dialog naming the machine and the date; picking the date already recorded keeps Record off with the reason; a past date warns and offers the first renewal after today.
- Reminders: lists today's reminders worked out on the phone; Send asks once naming the count, then lists each reminder the server says it sent; a second send the same day reports that nothing went out.
- Upcoming: the Filter menu narrows to Machines, VPN users, Shares or Certificates and a "Showing ... only. Show all" row appears; with a Triage token the note under the summary names the hidden kinds; swipe Renew on a machine row opens the Renew sheet.
- Voice Control "Show names": the Group menu, the More menus, the Filter menu and every Reveal and Record button have names.

## M6 Networking

- Outbound policy: the view picker reads Policies, Nodes and Matrix and becomes a menu at accessibility sizes and in landscape; the headings rotor jumps between Enabled and Disabled, and on Nodes between Apply failed, Planned, Applied, Disabled and No policy; each row reads its name, state and node count as one element.
- Outbound policy: Plan all outbound policies opens the plan ConfirmSheet with no Face ID, says every covered node is planned whichever policy it starts from, and lists the nodes as "Will try"; after File plan the result says how many plans were filed with the conflicts and orphaned nodes counted and never shows green; Done opens BatchReview.
- Matrix: the Egress and Ingress control is a segmented control at default sizes and a menu at accessibility sizes; each source row is a heading and a group row pushes the node group.
- Node policy (a manual node such as core-lon-1): the Convert section's name and priority fields are reachable above the keyboard at AX5; Convert opens a ConfirmSheet that says the policy is created first, then Face ID, then the filed plan opens in Review.
- DNS deployment (public resolver fra): Plan stops on the findings step with the lockout finding visible above an unchecked "Accept lockout risk" and File plan disabled; ticking it files the plan and the result restates the accepted finding.
- DNS deployment: Publish IPs shows the preview under "Computed on this iPhone from the node's reported address" before the button enables, then asks for Face ID; doh iad offers Measure certificate as a dialog that names host and port and both scopes, and a confined token sees it disabled with "Needs a token without a node allowlist".
- DDNS: the trailing swipe offers Run now once in the actions rotor with an Operator token and not at all with a Triage token; Run now shows the records it writes, old and new, labelled as computed on this iPhone; Delete profile asks for the typed profile name and Face ID.
- Geo routing: Preview config renders the config in a horizontally scrolling monospaced block that VoiceOver reads as one value; Delete on an applied routing names each DNS node that keeps answering and asks for the typed name.
- Tunnel: the Last plan row opens the newest cftunnel approval in Review; Delete tunnel says cloudflared keeps running and asks for the typed name.
- Inbound firewall: with a confined token the Security groups, Zones and Node-group bindings sections each say why they are hidden instead of reading empty; a node row pushes that node's firewall, and its security groups push the group's rules and bound nodes.

## M7 SSH Guard and agent updates

- SSH Guard board: the headings rotor jumps between Confirm needed, Password login open, Partial, Unknown, Secured and Excluded; a reverting row reads its node, posture, "confirm by" time and knock state as one element, and the "Reverts in" countdown never pulses.
- SSH Guard board: with an Operator token the trailing swipe offers Arm on an open or failed node that holds an explicit sshguard enrolment (an undecided node offers nothing, as on the console) and Confirm on a reverting one, each listed once in the actions rotor; with a Triage token the board shows "Needs sshguard:read and network:plan" instead of an empty list, and with sshguard:read but no sshguard:admin the swipes are gone and the context menu shows Arm or Confirm disabled with "Needs sshguard:admin".
- SSH Guard board: Confirm on edge-tyo-2 (a confirm plan already waiting) opens that approval in Review and files nothing; Confirm on a node with no confirm filed opens the plan ConfirmSheet with no Face ID, and after File plan the new approval opens in Review.
- SSH Guard board: the Filter menu's Posture and Coverage choices show as search tokens and in the subtitle; removing a token clears that filter; leaving and reopening the board starts at All; a query such as `posture:password state:failed` or `is:reverting` filters, and a misspelt field shows a sentence instead of an empty list.
- SSH Guard board: a poll that moves a node between sections while you scroll, or while VoiceOver runs, waits behind "1 update. Show" and focus stays put.
- SSH Guard node: on a reverting node the countdown and Confirm (or Open confirm approval) are the first thing on screen at AX5; the history rows open their approvals in Review; More has Open on web, Copy link, Copy ID and Node details.
- SSH Guard node: Reveal knock sequence without a signed-in session offers "Sign in for reveals"; with one it asks for the authenticator code, shows the knock command once with Copy only, masked until Show, and clears it after 60 seconds or when the app goes to the background; a second reveal within the minute skips the code.
- SSH Guard node: Exclude from SSH Guard runs a ConfirmSheet naming the node, then Face ID; cancelling Face ID sends nothing; afterwards Arm reads "Not enrolled for SSH Guard".
- Arm sheet: opens at full height; the port field brings up the number pad and stays above the keyboard at AX5; with knocking on, no source and no fallback, Continue stays off with the problem listed in the form; Continue pushes the plan's confirm page inside the sheet (no second sheet); on edge-hkg-2 the server's findings appear with "Accept findings" unchecked, and File plan stays off until it is ticked.
- Rotate knock: on a node with an installed sequence, "Reveal the current sequence" runs the code step inside the sheet, then shows "Current sequence identified" with its short digest; Continue files the rotation and opens it in Review; on a node whose control plane knows no sequence, the sheet asks for the three ports the node knocks on now and rejects a malformed list.
- Agent Updates: the Nodes, Distribution and Mirrors control stays pinned under the bar, becomes a menu at AX5, and moves into the navigation bar in landscape; opened from a node's agent row it shows only that node, with "Show all".
- Agent Updates: swipe Plan update on a behind node with a policy files the plan and opens Review; Plan all behind (5) lists every node it will try, files them one after another, shows "4 plans filed, 1 refused" with lab-pi-2's reason, then Done opens the filed plans in BatchReview.
- Agent Updates: with a Triage token the screen reads "Hidden: this token lacks node:admin"; when the release host cannot be read the Nodes view says so in words and every standing reads unknown instead of current.
- Release: each artifact row copies its digest from the whole row; Release notes opens the release page in the browser.
- Voice Control "Show names": the Filter, More, Plan all behind and picker controls all have names.

## M8 Platform

- Plugins: the headings rotor jumps between Failed, Waiting to activate, Running (or Active without plugin:admin), and Disabled; each row reads its name, health word, version, publisher and risk as one element. With an Operator token the footer says runtime health needs plugin:admin and no plugin reads "running"; the context menu shows Activate or Disable disabled with "Needs plugin:admin".
- Plugin detail: Disable (or Activate) runs a ConfirmSheet naming the plugin and what stops, then Face ID; cancelling Face ID sends nothing; afterwards the Health section shows the new runtime state. Pages list table and detail pages as rows that open here and every other kind as an "Open on web" row with its console path.
- Extensions: pages are grouped by plugin with the plugin as a heading; the Certificates page reads each row as one element, the alert hook is masked and never spoken in full, and "Recheck now" opens the console page instead of running.
- Extension page: on DNS probe Resolvers the failed runtime shows "Could not load Resolvers" with Retry, never an empty table.
- Publishing: the Overview, Routes, Tokens and Buckets control stays pinned under the bar, becomes a menu at AX5 and moves into the navigation bar in landscape; the Filter menu's origin shows as a search token and in the subtitle, and removing the token shows all origins again.
- Publishing routes: swiping a KV or static route offers Delete only with kv:admin or static:admin, listed once in the actions rotor; Delete runs a ConfirmSheet whose red button names the route, then Face ID, and the row leaves only after the server confirms. Without proxy:admin the Shares section reads "Hidden: this token lacks proxy:admin".
- Publishing tokens: with kv:admin, swiping an active token offers Revoke (never on a revoked one); without it each kind reads "Hidden: this token lacks kv:admin" (or static:admin).
- Share detail: Reveal share URL without a signed-in session offers "Sign in for reveals"; with one it asks for the authenticator code, shows the URL masked until Show, offers Copy and Share, and clears it after 60 seconds or when the app goes to the background. Rotate asks for Face ID; Refresh is a dialog naming the share; Delete closes the screen only after the server confirms. A proxy user's share says refresh is not needed.
- Store: the reserved vpn_users bucket cannot be opened; opening an entry shows Load value, the value appears only after the tap, Find in value opens the system find bar, and leaving the screen or backgrounding the app clears it.
- System: with a token that lacks * the screen reads "Hidden: this token lacks * (a full administrator)" and offers no range menu; with a full administrator the Range menu reloads the charts, each chart has a text summary above it, Audio Graphs are available from the rotor, and lines break where nothing was recorded.
- Voice Control "Show names": the Filter, More, Range and picker controls all have names.

## M9 Notifications and webhooks

- Notifications: the Routing and Sent control stays pinned under the bar, becomes a menu at AX5, and moves into the navigation bar in landscape; the headings rotor jumps between Needs attention, the channels, the rules and Control-plane witness.
- Notifications: a failing channel reads its name, "failing" and the cause in one element; swipe Send test on a channel is listed once in the actions rotor, and the rotor also offers Copy link and Delete channel; with a Triage token the screen reads "Hidden: this token lacks notify:admin", and with a confined token "Hidden from a confined token" with Token scopes.
- Send test: the dialog names the channel and says a notification goes to whoever it reaches; on Ops mail (failing) the banner says the test did not deliver and names the cause, with the error haptic, never green.
- Witness: a row reads the node, its state word, its facts and the sentence (watching, not answering, sees it down); tapping it opens the plan in Review when one is pending or failed, else the settings sheet, whose Remove the witness files the removal; a Needs attention witness row shows its whole sentence at the default size and taps through the same way; its rotor offers Review plan, Change settings and Remove the witness; Change settings on probe-sin-3 shows its edge watch URL as kept, and on probe-ams-3 says its timing was set on the web and keeps Continue off; Plan witness opens the sheet at full height, the URL field brings up the URL keyboard and stays above it at AX5, Continue stays off until the URL is a loopback address, and Continue pushes the plan confirmation inside the sheet (no second sheet); File plan opens the filed plan in Review.
- Sent (Activity and Notifications): the Filter menu's Outcome, Channel and Event type show as search tokens and in the subtitle; removing a token clears that filter; a link with `outcome:failed` opens with the filter set; a misspelt field (`chanel:x`) shows a sentence instead of an empty list; the day headings are rotor headings; each row reads its severity, title and state word first, then the channel (and "as fallback"), the event and the repeat count.
- Sent: while VoiceOver runs, a poll that inserts deliveries shows "1 update. Show" at the top and focus stays put; choosing another filter replaces the rows at once, with no "Show" step and no rows left from the earlier filter.
- Sent: switching Routing and Sent, or leaving Activity's Sent and coming back, shows the log at once, also offline, never "No deliveries match" while the footer counts stored deliveries.
- Delivery: the message title reads in full as a heading at AX5; each attempt is one element with its result, time and cause; an incident row opens IncidentDetail; the More menu has Copy link, Copy ID and Open on web.
- Channel: Send test and Delete channel are in the More menu and in the list; Delete on a channel that is the only one of an enabled rule, or the fallback of one (Ops mail for Incidents to the phone), names that rule and asks for the typed name, then Face ID; cancelling Face ID sends nothing; "Test send on web (needs notify:send)" opens the browser and the phone never offers that send itself.
- Rule: matches, channels, quiet hours and escalation read as label and value; Edit and Delete open the web.
- Webhooks: "UPS on battery" reads "reaches nobody" with the reason; swipe Send test is listed once; Delete webhook asks for the typed name, then Face ID, and the screen closes only after the server confirms.
- Voice Control "Show names": More, Filter, Send test, Plan witness, Continue and every web row have names.

## M10 Evidence

- Evidence: the first row reads "1 of 35 nodes recording, 4 more ready. 3 asked to record are not." as a heading (a confined token reads "visible nodes"); the headings rotor jumps between Captures, the nodes asked to record that are not, Nodes, Explore, Local budgets and Collection; each node row reads its name, its readiness word (recording, ready, not ready, not heard from, waiting for the agent, cannot tell, off) and its trace and raw log facts in one element, and a not-ready row adds its reason in full (edge-hkg-2 "No Clash API: no loopback Clash API address in the policy or the sing-box config.").
- Evidence capture: the swipe on edge-fra-3 offers 5, 15 and 60 min, each listed once in the actions rotor as "Capture 15 min" and so on, and the context menu offers the same under Start capture; the one T2 dialog "Capture 15 min on edge-fra-3?" says it records connection metadata for users on edge-fra-3 for 15 minutes and names log:admin; after it lands the capture row appears with a countdown that VoiceOver reads as time remaining. With a Triage token the swipe is absent, the Captures footer says starting one needs log:admin, and the context menu shows Start capture disabled with "Needs log:admin"; a node that already has eight captures says so.
- Evidence stop: swipe Stop on a running capture is listed once, the dialog names the capture and its node, and the row moves under "ended captures" only after the server confirms; Reduce Motion keeps the countdown a plain number with no animation.
- Evidence: "{n} more nodes collect nothing. Show them" reveals the idle nodes and its label flips to "Hide the idle nodes"; the More menu offers Connections, Raw logs and Open on web; the Collection web row opens the console on its Collection layer.
- Connections: the Filter menu's Node, User, Destination, Line, Capture and Open connections show as search tokens and in the subtitle; removing a token clears that filter; typing `node:edge-tyo-1 dst:example.org` and pressing Search turns both into tokens and leaves free words in the field; the Range menu changes the window and the header sentence ("31 connections in the last hour").
- Connections rows: each row reads source to destination (with "to", never an arrow), how it ended, the node, protocol, bytes ("bytes not sampled" when unmeasured, never 0) and the start time; at AX5 the destination leads and the source opens the detail line, nothing clipped; the context menu offers Open, Copy link, Copy ID, Open on web, Only this node, Only this destination and Raw logs.
- Connections: while VoiceOver runs, or within 2 s of a touch or scroll, a poll that adds records shows "1 update. Show" at the top and focus stays put (without VoiceOver the rows apply once the list is still); the User filter lists managed users only; "Load more" appends the next page with no duplicates.
- Connection: a link `lattice://evidence/connections/<node:generation:log:started_at>` opens it; the Hops section says "exact" with the sentence that the identity was carried, lists both hops and the other hop opens its own detail; an ambiguous path lists the candidates; Identity links open the node, the VPN user and the line; the markers section lists the restart or applied change nearby; More has Open on web, Copy link and Copy ID.
- Raw logs: the Source menu lists every source by name and node; the lines read newest last and the list opens at the bottom; "Load older" adds the previous page above with no line twice and ends at "Start of what this source holds"; Search on the server filters by substring; Find opens a bar under the navigation bar, its field takes focus, the count reads "2 of 17" and is announced on each step, Previous and Next are 44 pt and named; each line reads time and text as one element and its rotor offers Copy line; lines older than 20 hours carry their date; scrolled up while a capture writes lines, the list keeps its place and "12 new lines below" at the bottom jumps to the end; a raw log search result opens the source it names.
- Offline: with the network off before the first load, each Evidence screen says "Offline" instead of placeholders; with data loaded, the footer reads "Offline. Showing data from ...".
- Voice Control "Show names": More, Filter, Range, Find, Previous match, Next match, Load older, Load more and every web row have names.

## M11 Account and access

- Security & 2FA with an API token alone reads "Needs a signed-in session" and offers Sign in for reveals; after signing in it shows the authenticator state as symbol and word, the server policy, and the passkeys, most recently used first. Offline, both sections read "Not read: this iPhone is offline", never placeholders that do not end.
- Passkey: Rename asks in a dialog that names the old and the new name; Delete with two-factor on pushes "Confirm with your code" inside the Settings sheet (no second sheet), the code fills from Passwords and submits at six digits, a code already used this half minute reads "Wait for the next code" with a countdown, then the confirmation page names the passkey, then Face ID; cancelling Face ID sends nothing and leaves the code step with "Continue"; after the server confirms, Security shows without that passkey. Letting the grant run out before confirming gives "Not deleted: the server asked for a fresh authenticator code".
- Access: the Users, Tokens and SSO control stays pinned under the bar, becomes a menu at AX5 and moves into the navigation bar in landscape; each layer the token cannot read reads "Hidden: this token lacks user:admin" (or token:admin, oidc:admin) with Token scopes, and Settings never hides the Access row.
- Tokens: the token this iPhone uses is listed first and says "This iPhone"; swiping an active token offers Revoke once in the actions rotor, never on a revoked one; the context menu adds Delete, disabled on an active token with "Revoke it first"; `is:revoked`, `scope:"task:run"` and a misspelt field (`stauts:x`, which shows a sentence instead of an empty list) behave in the search field.
- Token detail: on the phone's own token the first row reads "This iPhone uses this token"; Revoke opens the confirmation page inside the Settings sheet saying "This is the token this iPhone uses. You will be signed out.", asks for the token's name to be typed, then Face ID; after the server confirms, the banner says "Signing out" and the welcome screen appears. Each scope reads its id, "sensitive" where it is, and what it grants as one element.
- User and SSO provider: every field reads as label and value; Edit, Delete and Test open the web; a provider that skips the authenticator code or has no secret says so in words with the warning glyph.
- Voice Control "Show names": More, Submit, Continue, Revoke, Delete, the picker and every web row have names.
