#!/usr/bin/env bash
# Packages the Linux release bundle as a portable tarball and a Debian package.
# Usage: packaging/linux/package.sh <version> <output-dir>   (after `flutter build linux --release`)
set -euo pipefail

version="$1"
out="$(realpath -m "$2")"
root="$(cd "$(dirname "$0")/../.." && pwd)"
bundle="$root/build/linux/x64/release/bundle"
app_id="io.github.project614.multiplex"

if [[ ! -x "$bundle/multiplex" ]]; then
  echo "No release bundle found; run 'flutter build linux --release' first." >&2
  exit 1
fi

mkdir -p "$out"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Portable tarball: extract anywhere and run ./multiplex.
name="Multiplex-$version-linux-x64"
cp -a "$bundle" "$work/$name"
tar -C "$work" -czf "$out/$name.tar.gz" "$name"

# Debian package: the bundle goes to /opt/multiplex, with a launcher, menu entry and icon.
deb="$work/deb"
mkdir -p "$deb/DEBIAN" "$deb/opt" "$deb/usr/bin" "$deb/usr/share/applications" \
  "$deb/usr/share/icons/hicolor/512x512/apps"
cp -a "$bundle" "$deb/opt/multiplex"
ln -s /opt/multiplex/multiplex "$deb/usr/bin/multiplex"
install -m 644 "$root/packaging/linux/$app_id.desktop" "$deb/usr/share/applications/$app_id.desktop"
install -m 644 "$root/assets/icon/multiplex.png" "$deb/usr/share/icons/hicolor/512x512/apps/$app_id.png"
chmod -R u+rwX,go+rX,go-w "$deb/opt/multiplex"

# Debian orders "~" before the release, so 1.2.0-beta.1 becomes 1.2.0~beta.1.
cat > "$deb/DEBIAN/control" <<CONTROL
Package: multiplex
Version: ${version//-/\~}
Section: graphics
Priority: optional
Architecture: amd64
Maintainer: 614project <614project@users.noreply.github.com>
Depends: libgtk-3-0 | libgtk-3-0t64, libepoxy0, libstdc++6
Recommends: zenity | kdialog, xdg-utils
Installed-Size: $(du -sk "$deb/opt" | cut -f1)
Homepage: https://github.com/614project/Multiplex
Description: Batch Stable Diffusion prompt cells across WebUI and ComfyUI
 Multiplex runs many prompt cells against a Stable Diffusion WebUI (A1111)
 or ComfyUI server with shared project settings, a job queue and an image
 history per cell.
CONTROL

dpkg-deb --build --root-owner-group "$deb" "$out/$name.deb" >/dev/null
echo "Wrote $out/$name.tar.gz and $out/$name.deb"
