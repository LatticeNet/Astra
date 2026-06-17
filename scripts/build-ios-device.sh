#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT_DIR"

TEAM_ID="${ASTRA_TEAM_ID:-}"
BUNDLE_ID="${ASTRA_BUNDLE_ID:-org.roobli.astra}"
DESTINATION="${ASTRA_DESTINATION:-generic/platform=iOS}"

if [ -z "$TEAM_ID" ]; then
  echo "error: ASTRA_TEAM_ID is required for signed device builds." >&2
  echo "example: ASTRA_TEAM_ID=ABCDE12345 ASTRA_BUNDLE_ID=com.yourname.astra ./scripts/build-ios-device.sh" >&2
  exit 1
fi

./scripts/doctor-ios.sh >/dev/null

xcodebuild \
  -project Astra.xcodeproj \
  -scheme Astra \
  -configuration Debug \
  -destination "$DESTINATION" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  CODE_SIGN_STYLE=Automatic \
  build
