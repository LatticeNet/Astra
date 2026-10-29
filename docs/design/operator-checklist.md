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
- Inbox: swiping Snooze opens one dialog naming the incident with 1 hour, 4 hours and until 08:00 tomorrow (and End snooze when snoozed); the banner offers Undo, and Undo restores the earlier state.
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
