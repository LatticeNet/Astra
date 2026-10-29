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
