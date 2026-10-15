#!/bin/bash
# Phase 0 run 2: turn the exported iOS project into the MacPadOS27 loader.
#
#  1. Forwarder: every symbol the engine (libiPhone-lib.a) takes from the
#     prebuilt IL2CPP runtime (Libraries/libil2cpp.a) becomes an arm64
#     trampoline into the macOS GameAssembly.dylib, which carries its own
#     copy of the IL2CPP runtime. The forwarder archive replaces libil2cpp.a.
#     The shell's own generated code (libGameAssembly.a) still supplies the
#     engine's class/icall registration functions; nothing else in it is
#     referenced any more, so the linker drops it.
#  2. UnityDataBundleDir() is patched to ask the loader first, so a game copied
#     to Documents/Game can supply the Data folder.
#  3. Relink and package MacPadOS27.ipa with the macOS test game's
#     GameAssembly.dylib (retargeted to iOS) and prepared Data bundled inside.
set -euo pipefail
ROOT=$GITHUB_WORKSPACE
X=$ROOT/phase0/TestProject/Build/iOS
MACAPP=$ROOT/phase0/TestProject/Build/Mac/Phase0Test.app
DD=$RUNNER_TEMP/dd
OUT=$ROOT/out
F=$OUT/forwarder
mkdir -p "$F" "$OUT/diag" "$OUT/logs"

defs() { nm -gU "$1" 2>/dev/null | awk 'NF>=3 {print $NF}' | sort -u; }
undefs() { nm -u "$1" 2>/dev/null | awk 'NF==1 && $1 !~ /:$/ {print $1}' | sort -u; }

echo "::group::forwarder symbols"
# Functions only (nm type T): data symbols cannot be forwarded by a trampoline.
nm -gU "$X/Libraries/libil2cpp.a" | awk '$2=="T" {print $3}' | sort -u > "$F/il2cpp-defined.txt"
nm -gU "$X/Libraries/libil2cpp.a" | awk 'NF>=3 && $2!="T" {print $3}' | sort -u > "$F/il2cpp-data.txt"
comm -12 "$F/il2cpp-data.txt" <(undefs "$X/Libraries/libiPhone-lib.a") > "$F/data-needed.txt" || true
echo "data symbols the engine takes from libil2cpp.a (cannot forward): $(wc -l < "$F/data-needed.txt")"
head -20 "$F/data-needed.txt"
undefs "$X/Libraries/libiPhone-lib.a" > "$F/engine-undefined.txt"
comm -12 "$F/engine-undefined.txt" "$F/il2cpp-defined.txt" > "$F/forward.txt"
defs "$MACAPP/Contents/Frameworks/GameAssembly.dylib" > "$F/mac-exports.txt"
comm -23 "$F/forward.txt" "$F/mac-exports.txt" > "$F/gaps.txt"
echo "engine takes $(wc -l < "$F/forward.txt") symbols from libil2cpp.a ($(grep -c '^_il2cpp_' "$F/forward.txt") il2cpp_* API)"
echo "of those, NOT exported by the macOS GameAssembly.dylib: $(wc -l < "$F/gaps.txt")"
head -40 "$F/gaps.txt"
cp "$F/forward.txt" "$F/gaps.txt" "$OUT/diag/"
echo "::endgroup::"

echo "::group::compile forwarder"
python3 "$ROOT/phase0/forwarder/gen_forwarder.py" "$F/forward.txt" "$F"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
CC=(xcrun --sdk iphoneos clang -target arm64-apple-ios15.0 -isysroot "$SDK" -O2 -c)
"${CC[@]}" "$F/mp27_stubs.s" -o "$F/stubs.o"
"${CC[@]}" "$F/mp27_table.c" -o "$F/table.o"
FW=$ROOT/phase0/forwarder
"${CC[@]}" -fobjc-arc -I"$FW" "$FW/mp27_loader.m" -o "$F/loader.o"
"${CC[@]}" -I"$FW" "$FW/mp27_prep.c" -o "$F/prep.o"
libtool -static -o "$F/libil2cpp.a" "$F/stubs.o" "$F/table.o" "$F/loader.o" "$F/prep.o"
# The same preparation code as a command-line tool, for the bundled demo below.
clang -O2 -DMP27_PREP_MAIN -I"$FW" "$FW/mp27_prep.c" -o "$F/mp27prep"
cp "$X/Libraries/libil2cpp.a" "$F/libil2cpp.original.a"
cp "$F/libil2cpp.a" "$X/Libraries/libil2cpp.a"
echo "::endgroup::"

