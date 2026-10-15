#!/bin/bash
# Compile the Unity-exported Xcode project without signing and package the
# Phase 0 IPAs (LiveContainer signs them on install).
set -euo pipefail
ROOT=$GITHUB_WORKSPACE
X=$ROOT/phase0/TestProject/Build/iOS
MACAPP=$ROOT/phase0/TestProject/Build/Mac/Phase0Test.app
MACDATA=$MACAPP/Contents/Resources/Data
DD=$RUNNER_TEMP/dd
OUT=$ROOT/out
mkdir -p "$OUT/logs" "$OUT/diag"

# Capture Unity's console output (and crash signals) in Documents/unity-player.log,
# since there is no Xcode console on a phone-only setup.
MAIN=$X/MainApp/main.mm
grep -q MP27RedirectStdio "$MAIN" || {
  python3 - "$MAIN" "$ROOT/phase0/forwarder/stdio_capture.mm" <<'PY'
import sys
main, snippet = sys.argv[1], open(sys.argv[2]).read()
s = open(main).read()
s = s.replace("int main(int argc, char* argv[])\n{\n    @autoreleasepool\n    {\n",
              snippet + "\nint main(int argc, char* argv[])\n{\n    @autoreleasepool\n    {\n        MP27RedirectStdio();\n", 1)
assert "MP27RedirectStdio();" in s, "main.mm layout changed"
open(main, "w").write(s)
PY
}

echo "::group::xcodebuild"
if ! xcodebuild -project "$X/Unity-iPhone.xcodeproj" -scheme Unity-iPhone -configuration Release \
     -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath "$DD" \
     CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
     build > "$OUT/logs/xcodebuild.log" 2>&1; then
  grep -E "error:|\*\* BUILD" "$OUT/logs/xcodebuild.log" | head -60
  tail -80 "$OUT/logs/xcodebuild.log"
  exit 1
fi
grep -E "\*\* BUILD" "$OUT/logs/xcodebuild.log"
echo "::endgroup::"

APP=$(find "$DD/Build/Products/Release-iphoneos" -maxdepth 1 -name '*.app' | head -1)
echo "iOS app: $APP"
echo "$APP" > "$OUT/diag/app-path.txt"

pb() { /usr/libexec/PlistBuddy -c "$1" "$2" >/dev/null 2>&1 || true; }

# make_ipa <name> <bundle id> <display name> [hook]
make_ipa() {
  local name=$1 bid=$2 display=$3 hook=${4:-}
  local w; w=$(mktemp -d)
  mkdir "$w/Payload"
  cp -R "$APP" "$w/Payload/"
  local a="$w/Payload/$(basename "$APP")" p
  p="$a/Info.plist"
  pb "Set :CFBundleIdentifier $bid" "$p"
  pb "Delete :CFBundleDisplayName" "$p"; pb "Add :CFBundleDisplayName string $display" "$p"
  pb "Delete :UIFileSharingEnabled" "$p"; pb "Add :UIFileSharingEnabled bool true" "$p"
  pb "Delete :LSSupportsOpeningDocumentsInPlace" "$p"; pb "Add :LSSupportsOpeningDocumentsInPlace bool true" "$p"
  if [ -n "$hook" ]; then "$hook" "$a"; fi
  (cd "$w" && zip -qry "$OUT/$name.ipa" Payload)
  echo "packaged $name.ipa ($(du -h "$OUT/$name.ipa" | cut -f1))"
}

# Experiment E1: iOS engine + iOS GameAssembly, but scene/asset files built for macOS.
swap_in_mac_data() {
  local d=$1/Data
  (cd "$MACDATA" && find . -type f \( -name 'globalgamemanagers*' -o -name 'level[0-9]*' \
      -o -name '*.assets' -o -name '*.resS' -o -name '*.resource' -o -path './Resources/unity_builtin_extra' \)) |
  while read -r f; do
    mkdir -p "$d/$(dirname "$f")"
    cp "$MACDATA/$f" "$d/$f"
    echo "swapped ${f#./}"
  done | tee "$OUT/diag/macdata-swapped.txt"
}

# Bisection of the macdata crash: each variant swaps in one part of the macOS data.
swap_files() { # <app> <file>...
  local d=$1/Data; shift
  for f in "$@"; do
    [ -f "$MACDATA/$f" ] || continue
    mkdir -p "$d/$(dirname "$f")"; cp "$MACDATA/$f" "$d/$f"; echo "  swapped $f"
  done
}
v_platform()  { swap_in_mac_data "$1" >/dev/null
                (cd "$1/Data" && python3 "$ROOT/tools/serialized_types.py" --set-platform 9 \
                   globalgamemanagers globalgamemanagers.assets level0 resources.assets sharedassets0.assets Resources/unity_builtin_extra); }
v_scene()     { swap_files "$1" level0 sharedassets0.assets sharedassets0.assets.resS; }
v_managers()  { swap_files "$1" globalgamemanagers globalgamemanagers.assets globalgamemanagers.assets.resS; }
v_shaders()   { swap_files "$1" Resources/unity_builtin_extra; }
v_resources() { swap_files "$1" resources.assets; }

make_ipa Phase0-native     com.macpados27.phase0.native    "P0 Native"
make_ipa Phase0-macdata    com.macpados27.phase0.macdata   "P0 MacData" swap_in_mac_data
make_ipa P0-1-platform     com.macpados27.phase0.platform  "P0 1 Platform"  v_platform
make_ipa P0-2-managers     com.macpados27.phase0.managers  "P0 2 Managers"  v_managers
make_ipa P0-3-scene        com.macpados27.phase0.scene     "P0 3 Scene"     v_scene
make_ipa P0-4-shaders      com.macpados27.phase0.shaders   "P0 4 Shaders"   v_shaders
make_ipa P0-5-resources    com.macpados27.phase0.resources "P0 5 Resources" v_resources

(cd "$(dirname "$MACAPP")" && ditto -c -k --keepParent Phase0Test.app "$OUT/Phase0Test-mac.zip")
echo "packaged Phase0Test-mac.zip ($(du -h "$OUT/Phase0Test-mac.zip" | cut -f1))"
