#!/bin/bash
# Build, run and screenshot Astra in the iOS simulator.
#
#   scripts/sim.sh build                 build for the simulator (DerivedData/sim in this checkout)
#   scripts/sim.sh run [-- ARGS...]      boot this checkout's simulator, install, launch with ARGS
#   scripts/sim.sh demo [ROUTE]          launch in demo mode, optionally at a deep link route
#   scripts/sim.sh open URL              open a deep link (lattice://...) in the running app
#   scripts/sim.sh shot NAME [OPTS]      screenshot to $ASTRA_SHOTS (default ./DerivedData/shots)
#        OPTS: --dark | --light, --text SIZE (xs s m l xl xxl xxxl ax1..ax5), --wait SECONDS
#   scripts/sim.sh reset-ui              light mode, default text size
#   scripts/sim.sh down                  shut down and delete this checkout's simulator
#
# Several checkouts (git worktrees) can use this at once. Each gets its own simulator, named
# after the checkout path, and builds wait for a free slot so that at most ASTRA_BUILD_SLOTS
# (default 3) xcodebuilds run on this machine at the same time.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE=org.roobli.cdcd.Astra
BASE_DEVICE="${ASTRA_BASE_DEVICE:-iPhone 17 Pro}"
SLOTS="${ASTRA_BUILD_SLOTS:-3}"
LOCKS=/tmp/astra-build-slots
SHOTS="${ASTRA_SHOTS:-$ROOT/DerivedData/shots}"
KEY="$(printf '%s' "$ROOT" | shasum | cut -c1-8)"
DEVICE_NAME="Astra-$KEY"
DERIVED="$ROOT/DerivedData/sim"

say(){ printf '%s %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

device_id(){
  xcrun simctl list devices -j | /usr/bin/python3 -c '
import json,sys
name=sys.argv[1]
for rt,devs in json.load(sys.stdin)["devices"].items():
    for d in devs:
        if d["name"]==name and d.get("isAvailable",True):
            print(d["udid"]); sys.exit(0)' "$1"
}

ensure_device(){
  local id; id="$(device_id "$DEVICE_NAME")"
  if [ -z "$id" ]; then
    local base; base="$(device_id "$BASE_DEVICE")"
    [ -n "$base" ] || { say "no base simulator named '$BASE_DEVICE'"; exit 2; }
    id="$(xcrun simctl clone "$base" "$DEVICE_NAME")"
    say "created simulator $DEVICE_NAME ($id) from $BASE_DEVICE"
  fi
  if ! xcrun simctl list devices | grep "$id" | grep -q Booted; then
    xcrun simctl boot "$id" >/dev/null 2>&1 || true
    xcrun simctl bootstatus "$id" -b >/dev/null 2>&1 || true
  fi
  printf '%s' "$id"
}

acquire_slot(){
  mkdir -p "$LOCKS"
  while true; do
    for i in $(seq 1 "$SLOTS"); do
      if mkdir "$LOCKS/slot$i" 2>/dev/null; then
        echo "$$ $ROOT" > "$LOCKS/slot$i/owner"
        SLOT="$LOCKS/slot$i"; return 0
      fi
      # Reclaim a slot whose owner died.
      local pid; pid="$(cut -d' ' -f1 "$LOCKS/slot$i/owner" 2>/dev/null || true)"
      if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then rm -rf "$LOCKS/slot$i"; fi
    done
    sleep 5
  done
}

cmd_build(){
  acquire_slot
  trap 'rm -rf "$SLOT"' EXIT
  say "building in $ROOT (slot $(basename "$SLOT"))"
  local log="$ROOT/DerivedData/build.log"; mkdir -p "$ROOT/DerivedData"
  if xcodebuild -project "$ROOT/Astra.xcodeproj" -scheme Astra -sdk iphonesimulator -configuration Debug \
      -destination "platform=iOS Simulator,name=$BASE_DEVICE" -derivedDataPath "$DERIVED" \
      CODE_SIGNING_ALLOWED=NO build >"$log" 2>&1; then
    grep -E 'warning: ' "$log" | grep -v appintentsmetadataprocessor | sed -E "s|^$ROOT/||" | sort -u | head -40 || true
    say "BUILD SUCCEEDED"
  else
    grep -E 'error: ' "$log" | sed -E "s|^$ROOT/||" | sort -u | head -60
    say "BUILD FAILED (full log: $log)"; exit 1
  fi
}

app_path(){ find "$DERIVED/Build/Products/Debug-iphonesimulator" -maxdepth 1 -name '*.app' | head -1; }

cmd_run(){
  local id; id="$(ensure_device)"
  local app; app="$(app_path)"; [ -n "$app" ] || { say "build first"; exit 2; }
  xcrun simctl terminate "$id" "$BUNDLE" >/dev/null 2>&1 || true
  xcrun simctl install "$id" "$app"
  xcrun simctl launch "$id" "$BUNDLE" "$@" >/dev/null
  say "launched on $DEVICE_NAME"
}

cmd_demo(){
  if [ -n "${1:-}" ]; then cmd_run -AstraDemo YES -AstraRoute "$1"; else cmd_run -AstraDemo YES; fi
}

cmd_open(){ local id; id="$(ensure_device)"; xcrun simctl openurl "$id" "$1"; }

cmd_shot(){
  local name="$1"; shift
  local wait=2 id; id="$(ensure_device)"
  while [ $# -gt 0 ]; do
    case "$1" in
      --dark) xcrun simctl ui "$id" appearance dark ;;
      --light) xcrun simctl ui "$id" appearance light ;;
      --text)
        local s="$2"; shift
        case "$s" in
          xs) s=extra-small ;; s) s=small ;; m) s=medium ;; l) s=large ;; xl) s=extra-large ;;
          xxl) s=extra-extra-large ;; xxxl) s=extra-extra-extra-large ;;
          ax1) s=accessibility-medium ;; ax2) s=accessibility-large ;; ax3) s=accessibility-extra-large ;;
          ax4) s=accessibility-extra-extra-large ;; ax5) s=accessibility-extra-extra-extra-large ;;
        esac
        xcrun simctl ui "$id" content_size "$s" ;;
      --wait) wait="$2"; shift ;;
    esac
    shift
  done
  sleep "$wait"
  mkdir -p "$SHOTS"
  xcrun simctl io "$id" screenshot "$SHOTS/$name.png" >/dev/null 2>&1
  sips -Z 1000 "$SHOTS/$name.png" >/dev/null
  printf '%s\n' "$SHOTS/$name.png"
}

cmd_reset_ui(){ local id; id="$(ensure_device)"; xcrun simctl ui "$id" appearance light; xcrun simctl ui "$id" content_size large; }

cmd_down(){
  local id; id="$(device_id "$DEVICE_NAME")"
  [ -n "$id" ] || exit 0
  xcrun simctl shutdown "$id" >/dev/null 2>&1 || true
  xcrun simctl delete "$id"
  say "deleted $DEVICE_NAME"
}

case "${1:-}" in
  build) cmd_build ;;
  run) shift; [ "${1:-}" = "--" ] && shift; cmd_run "$@" ;;
  demo) shift; cmd_demo "${1:-}" ;;
  open) shift; cmd_open "$1" ;;
  shot) shift; cmd_shot "$@" ;;
  reset-ui) cmd_reset_ui ;;
  down) cmd_down ;;
  *) sed -n '2,16p' "$0"; exit 2 ;;
esac
