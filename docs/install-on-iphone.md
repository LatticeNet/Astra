# Install Lattice on iPhone

Quick path. Full signing, archive, and export: [ios-build-deploy.md](ios-build-deploy.md).

## Prerequisites

- Full Xcode on macOS (`/Applications/Xcode.app`).
- An Apple ID signed into Xcode.
- iPhone on iOS 16 or later, trusted, visible as an Xcode run destination.

If Command Line Tools are selected instead of full Xcode:

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

Or prefix project commands:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/doctor-ios.sh
```

Accept the Xcode license if needed: `sudo xcodebuild -license`.

## Environment check

From the Astra repo root:

```sh
./scripts/doctor-ios.sh
```

## Xcode device install

1. Open `Astra.xcodeproj`.
2. Select the `Astra` target, Signing & Capabilities, your Apple Team.
3. If the bundle identifier is taken, pick a stable one and keep it.
4. Choose the iPhone as run destination and Run.
5. Trust the developer on the phone if prompted.
6. The home-screen name is `Lattice`.

## First configuration

Open **More → Settings**.

1. Enter the Lattice server URL (`https://lattice.example.com`, a LAN HTTP URL, or a pasted `/api/nodes` URL; the app normalizes it).
2. Authenticate with a PAT that has `network:apply`, `node:read`, `audit:read`, and `task:read`, or log in with username, password, and TOTP.
3. Test the connection, then Save and refresh.
4. Open Inbox. Do not configure Bark in this app. Always-on alerting is the Lattice server notify channel.

## Command-line device build

```sh
ASTRA_TEAM_ID=ABCDE12345 \
./scripts/build-ios-device.sh
```

Development IPA:

```sh
ASTRA_TEAM_ID=ABCDE12345 \
./scripts/archive-ios-development.sh
```

`ASTRA_BUNDLE_ID` is optional and overrides the project identifier only when you pass it.

Outputs: archive `DerivedData/Astra.xcarchive`, export `DerivedData/export/`. This is development signing, not TestFlight.

## Background refresh

Task id: `org.roobli.astra.refresh` (`BGAppRefreshTask`). The system decides if it runs. When it does, it only refreshes the Inbox badge. Do not treat it as always-on alerting.
