#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT_DIR"

mkdir -p .build/module-cache .build/swiftpm-cache .build/swiftpm-config .build/swiftpm-security
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/module-cache"

echo "Checking plist files"
plutil -lint Astra.xcodeproj/project.pbxproj AstraApp/Info.plist >/dev/null
plutil -lint Config/ExportOptions.Development.plist >/dev/null
jq empty AstraApp/Assets.xcassets/AppIcon.appiconset/Contents.json
/usr/libexec/PlistBuddy -c "Print :UIBackgroundModes:0" AstraApp/Info.plist | grep -q '^fetch$'
/usr/libexec/PlistBuddy -c "Print :BGTaskSchedulerPermittedIdentifiers:0" AstraApp/Info.plist | grep -q '^org.roobli.astra.refresh$'
grep -q "BackgroundTaskCompletionBox" AstraApp/App/BackgroundRefresh.swift || {
  echo "error: background refresh task completion guard is missing" >&2
  exit 1
}
grep -q "Background refresh expired" AstraApp/App/BackgroundRefresh.swift || {
  echo "error: background refresh expiration status is not recorded" >&2
  exit 1
}
grep -q "Task.checkCancellation()" AstraApp/App/BackgroundRefresh.swift || {
  echo "error: background refresh runner must check cancellation before recording success" >&2
  exit 1
}
grep -q "catch is CancellationError" AstraApp/App/BackgroundRefresh.swift || {
  echo "error: background refresh cancellation must not overwrite expiration failure status" >&2
  exit 1
}
if grep -q "if !Task.isCancelled" AstraApp/App/BackgroundRefresh.swift; then
  echo "error: background refresh completion must not be skipped after cancellation" >&2
  exit 1
fi
background_cancel_count="$(grep -c "BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: AstraBackgroundRefresh.identifier)" AstraApp/App/BackgroundRefresh.swift)"
if [ "$background_cancel_count" -lt 2 ]; then
  echo "error: enabled background refresh scheduling must replace any pending request before submit" >&2
  exit 1
fi

echo "Checking Xcode scheme XML"
xmllint --noout Astra.xcodeproj/xcshareddata/xcschemes/Astra.xcscheme

echo "Checking Xcode target membership"
for file in AstraApp/App/*.swift Sources/AstraCore/*.swift; do
  name="$(basename "$file")"
  grep -q "/\\* $name in Sources \\*/" Astra.xcodeproj/project.pbxproj || {
    echo "error: $file is not in the Astra target sources" >&2
    exit 1
  }
done
grep -q "/\\* Security.framework in Frameworks \\*/" Astra.xcodeproj/project.pbxproj || {
  echo "error: Security.framework is not linked" >&2
  exit 1
}
grep -q "/\\* BackgroundTasks.framework in Frameworks \\*/" Astra.xcodeproj/project.pbxproj || {
  echo "error: BackgroundTasks.framework is not linked" >&2
  exit 1
}
grep -q "SecItemDelete(query as CFDictionary)" AstraApp/App/AppSettings.swift || {
  echo "error: clearing a secret must delete the Keychain item" >&2
  exit 1
}
grep -q "trimmingCharacters(in: .whitespacesAndNewlines)" AstraApp/App/AppSettings.swift || {
  echo "error: secrets must be trimmed before Keychain persistence" >&2
  exit 1
}
grep -Fq "UIApplication.didEnterBackgroundNotification" AstraApp/App/AstraApp.swift || {
  echo "error: app lifecycle must observe iOS background entry" >&2
  exit 1
}
grep -Fq ".onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification))" AstraApp/App/AstraApp.swift || {
  echo "error: app must save settings when entering background" >&2
  exit 1
}
grep -Fq "model.saveSettings()" AstraApp/App/AstraApp.swift || {
  echo "error: scenePhase background handling must persist editable settings and secrets" >&2
  exit 1
}
grep -Fq "settings.latticeBaseURL = settings.latticeBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)" AstraApp/App/DashboardModel.swift || {
  echo "error: Lattice URL settings must be trimmed before persistence" >&2
  exit 1
}
grep -Fq "settings.barkServerURL = settings.barkServerURL.trimmingCharacters(in: .whitespacesAndNewlines)" AstraApp/App/DashboardModel.swift || {
  echo "error: Bark server URL settings must be trimmed before persistence" >&2
  exit 1
}
grep -Fq "settings.barkGroup = settings.barkGroup.trimmingCharacters(in: .whitespacesAndNewlines)" AstraApp/App/DashboardModel.swift || {
  echo "error: Bark group settings must be trimmed before persistence" >&2
  exit 1
}
grep -Fq "settings.barkSound = settings.barkSound.trimmingCharacters(in: .whitespacesAndNewlines)" AstraApp/App/DashboardModel.swift || {
  echo "error: Bark sound settings must be trimmed before persistence" >&2
  exit 1
}
grep -Fq "guard !isBusy else {" AstraApp/App/DashboardModel.swift || {
  echo "error: foreground network actions must guard against overlapping busy work" >&2
  exit 1
}
grep -Fq "performRefresh(sendNotifications:" AstraApp/App/DashboardModel.swift || {
  echo "error: refresh implementation must be split so login can refresh after releasing busy state" >&2
  exit 1
}
python3 - <<'PY'
from pathlib import Path
source = Path("AstraApp/App/DashboardModel.swift").read_text()
start = source.index("    func startPolling() {")
end = source.index("    func stopPolling()", start)
body = source[start:end]
if "saveSettings()" not in body:
    raise SystemExit("error: starting polling must save normalized settings before scheduling")
