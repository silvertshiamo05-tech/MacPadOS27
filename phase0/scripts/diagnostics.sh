#!/bin/bash
# Collect what the forwarder design (Phase 0, run 2) needs to know about the
# Unity 2022.3 iOS export. Never fails the job.
set +e
ROOT=$GITHUB_WORKSPACE
X=$ROOT/phase0/TestProject/Build/iOS
MACAPP=$ROOT/phase0/TestProject/Build/Mac/Phase0Test.app
DD=$RUNNER_TEMP/dd
D=$ROOT/out/diag
mkdir -p "$D"

python3 "$ROOT/tools/unity_inspect.py" "$MACAPP" --json "$D/mac-testgame.json" > "$D/mac-testgame.txt" 2>&1
xcodebuild -list -project "$X/Unity-iPhone.xcodeproj" > "$D/xcode-list.txt" 2>&1
(cd "$X" && find . -maxdepth 3 -not -path './Il2CppOutputProject/IL2CPP/*' | sort) > "$D/xcode-tree.txt"
cp "$X/Unity-iPhone.xcodeproj/project.pbxproj" "$D/" 2>/dev/null
cp "$X/MainApp/main.mm" "$D/main.mm" 2>/dev/null
ls -la "$X/Libraries" > "$D/libraries.txt" 2>&1
grep -rn "DataBundle\|il2cpp_\|UnityInitRuntime\|UnitySetExecuteMLBundle" "$X/Classes" "$X/UnityFramework" "$X/MainApp" 2>/dev/null | head -200 > "$D/trampoline-grep.txt"
find "$X" "$(dirname "$UNITY")/../.." -name 'il2cpp-api-functions.h' 2>/dev/null | head -3 > "$D/api-header-paths.txt"
f=$(head -1 "$D/api-header-paths.txt"); [ -n "$f" ] && cp "$f" "$D/"

defs() { nm -gU "$1" 2>/dev/null | awk 'NF>=3 {print $NF}' | sort -u; }
undefs() { nm -u "$1" 2>/dev/null | awk 'NF==1 && $1 !~ /:$/ {print $1}' | sort -u; }

ENGINE=$X/Libraries/libiPhone-lib.a
GA=$(find "$DD" -name 'libGameAssembly.a' 2>/dev/null | head -1)
echo "engine: $ENGINE" > "$D/symbols-summary.txt"
echo "gameassembly: ${GA:-not found}" >> "$D/symbols-summary.txt"
find "$DD/Build" -name '*.a' -o -name 'UnityFramework' -type f 2>/dev/null | head -20 >> "$D/symbols-summary.txt"
if [ -f "$ENGINE" ] && [ -n "$GA" ]; then
  defs "$ENGINE" > "$D/engine-defined.txt"
  undefs "$ENGINE" | comm -23 - "$D/engine-defined.txt" > "$D/engine-undefined.txt"
  defs "$GA" > "$D/ga-defined.txt"
  undefs "$GA" | comm -23 - "$D/ga-defined.txt" > "$D/ga-undefined.txt"
  comm -12 "$D/engine-undefined.txt" "$D/ga-defined.txt" > "$D/engine-needs-from-ga.txt"
  comm -12 "$D/ga-undefined.txt" "$D/engine-defined.txt" > "$D/ga-needs-from-engine.txt"
  {
    echo "engine needs from GameAssembly: $(wc -l < "$D/engine-needs-from-ga.txt") symbols"
    echo "  il2cpp_* API: $(grep -c '^_il2cpp_' "$D/engine-needs-from-ga.txt")"
    echo "  other:        $(grep -vc '^_il2cpp_' "$D/engine-needs-from-ga.txt")"
    echo "GameAssembly needs from engine: $(wc -l < "$D/ga-needs-from-engine.txt") symbols"
  } >> "$D/symbols-summary.txt"
fi
MACGA=$MACAPP/Contents/Frameworks/GameAssembly.dylib
if [ -f "$MACGA" ]; then
  nm -gU "$MACGA" | awk '{print $NF}' | sort -u > "$D/mac-ga-exports.txt"
  otool -L "$MACGA" > "$D/mac-ga-otool.txt"
  [ -f "$D/engine-needs-from-ga.txt" ] && comm -23 "$D/engine-needs-from-ga.txt" "$D/mac-ga-exports.txt" > "$D/forwarder-gaps.txt" &&
    echo "engine needs that the macOS GameAssembly.dylib does NOT export: $(wc -l < "$D/forwarder-gaps.txt")" >> "$D/symbols-summary.txt"
fi
find "$MACAPP" -maxdepth 4 | sed "s|$MACAPP|Phase0Test.app|" | sort > "$D/mac-app-tree.txt"
APP=$(cat "$D/app-path.txt" 2>/dev/null)
[ -n "$APP" ] && find "$APP" -maxdepth 3 | sed "s|$APP|App|" | sort > "$D/ios-app-tree.txt"

echo "===== symbols-summary"; cat "$D/symbols-summary.txt"
for f in mac-testgame.txt xcode-list.txt libraries.txt forwarder-gaps.txt ga-needs-from-engine.txt; do
  echo "===== $f"; head -80 "$D/$f" 2>/dev/null
done
(cd "$ROOT/out" && zip -qr diagnostics.zip diag logs)
exit 0
