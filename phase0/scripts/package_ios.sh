#!/bin/bash
# Compile the Unity-exported Xcode project without signing (LiveContainer signs
# on install) and zip the macOS test game. build_loader.sh makes the IPA.
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

(cd "$(dirname "$MACAPP")" && ditto -c -k --keepParent Phase0Test.app "$OUT/Phase0Test-mac.zip")
echo "packaged Phase0Test-mac.zip ($(du -h "$OUT/Phase0Test-mac.zip" | cut -f1))"