if body.index("saveSettings()") > body.index("isPolling = true"):
    raise SystemExit("error: polling start must save settings before mutating polling state")
PY
grep -q "let username = loginUsername.trimmingCharacters(in: .whitespacesAndNewlines)" AstraApp/App/DashboardModel.swift || {
  echo "error: Lattice login username must be trimmed before validation and login" >&2
  exit 1
}
grep -q "login(username: username, password: loginPassword)" AstraApp/App/DashboardModel.swift || {
  echo "error: Lattice login must use the trimmed username" >&2
  exit 1
}
grep -q "BarkDeviceKeyNormalizer.deviceKey" Sources/AstraCore/AstraCore.swift || {
  echo "error: Bark device key normalization is missing from core" >&2
  exit 1
}
grep -q "barkDeviceKey = BarkDeviceKeyNormalizer.deviceKey" AstraApp/App/DashboardModel.swift || {
  echo "error: Settings must normalize pasted Bark device key URLs before saving" >&2
  exit 1
}
grep -q "payload\\[\"url\"\\]" Sources/AstraCore/AstraCore.swift || {
  echo "error: Bark payload must include optional click-through URL support" >&2
  exit 1
}
grep -q "enum BarkInterruptionLevel" Sources/AstraCore/AstraCore.swift || {
  echo "error: Bark interruption level support is missing from core" >&2
  exit 1
}
grep -q "var barkLevel: BarkInterruptionLevel" AstraApp/App/AppSettings.swift || {
  echo "error: Settings must persist Bark notification level" >&2
  exit 1
}
grep -q "level: settings.barkLevel" AstraApp/App/DashboardModel.swift || {
  echo "error: foreground Bark configuration must use the persisted notification level" >&2
  exit 1
}
grep -q "level: settings.barkLevel" AstraApp/App/BackgroundRefresh.swift || {
  echo "error: background Bark configuration must use the persisted notification level" >&2
  exit 1
}
grep -q "latticeDashboardURL(from rawValue" Sources/AstraCore/AstraCore.swift || {
  echo "error: Lattice dashboard URL normalization is missing from core" >&2
  exit 1
}
grep -q "url: normalizedLatticeDashboardURL(settings.latticeBaseURL)" AstraApp/App/DashboardModel.swift || {
  echo "error: foreground Bark configuration must include the Lattice click-through URL" >&2
  exit 1
}
grep -q "url: normalizedLatticeDashboardURL(settings.latticeBaseURL)" AstraApp/App/BackgroundRefresh.swift || {
  echo "error: background Bark configuration must include the Lattice click-through URL" >&2
  exit 1
}
grep -q "enum NodeStore" AstraApp/App/AppSettings.swift || {
  echo "error: node snapshot persistence store is missing" >&2
  exit 1
}
grep -q "refreshedAt: Date?" AstraApp/App/AppSettings.swift || {
  echo "error: node snapshots must persist their refresh timestamp" >&2
  exit 1
}
grep -q "let nodeSnapshot = NodeStore.load()" AstraApp/App/DashboardModel.swift || {
  echo "error: dashboard must load persisted node snapshots" >&2
  exit 1
}
grep -q "lastRefresh = nodeSnapshot.refreshedAt" AstraApp/App/DashboardModel.swift || {
  echo "error: dashboard must restore the persisted node snapshot timestamp" >&2
  exit 1
}
grep -q "NodeStore.save(fetched, refreshedAt: refreshedAt)" AstraApp/App/DashboardModel.swift || {
  echo "error: foreground refresh must persist node snapshots" >&2
  exit 1
}
grep -q "NodeStore.save(nodes)" AstraApp/App/BackgroundRefresh.swift || {
  echo "error: background refresh must persist node snapshots" >&2
  exit 1
}
bundle_ids="$(awk -F' = ' '
  /PRODUCT_BUNDLE_IDENTIFIER = / {
    value = $2
    sub(/;$/, "", value)
    seen[value] = 1
  }
  END {
    for (value in seen) {
      print value
    }
  }
' Astra.xcodeproj/project.pbxproj)"
bundle_id_count="$(printf "%s\n" "$bundle_ids" | awk 'NF { count++ } END { print count + 0 }')"
if [ "$bundle_id_count" -eq 0 ]; then
  echo "error: no PRODUCT_BUNDLE_IDENTIFIER entries found in Xcode project" >&2
  exit 1
fi
if [ "$bundle_id_count" -ne 1 ]; then
  echo "error: Debug and Release bundle identifiers must match" >&2
  printf "%s\n" "$bundle_ids" >&2
  exit 1
