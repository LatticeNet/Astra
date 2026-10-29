# Astra v3 design brief

Astra (display name Lattice) is the iPhone client for the Lattice control plane. This brief is the shared contract for the v3 redesign: full feature parity with the web console, built the way a first-party iOS 26 app would be.

## Product

Lattice is a sovereign control plane for one operator's fleet of about 35 machines (cloud VPS, home servers, a Mac), spread over East Asia, the US and Europe. Doctrine (`lattice/docs/PRODUCT-VISION.md`): every privileged change is a reviewed plan whose approval hashes exactly what the operator was shown; nodes run an outbound-only agent with node-side vetoes; hands and agents are equal operators. The console inventory (`docs/design/console-inventory.md`) lists every page, action and endpoint.

The person: the operator, a Linux and security engineer, often away from a desk. On the phone they triage (is anything wrong, what needs me), decide (approve or reject plans with Face ID), investigate (why is this path degraded, what did this node do), and make targeted changes. Sessions are short and interruptible, sometimes long when investigating.

## Platform and code constraints

- SwiftUI, iOS 26.0 minimum, Swift 6 strict concurrency, Xcode 26.5. Primary device iPhone 17 Pro Max; must work on every iPhone size from iPhone SE (375 pt) up, portrait and landscape. iPad gets the adaptive tab/sidebar for free; no iPad-only work.
- Use the Observation framework (`@Observable`), `NavigationStack` with typed paths, the iOS 18+ `Tab` API, `.searchable`, sheets with detents, `ContentUnavailableView`, Swift Charts, MapKit for SwiftUI, `sensoryFeedback`.
- `Sources/AstraCore/` stays free of SwiftUI and is checked by `swift run --scratch-path .build AstraCoreCheck`. The app target compiles the same files.
- The repository is public. Demo data and fixtures use invented names, invented addresses (RFC 5737 / RFC 3849 documentation ranges), and no real tokens or hostnames.
- No third-party dependencies.

## Non-negotiable behavior

- The approval contract stays exactly as strict (see `README.md` and `AstraApp/App/ReviewSheet.swift`): review loads by id, hashes the plan body that is on screen, sends that `plan_sha256`; Face ID or passcode gates approve, reject and dismiss; cancelled authentication sends nothing; stale rows are inspect-only; an undecodable approval disables approve ("companion behind").
- Credentials: PAT in Keychain preferred, session plus TOTP fallback, passkey if feasible. Secrets that need step-up on the server (knock sequences, share URLs, scripts, console links) need a step-up grant; the phone may obtain one with TOTP. Never cache revealed secrets.
- Alerting belongs to the server's notify channels. The app may refresh its badge in the background; it does not claim to alert.
- Truthful state: never show a success-looking surface when a sub-request failed, data is stale, or a scope is missing. Every screen has loading, empty, error, offline/stale, permission-denied (missing scope) states.
- Every direct write states its object, scope and consequence before it runs. Irreversible writes (delete node, delete machine, revoke token) need an explicit confirmation naming the object.

## Design standard

- Apple HIG for iOS 26 first. Native components carry Liquid Glass on the navigation and control layer; content stays opaque and legible. No glass or blur cards in the content layer, no wall of identical cards, no decorative gradients, no emoji icons. SF Symbols, system text styles, Dynamic Type through the accessibility sizes, VoiceOver labels and rotor-friendly structure, Dark Mode, Increase Contrast, Reduce Motion, Reduce Transparency, 44 pt targets, color never the only signal.
- One signature element for the product, used with restraint.
- Interaction quality over visual novelty: reachable primary actions, swipe actions and context menus where they save steps, pull to refresh, search everywhere lists get long, state preserved across tab switches and relaunch, deep links to every object.
- Permissions are requested at the moment of need (notifications when the operator turns on badge refresh, not on first launch).

## Scope of writes on the phone

The operator asked for all features. The design decides, per console action, one of: native on the phone, native with step-up, or "Open on web" (a deep link to the exact console route with the same object open). Decide by frequency on the go, consequence, and how much input the form needs. Plan-filing actions ([A] in the inventory) are good phone candidates because the approval still gates them. Terminal is a candidate for a native, read-mostly or full client only if it can be done well.

## Verification

Each feature ships with: AstraCore decode and logic checks against fixture JSON shaped like the real server responses (read the Go handlers and views to get them right), demo fixtures so the simulator renders the feature with realistic data and no server, and simulator screenshots at default and accessibility text sizes, light and dark.
