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