fi
actual_bundle_id="$(printf "%s\n" "$bundle_ids" | awk 'NF { print; exit }')"
case "$actual_bundle_id" in
  *.*) ;;
  *)
    echo "error: bundle identifier must use reverse-DNS form, got '$actual_bundle_id'" >&2
    exit 1
    ;;
esac
case "$actual_bundle_id" in
  *[!A-Za-z0-9.-]*)
    echo "error: bundle identifier contains unsupported characters: '$actual_bundle_id'" >&2
    exit 1
    ;;
esac
case "$actual_bundle_id" in
  com.yourname.lattice|org.roobli.astra)
    echo "warning: bundle identifier is still a template/default value: $actual_bundle_id" >&2
    ;;
esac
if [ "${ASTRA_BUNDLE_ID:-}" ] && [ "$actual_bundle_id" != "$ASTRA_BUNDLE_ID" ]; then
  echo "error: Xcode project bundle identifier '$actual_bundle_id' does not match ASTRA_BUNDLE_ID '$ASTRA_BUNDLE_ID'" >&2
  exit 1
fi
echo "Bundle identifier: $actual_bundle_id"
grep -q "ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;" Astra.xcodeproj/project.pbxproj || {
  echo "error: AppIcon is not configured as the app icon" >&2
  exit 1
}
grep -q "IPHONEOS_DEPLOYMENT_TARGET = 16.0;" Astra.xcodeproj/project.pbxproj || {
  echo "error: iOS deployment target should stay at 16.0 for wider device install coverage" >&2
  exit 1
}
grep -q "/\\* Assets.xcassets in Resources \\*/" Astra.xcodeproj/project.pbxproj || {
  echo "error: Assets.xcassets is not in the Astra target resources" >&2
  exit 1
}
if rg -n "ContentUnavailableView" AstraApp Sources Checks >/dev/null; then
  echo "error: ContentUnavailableView requires iOS 17; keep the app installable on iOS 16" >&2
  exit 1
fi

for icon in \
  Icon-20@2x.png Icon-20@3x.png Icon-29@2x.png Icon-29@3x.png \
  Icon-40@2x.png Icon-40@3x.png Icon-60@2x.png Icon-60@3x.png Icon-1024.png
do
  test -s "AstraApp/Assets.xcassets/AppIcon.appiconset/$icon" || {
    echo "error: missing AppIcon asset $icon" >&2
    exit 1
  }
done

check_icon_size() {
  icon_path="AstraApp/Assets.xcassets/AppIcon.appiconset/$1"
  expected_width="$2"
  expected_height="$3"
  actual_size="$(sips -g pixelWidth -g pixelHeight "$icon_path" 2>/dev/null | awk '
    /pixelWidth:/ { width = $2 }
    /pixelHeight:/ { height = $2 }
    END { print width "x" height }
  ')"
  expected_size="${expected_width}x${expected_height}"
  if [ "$actual_size" != "$expected_size" ]; then
    echo "error: $1 has size $actual_size, expected $expected_size" >&2
    exit 1
  fi
}

check_icon_size Icon-20@2x.png 40 40
check_icon_size Icon-20@3x.png 60 60
check_icon_size Icon-29@2x.png 58 58
check_icon_size Icon-29@3x.png 87 87
check_icon_size Icon-40@2x.png 80 80
check_icon_size Icon-40@3x.png 120 120
check_icon_size Icon-60@2x.png 120 120
check_icon_size Icon-60@3x.png 180 180
check_icon_size Icon-1024.png 1024 1024

echo "Checking secret hygiene"
bark_key_pattern="jV""Fa|Pd""Jrei"
if rg -n "$bark_key_pattern" Sources AstraApp Checks Config docs README.md Package.swift Astra.xcodeproj >/dev/null; then
  echo "error: Bark device key material is present in project files" >&2
  exit 1
fi

echo "Checking helper scripts"
sh -n scripts/doctor-ios.sh
sh -n scripts/build-ios-device.sh
sh -n scripts/archive-ios-development.sh
if grep -Fq 'BUNDLE_ID="${ASTRA_BUNDLE_ID:-org.roobli.astra}"' scripts/build-ios-device.sh scripts/archive-ios-development.sh; then
  echo "error: build/export scripts must default to the project bundle identifier, not the old template value" >&2
  exit 1
fi
swiftc -typecheck scripts/generate-icons.swift

echo "Running AstraCoreCheck"
swift run \
  --disable-sandbox \
  --cache-path .build/swiftpm-cache \
  --config-path .build/swiftpm-config \
  --security-path .build/swiftpm-security \
  --scratch-path .build \
  AstraCoreCheck

echo "Type-checking SwiftUI app sources with the available SDK"
swiftc -typecheck -parse-as-library \
  Sources/AstraCore/AstraCore.swift \
  AstraApp/App/AstraApp.swift \
  AstraApp/App/AppSettings.swift \
  AstraApp/App/BackgroundRefresh.swift \
  AstraApp/App/DashboardModel.swift \
  AstraApp/App/ContentView.swift \
  AstraApp/App/ServerDetailView.swift

echo "Local checks passed"
