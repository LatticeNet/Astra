#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT_DIR"

TEAM_ID="${ASTRA_TEAM_ID:-}"
BUNDLE_ID="${ASTRA_BUNDLE_ID:-org.roobli.astra}"
ARCHIVE_PATH="${ASTRA_ARCHIVE_PATH:-$ROOT_DIR/DerivedData/Astra.xcarchive}"
EXPORT_PATH="${ASTRA_EXPORT_PATH:-$ROOT_DIR/DerivedData/export}"
EXPORT_OPTIONS_PATH="${ASTRA_EXPORT_OPTIONS_PATH:-$ROOT_DIR/DerivedData/ExportOptions.Development.generated.plist}"

if [ -z "$TEAM_ID" ]; then
  echo "error: ASTRA_TEAM_ID is required for archive/export." >&2
  echo "example: ASTRA_TEAM_ID=ABCDE12345 ASTRA_BUNDLE_ID=com.yourname.astra ./scripts/archive-ios-development.sh" >&2
  exit 1
fi

./scripts/doctor-ios.sh >/dev/null
mkdir -p "$(dirname "$ARCHIVE_PATH")" "$EXPORT_PATH"
cp Config/ExportOptions.Development.plist "$EXPORT_OPTIONS_PATH"
if /usr/libexec/PlistBuddy -c "Print :teamID" "$EXPORT_OPTIONS_PATH" >/dev/null 2>&1; then
  /usr/libexec/PlistBuddy -c "Set :teamID $TEAM_ID" "$EXPORT_OPTIONS_PATH"
else
  /usr/libexec/PlistBuddy -c "Add :teamID string $TEAM_ID" "$EXPORT_OPTIONS_PATH"
fi

xcodebuild \
  -project Astra.xcodeproj \
  -scheme Astra \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  CODE_SIGN_STYLE=Automatic \
  -archivePath "$ARCHIVE_PATH" \
  archive

xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS_PATH" \
  DEVELOPMENT_TEAM="$TEAM_ID"

echo "Exported development build to $EXPORT_PATH"
