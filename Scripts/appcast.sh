#!/usr/bin/env bash
# Writes dist/appcast.xml for dist/capy-companion-<version>.zip, signed with the Sparkle EdDSA
# private key in SPARKLE_ED_PRIVATE_KEY. Earlier entries are carried over from the latest release.
# Usage: Scripts/appcast.sh --version <version> --tag <tag> --repository <owner/repo>
set -euo pipefail
cd "$(dirname "$0")/.."
version=""; tag=""; repository=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) version=${2:?}; shift 2 ;;
    --tag) tag=${2:?}; shift 2 ;;
    --repository) repository=${2:?}; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -n $version && -n $tag && -n $repository ]] || { echo "Usage: $0 --version <v> --tag <tag> --repository <owner/repo>" >&2; exit 2; }
: "${SPARKLE_ED_PRIVATE_KEY:?SPARKLE_ED_PRIVATE_KEY is required}"

archive="dist/capy-companion-$version.zip"
[[ -f $archive ]] || { echo "Update archive not found: $archive" >&2; exit 1; }
tools=${SPARKLE_TOOLS_DIR:-$(dirname "$(find build/release-mac -path '*/Sparkle/bin/generate_appcast' -type f 2>/dev/null | head -n 1)")}
[[ -x $tools/generate_appcast ]] || { echo "generate_appcast not found; set SPARKLE_TOOLS_DIR." >&2; exit 1; }

updates=$(mktemp -d "${TMPDIR:-/tmp}/capy-appcast.XXXXXX")
trap 'rm -rf "$updates"' EXIT
cp "$archive" "$updates/"
curl -fsSL "https://github.com/$repository/releases/latest/download/appcast.xml" -o "$updates/appcast.xml" 2>/dev/null || true
printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$tools/generate_appcast" \
  --ed-key-file - \
  --download-url-prefix "https://github.com/$repository/releases/download/$tag/" \
  --maximum-deltas 0 \
  "$updates"
cp "$updates/appcast.xml" dist/appcast.xml
xmllint --noout dist/appcast.xml
echo "Sparkle appcast ready: dist/appcast.xml"
