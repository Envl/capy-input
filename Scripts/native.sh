#!/usr/bin/env bash
set -euo pipefail
mode=${1:?expected mac or run}
source "$(dirname "$0")/build-env.sh"
case "$mode" in
  mac|run) scheme=CapyCompanion; destination='platform=macOS,arch=arm64' ;;
  *) echo "Expected mac or run, got: $mode" >&2; exit 2 ;;
esac
args=(-scheme "$scheme" -project CapyCompanion.xcodeproj -configuration Debug -derivedDataPath "build/$mode")
for var in CAPY_SYNC_SERVER CAPY_ENABLE_SERVER_SYNC CAPY_MAC_BUNDLE_ID CAPY_BUNDLE_ID_SUFFIX CAPY_APP_GROUP CAPY_ICLOUD_CONTAINER; do
  if [[ -n ${!var:-} ]]; then
    args+=("$var=${!var}")
  fi
done
team=${CAPY_DEVELOPMENT_TEAM:-${RIME_DEVELOPMENT_TEAM:-}}
if [[ -n "$team" ]]; then
  xcodebuild "${args[@]}" -destination "$destination" -allowProvisioningUpdates DEVELOPMENT_TEAM="$team" build
else
  xcodebuild "${args[@]}" -destination "$destination" CODE_SIGNING_ALLOWED=NO build
fi
if [[ $mode == run ]]; then
  app="$PWD/build/run/Build/Products/Debug/capy-companion.app"
  xcrun swift Scripts/stop-mac-build.swift "$app"
  open "$app"
fi
