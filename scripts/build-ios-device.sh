#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT_DIR"

project_bundle_id() {
  awk -F' = ' '
    /PRODUCT_BUNDLE_IDENTIFIER = / {
      value = $2
      sub(/;$/, "", value)
      if (bundle_id == "") {
        bundle_id = value
      } else if (value != bundle_id) {
        mismatch = 1
      }
    }
    END {
      if (mismatch || bundle_id == "") {
        exit 1
      }
      print bundle_id
    }
  ' Astra.xcodeproj/project.pbxproj
}

PROJECT_BUNDLE_ID="$(project_bundle_id)" || {
  echo "error: unable to read a single bundle identifier from Astra.xcodeproj." >&2
  exit 1
}

TEAM_ID="${ASTRA_TEAM_ID:-}"
BUNDLE_ID="${ASTRA_BUNDLE_ID:-$PROJECT_BUNDLE_ID}"
DESTINATION="${ASTRA_DESTINATION:-generic/platform=iOS}"

if [ -z "$TEAM_ID" ]; then
  echo "error: ASTRA_TEAM_ID is required for signed device builds." >&2
  echo "example: ASTRA_TEAM_ID=ABCDE12345 ./scripts/build-ios-device.sh" >&2
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
