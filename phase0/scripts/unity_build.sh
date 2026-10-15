#!/bin/bash
# Run one Unity batch-mode build. Usage: unity_build.sh <buildTarget> <Class.Method>
set -uo pipefail
target=$1 method=$2
mkdir -p out/logs
"$UNITY" -batchmode -nographics -quit \
  -projectPath "$GITHUB_WORKSPACE/phase0/TestProject" \
  -buildTarget "$target" -executeMethod "$method" \
  -logFile - 2>&1 | tee "out/logs/unity-$target.log"
status=${PIPESTATUS[0]}
grep -E "PHASE0 BUILD|error CS|Build Finished|Exiting batchmode" "out/logs/unity-$target.log" | tail -20
exit "$status"
