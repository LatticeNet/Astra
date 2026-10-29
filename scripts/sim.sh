#!/bin/bash
# Build, run and screenshot Astra in the iOS simulator.
#
#   scripts/sim.sh build                 build for the simulator (DerivedData/sim in this checkout)
#   scripts/sim.sh run [-- ARGS...]      boot this checkout's simulator, install, launch with ARGS
#   scripts/sim.sh demo [ROUTE] [SCENARIO] [-- ARGS...]
#                                        launch in demo mode at a deep link route (lattice://...),
#                                        with a demo scenario (failing:/api/monitors) and extra args
#   scripts/sim.sh open URL              open a deep link (lattice://...) in the running app
#   scripts/sim.sh shot [MODULE/]NAME [OPTS]
#                                        screenshot to $ASTRA_SHOTS/<branch>/[MODULE/]NAME.png
#        OPTS: --dark | --light, --text SIZE (xs s m l xl xxl xxxl ax1..ax5), --contrast | --no-contrast,
#              --wait SECONDS
#   scripts/sim.sh reset-ui              light mode, default text size, standard contrast
#   scripts/sim.sh down                  shut down and delete this checkout's simulator
#
# Several checkouts (git worktrees) can use this at once. Each gets its own simulator per base
# device, named Astra-<hash of checkout path>-<device slug>, and builds wait for a free slot so
# that at most ASTRA_BUILD_SLOTS (default 3) xcodebuilds run on this machine at the same time.
# ASTRA_BASE_DEVICE picks the base device ("iPhone 17 Pro" by default, "iPhone SE (3rd
# generation)" for the AX5 passes); a missing base device is created on the newest iOS runtime.
# Screenshots land outside every worktree, in ${ASTRA_SHOTS:-~/Library/Caches/AstraShots}.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE=org.roobli.cdcd.Astra
BASE_DEVICE="${ASTRA_BASE_DEVICE:-iPhone 17 Pro}"
SLOTS="${ASTRA_BUILD_SLOTS:-3}"
LOCKS=/tmp/astra-build-slots
BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo detached)"
SHOTS="${ASTRA_SHOTS:-$HOME/Library/Caches/AstraShots}/$BRANCH"
KEY="$(printf '%s' "$ROOT" | shasum | cut -c1-8)"
SLUG="$(printf '%s' "$BASE_DEVICE" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed -E 's/^-+|-+$//g')"
DEVICE_NAME="Astra-$KEY-$SLUG"
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

# The base device, created on the newest iOS runtime when this machine has none by that name
# (for example: xcrun simctl create 'iPhone SE (3rd generation)'
#  com.apple.CoreSimulator.SimDeviceType.iPhone-SE-3rd-generation <iOS 26.5 runtime id>).
ensure_base_device(){
  local base; base="$(device_id "$BASE_DEVICE")"
  if [ -z "$base" ]; then
    local type runtime
    type="$(xcrun simctl list devicetypes -j | /usr/bin/python3 -c '
import json,sys
name=sys.argv[1]
for t in json.load(sys.stdin)["devicetypes"]:
    if t["name"]==name: print(t["identifier"]); break' "$BASE_DEVICE")"
    runtime="$(xcrun simctl list runtimes -j | /usr/bin/python3 -c '
import json,sys
rts=[r for r in json.load(sys.stdin)["runtimes"] if r.get("platform")=="iOS" and r.get("isAvailable")]
rts.sort(key=lambda r: [int(p) for p in r["version"].split(".")])
print(rts[-1]["identifier"] if rts else "")')"
    [ -n "$type" ] && [ -n "$runtime" ] || { say "cannot create '$BASE_DEVICE': unknown device type or no iOS runtime"; exit 2; }
    base="$(xcrun simctl create "$BASE_DEVICE" "$type" "$runtime")"
    say "created base simulator $BASE_DEVICE ($base) on $runtime"
  fi
  printf '%s' "$base"
}

ensure_device(){
  local id; id="$(device_id "$DEVICE_NAME")"
  if [ -z "$id" ]; then
    local base; base="$(ensure_base_device)"
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
  ensure_base_device >/dev/null
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
  local args=(-AstraDemo YES)
  if [ $# -gt 0 ] && [ "$1" != "--" ]; then
    [ -n "$1" ] && args+=(-AstraRoute "$1")
    shift
  fi
  if [ $# -gt 0 ] && [ "$1" != "--" ]; then
    [ -n "$1" ] && args+=(-AstraDemoScenario "$1")
    shift
  fi
  [ "${1:-}" = "--" ] && shift
  cmd_run "${args[@]}" "$@"
}

cmd_open(){ local id; id="$(ensure_device)"; xcrun simctl openurl "$id" "$1"; }

cmd_shot(){
  local name="$1"; shift
  local wait=2 id; id="$(ensure_device)"
  while [ $# -gt 0 ]; do
    case "$1" in
      --dark) xcrun simctl ui "$id" appearance dark ;;
      --light) xcrun simctl ui "$id" appearance light ;;
      --contrast) xcrun simctl ui "$id" increase_contrast enabled ;;
      --no-contrast) xcrun simctl ui "$id" increase_contrast disabled ;;
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
  local file="$SHOTS/$name.png"
  mkdir -p "$(dirname "$file")"
  xcrun simctl io "$id" screenshot "$file" >/dev/null 2>&1
  sips -Z 1000 "$file" >/dev/null
  printf '%s\n' "$file"
}

cmd_reset_ui(){
  local id; id="$(ensure_device)"
  xcrun simctl ui "$id" appearance light
  xcrun simctl ui "$id" content_size large
  xcrun simctl ui "$id" increase_contrast disabled
}

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
  demo) shift; cmd_demo "$@" ;;
  open) shift; cmd_open "$1" ;;
  shot) shift; cmd_shot "$@" ;;
  reset-ui) cmd_reset_ui ;;
  down) cmd_down ;;
  *) sed -n '2,25p' "$0"; exit 2 ;;
esac
