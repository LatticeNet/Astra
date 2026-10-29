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
