#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p Vendor Generated
release=1.17.0-pack.10.0.0
if [[ ! -d Vendor/librime-dynamic.xcframework ]]; then
  archive=Vendor/rime.zip
  curl --retry 3 -fsSL "https://github.com/ghostflyby/librime-xcframework/releases/download/$release/librime-dynamic.xcframework.zip" -o "$archive"
  echo "5beaca3b6263e8ddc4a053eaebe4a0de2e33c2fc36056dd7fa0a8b87edb88533  $archive" | shasum -a 256 -c -
  ditto -x -k "$archive" Vendor/
fi
if [[ -f Scripts/RimeDynamicPrivacyInfo.xcprivacy && -d Vendor/librime-dynamic.xcframework ]]; then
  dst="Vendor/librime-dynamic.xcframework/macos-arm64_x86_64/RimeDynamic.framework/Versions/A/Resources/PrivacyInfo.xcprivacy"
  if [[ -d "$(dirname "$dst")" ]]; then
    cp Scripts/RimeDynamicPrivacyInfo.xcprivacy "$dst"
  fi
fi
notices=Generated/Rime/Licenses/librime
if [[ ! -f "$notices/THIRD_PARTY_NOTICES.md" ]]; then
  mkdir -p "$notices"
  base="https://github.com/ghostflyby/librime-xcframework/releases/download/$release"
  curl --retry 3 -fsSL "$base/third-party-notices.zip" -o Vendor/notices.zip
  echo "74c7e7a0ac34671903d4aca4cc0fec0187daf3dc747d01bf782bb0be703b08f1  Vendor/notices.zip" | shasum -a 256 -c -
  ditto -x -k Vendor/notices.zip "$notices"
  curl --retry 3 -fsSL "$base/LICENSE.txt" -o "$notices/LICENSE.txt"
  curl --retry 3 -fsSL "$base/THIRD_PARTY_NOTICES.md" -o "$notices/THIRD_PARTY_NOTICES.md"
fi
