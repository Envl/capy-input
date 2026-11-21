# Sourced by native.sh and release.sh: loads .env, prepares librime, and generates CapyCompanion.xcodeproj.
cd "$(dirname "${BASH_SOURCE[0]}")/.."
if [[ -f .env ]]; then
  while IFS='=' read -r key value; do
    [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
    key=${key//[[:space:]]/}
    value=${value%$'\r'}
    value=${value#\"}; value=${value%\"}
    value=${value#\'}; value=${value%\'}
    [[ -z "${!key:-}" ]] && export "$key=$value"
  done < .env
fi

if [[ -z ${CAPY_SYNC_SERVER+x} ]]; then
  CAPY_SYNC_SERVER="https://capy.lumik.space"
fi

if [[ ! -d Vendor/librime-dynamic.xcframework || ! -f Generated/Rime/Licenses/librime/THIRD_PARTY_NOTICES.md ]]; then
  bash Scripts/prepare.sh
fi
xcodegen generate
