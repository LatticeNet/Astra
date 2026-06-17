#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT_DIR"

echo "Astra iOS doctor"
echo "root: $ROOT_DIR"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "error: xcodebuild not found. Install full Xcode." >&2
  exit 1
fi

DEVELOPER_DIR="$(xcode-select -p 2>/dev/null || true)"
echo "developer dir: ${DEVELOPER_DIR:-unknown}"
case "$DEVELOPER_DIR" in
  *"/Xcode.app/Contents/Developer") ;;
  *)
    echo "error: xcode-select is not pointing at full Xcode." >&2
    echo "fix: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
    exit 1
    ;;
esac

xcodebuild -version
if ! LICENSE_OUTPUT="$(xcodebuild -license check 2>&1)"; then
  printf "%s\n" "$LICENSE_OUTPUT" >&2
  echo "error: Xcode license has not been accepted." >&2
  echo "fix: run 'sudo xcodebuild -license' in Terminal, review the license, and agree if acceptable." >&2
  exit 1
fi

xcodebuild -showsdks | grep -q "iphoneos" || {
  echo "error: iphoneos SDK not available." >&2
  exit 1
}

echo
echo "Schemes:"
xcodebuild -list -project Astra.xcodeproj

echo
echo "Simulator build check:"
xcodebuild \
  -project Astra.xcodeproj \
  -scheme Astra \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build

echo
echo "Astra iOS doctor passed"
