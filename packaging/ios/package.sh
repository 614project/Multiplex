#!/usr/bin/env bash
# Packages the unsigned iOS release app as an .ipa for sideloading tools (AltStore, Sideloadly),
# which sign it with the user's own Apple ID.
# Usage: packaging/ios/package.sh <version> <output-dir>   (after `flutter build ios --release --no-codesign`)
set -euo pipefail

version="$1"
mkdir -p "$2"
out="$(cd "$2" && pwd)"
root="$(cd "$(dirname "$0")/../.." && pwd)"
app="$root/build/ios/iphoneos/Runner.app"

if [[ ! -d "$app" ]]; then
  echo "No release app found; run 'flutter build ios --release --no-codesign' first." >&2
  exit 1
fi

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
mkdir "$stage/Payload"
cp -R "$app" "$stage/Payload/"
ipa="$out/Multiplex-$version-ios-unsigned.ipa"
rm -f "$ipa"
(cd "$stage" && zip -qry "$ipa" Payload)
echo "Wrote $ipa"
