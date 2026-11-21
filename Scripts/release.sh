#!/usr/bin/env bash
# Release build for capy-companion (macOS).
# Archives capy-companion, signs with Developer ID, notarizes, and writes
# dist/capy-companion.dmg plus the Sparkle update archive dist/capy-companion-<version>.zip.
set -euo pipefail
mode=${1:-mac}
[[ $mode == mac ]] || { echo "Expected mac, got: $mode" >&2; exit 2; }
source "$(dirname "$0")/build-env.sh"

team=${CAPY_DEVELOPMENT_TEAM:-${RIME_DEVELOPMENT_TEAM:-}}
[[ -n $team ]] || { echo "Set CAPY_DEVELOPMENT_TEAM to your Apple Developer Team ID." >&2; exit 1; }
version=${CAPY_VERSION:-$(sed -n 's/^ *MARKETING_VERSION: *"*\([^"]*\)"*$/\1/p' project.yml | head -n 1)}
build=${CAPY_BUILD_NUMBER:-$(date -u +%y%m%d%H%M)}
[[ $version =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || { echo "Version must be numeric (e.g. 1.2.3): $version" >&2; exit 1; }
[[ $build =~ ^[0-9]+$ ]] || { echo "Build number must be numeric: $build" >&2; exit 1; }

auth=()
if [[ -n ${ASC_KEY_ID:-} ]]; then
  : "${ASC_ISSUER_ID:?ASC_ISSUER_ID is required with ASC_KEY_ID}" "${ASC_KEY_PATH:?ASC_KEY_PATH is required with ASC_KEY_ID}"
  auth=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

scheme=CapyCompanion; destination='generic/platform=macOS'; method=developer-id; export_destination=export
if [[ -n ${CAPY_UPDATE_PUBLIC_KEY:-} && -z ${CAPY_UPDATE_FEED_URL:-} && -n ${GITHUB_REPOSITORY:-} ]]; then
  export CAPY_UPDATE_FEED_URL="https://github.com/$GITHUB_REPOSITORY/releases/latest/download/appcast.xml"
fi
if [[ -n ${CAPY_UPDATE_PUBLIC_KEY:-} && -z ${CAPY_UPDATE_FEED_URL:-} ]]; then
  echo "CAPY_UPDATE_FEED_URL is required when CAPY_UPDATE_PUBLIC_KEY is set." >&2
  exit 1
fi
[[ -n ${CAPY_UPDATE_PUBLIC_KEY:-} ]] || echo "warning: CAPY_UPDATE_PUBLIC_KEY is not set; this build will not auto-update." >&2
if [[ -n ${ASC_KEY_ID:-} ]]; then
  notary=(--key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")
elif [[ -n ${CAPY_NOTARY_PROFILE:-} ]]; then
  notary=(--keychain-profile "$CAPY_NOTARY_PROFILE")
else
  echo "Set ASC_KEY_ID/ASC_ISSUER_ID/ASC_KEY_PATH or CAPY_NOTARY_PROFILE for notarization." >&2
  exit 1
fi

out="$PWD/build/release-mac"
rm -rf "$out"
mkdir -p "$out"
settings=(DEVELOPMENT_TEAM="$team" MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build")
for var in CAPY_SYNC_SERVER CAPY_ENABLE_SERVER_SYNC CAPY_MAC_BUNDLE_ID CAPY_BUNDLE_ID_SUFFIX CAPY_APP_GROUP CAPY_ICLOUD_CONTAINER CAPY_UPDATE_FEED_URL CAPY_UPDATE_PUBLIC_KEY; do
  if [[ -n ${!var:-} ]]; then
    settings+=("$var=${!var}")
  fi
done
signing_style=automatic
provisioning_flags=(-allowProvisioningUpdates)
if [[ -n ${CAPY_MAC_PROFILE:-} ]]; then
  [[ -f $CAPY_MAC_PROFILE ]] || { echo "Provisioning profile not found: $CAPY_MAC_PROFILE" >&2; exit 1; }
  security cms -D -i "$CAPY_MAC_PROFILE" > "$out/profile.plist"
  signing_style=manual
  provisioning_flags=()
  settings+=(CODE_SIGNING_ALLOWED=NO)
fi

echo "Releasing $scheme $version ($build)"
xcodebuild archive -project CapyCompanion.xcodeproj -scheme "$scheme" -configuration Release \
  -destination "$destination" -derivedDataPath "$out/DerivedData" -archivePath "$out/$scheme.xcarchive" \
  ${provisioning_flags[@]+"${provisioning_flags[@]}"} ${auth[@]+"${auth[@]}"} "${settings[@]}"

if [[ $signing_style == manual ]]; then
  app="$out/export/capy-companion.app"
  mkdir -p "$out/export"
  ditto "$out/$scheme.xcarchive/Products/Applications/capy-companion.app" "$app"
  cp "$CAPY_MAC_PROFILE" "$app/Contents/embedded.provisionprofile"

  bundle_id=${CAPY_MAC_BUNDLE_ID:-com.capyinput.companion}
  icloud_container=${CAPY_ICLOUD_CONTAINER:-iCloud.com.capyinput.keyboard}
  cat > "$out/entitlements.plist" <<ENTITLEMENTS
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.application-identifier</key><string>$team.$bundle_id</string>
  <key>com.apple.developer.team-identifier</key><string>$team</string>
  <key>com.apple.developer.icloud-container-identifiers</key><array><string>$icloud_container</string></array>
  <key>com.apple.developer.icloud-services</key><array><string>CloudKit</string></array>
  <key>com.apple.developer.icloud-container-environment</key><string>Production</string>
</dict>
</plist>
ENTITLEMENTS

  sign_identity=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:.*\)".*/\1/p' | head -n 1)
  [[ -n $sign_identity ]] || { echo "No Developer ID Application signing identity found." >&2; exit 1; }
  while IFS= read -r -d '' bin; do
    if file -b "$bin" | grep -q "Mach-O universal binary" && lipo -archs "$bin" 2>/dev/null | grep -qw arm64; then
      lipo -thin arm64 "$bin" -output "$bin.arm64" && mv "$bin.arm64" "$bin"
    fi
  done < <(find "$app/Contents/Frameworks" -type f -perm +111 -print0 2>/dev/null)
  if [[ -d "$app/Contents/Frameworks/RimeDynamic.framework" ]]; then
    codesign --force --deep --options runtime --timestamp --sign "$sign_identity" "$app/Contents/Frameworks/RimeDynamic.framework"
  fi
  if [[ -d "$app/Contents/Frameworks/Sparkle.framework" ]]; then
    codesign --force --deep --options runtime --timestamp \
      --preserve-metadata=identifier,entitlements,requirements,flags \
      --sign "$sign_identity" "$app/Contents/Frameworks/Sparkle.framework"
  fi
  codesign --force --options runtime --timestamp --entitlements "$out/entitlements.plist" --sign "$sign_identity" "$app"
else
  cat > "$out/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>$method</string>
  <key>destination</key><string>$export_destination</string>
  <key>teamID</key><string>$team</string>
  <key>signingStyle</key><string>automatic</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>uploadSymbols</key><true/>
</dict>
</plist>
PLIST
  xcodebuild -exportArchive -archivePath "$out/$scheme.xcarchive" -exportOptionsPlist "$out/ExportOptions.plist" \
    -exportPath "$out/export" ${provisioning_flags[@]+"${provisioning_flags[@]}"} ${auth[@]+"${auth[@]}"}
fi

app="$out/export/capy-companion.app"
codesign --verify --deep --strict --verbose=2 "$app"
ditto -c -k --keepParent "$app" "$out/notarize.zip"
xcrun notarytool submit "$out/notarize.zip" "${notary[@]}" --wait
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=4 "$app"

mkdir -p dist
zip="dist/capy-companion-$version.zip"
dmg="dist/capy-companion.dmg"
rm -f "$zip" "$dmg"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
staging="$out/dmg"
mkdir -p "$staging"
ditto "$app" "$staging/capy-companion.app"
ln -s /Applications "$staging/Applications"
hdiutil create -volname "capy-companion $version" -srcfolder "$staging" -ov -format UDZO "$dmg" >/dev/null
xcrun notarytool submit "$dmg" "${notary[@]}" --wait
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
echo "Release artifacts ready: $dmg $zip"
