#!/usr/bin/env bash
# Packages the macOS release app as a drag-to-Applications disk image.
# Usage: packaging/macos/package.sh <version> <output-dir>   (after `flutter build macos --release`)
set -euo pipefail

version="$1"
mkdir -p "$2"
out="$(cd "$2" && pwd)"
root="$(cd "$(dirname "$0")/../.." && pwd)"
app="$root/build/macos/Build/Products/Release/Multiplex.app"

if [[ ! -d "$app" ]]; then
  echo "No release app found; run 'flutter build macos --release' first." >&2
  exit 1
fi

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
cp -R "$app" "$stage/"
ln -s /Applications "$stage/Applications"

dmg="$out/Multiplex-$version-macos.dmg"
# hdiutil occasionally fails with "Resource busy" on CI machines; retry a few times.
for attempt in 1 2 3 4 5; do
  if hdiutil create -volname "Multiplex" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$dmg"; then
    echo "Wrote $dmg"
    exit 0
  fi
  sleep $((attempt * 5))
done
echo "hdiutil failed to create $dmg" >&2
exit 1