echo "::group::patch UnityDataBundleDir"
FS=$X/Classes/Unity/Filesystem.mm
grep -q 'mp27_data_bundle_dir' "$FS" || {
  sed -i '' 's/extern "C" const char\* UnityDataBundleDir()/static const char* UnityDataBundleDir_Unity()/' "$FS"
  cat >> "$FS" <<'EOF'

// MacPadOS27: let the loader supply the Data folder (Documents/Game/...).
extern "C" const char* mp27_data_bundle_dir(void);
extern "C" const char* UnityDataBundleDir()
{
    const char* p = mp27_data_bundle_dir();
    return p ? p : UnityDataBundleDir_Unity();
}
EOF
}
grep -n 'UnityDataBundleDir' "$FS"
echo "::endgroup::"

echo "::group::relink"
status=0
xcodebuild -project "$X/Unity-iPhone.xcodeproj" -scheme Unity-iPhone -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath "$DD" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  build > "$OUT/logs/xcodebuild-loader.log" 2>&1 || status=$?
cp "$F/libil2cpp.original.a" "$X/Libraries/libil2cpp.a"
if [ $status -ne 0 ]; then
  grep -E "error:|Undefined symbols|referenced from|^  \"_" "$OUT/logs/xcodebuild-loader.log" | head -120
  exit 1
fi
grep -E "\*\* BUILD" "$OUT/logs/xcodebuild-loader.log"
echo "::endgroup::"

APP=$(find "$DD/Build/Products/Release-iphoneos" -maxdepth 1 -name '*.app' | head -1)
UF=$APP/Frameworks/UnityFramework.framework/UnityFramework
echo "UnityFramework il2cpp_* defined: $(nm -gU "$UF" | grep -c ' _il2cpp_' || true), mp27 symbols: $(nm -gU "$UF" | grep -c '_mp27_' || true)"

pb() { /usr/libexec/PlistBuddy -c "$1" "$2" >/dev/null 2>&1 || true; }
# The app: loader + the macOS test game bundled as a demo (prepared here, so
# it runs without JIT: LiveContainer signs the bundled GameAssembly.dylib).
w=$(mktemp -d)
mkdir "$w/Payload"
cp -R "$APP" "$w/Payload/"
a="$w/Payload/$(basename "$APP")"
p="$a/Info.plist"
pb "Set :CFBundleIdentifier com.macpados27.app" "$p"
pb "Delete :CFBundleDisplayName" "$p"; pb "Add :CFBundleDisplayName string MacPadOS27" "$p"
pb "Delete :UIFileSharingEnabled" "$p"; pb "Add :UIFileSharingEnabled bool true" "$p"
pb "Delete :LSSupportsOpeningDocumentsInPlace" "$p"; pb "Add :LSSupportsOpeningDocumentsInPlace bool true" "$p"
rsync -a "$MACAPP/Contents/Resources/Data/" "$a/Data/"
"$F/mp27prep" "$a/Data"
python3 "$ROOT/tools/macho_retarget.py" "$MACAPP/Contents/Frameworks/GameAssembly.dylib" "$a/Frameworks/GameAssembly.dylib"
codesign -f -s - "$a/Frameworks/GameAssembly.dylib"
(cd "$w" && zip -qry "$OUT/MacPadOS27.ipa" Payload)
echo "packaged MacPadOS27.ipa ($(du -h "$OUT/MacPadOS27.ipa" | cut -f1))"
