#!/bin/sh
# Packages flutter build linux --release into a .deb and a portable tarball.
# Run on Ubuntu after the bundle exists at build/linux/x64/release/bundle.
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
version=$(sed -n 's/^version:[[:space:]]*//p' "$root/pubspec.yaml")
marketing=${version%%+*}
bundle="$root/build/linux/x64/release/bundle"

if [ ! -x "$bundle/baocode" ]; then
  echo "No bundle at $bundle. Run: flutter build linux --release" >&2
  exit 1
fi

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

mkdir -p "$stage/opt/baocode" \
  "$stage/usr/bin" \
  "$stage/usr/share/applications" \
  "$stage/usr/share/icons/hicolor/128x128/apps" \
  "$stage/DEBIAN"

cp -a "$bundle/." "$stage/opt/baocode/"
cp "$root/assets/branding/app_icon.png" \
  "$stage/usr/share/icons/hicolor/128x128/apps/baocode.png"

cat > "$stage/usr/bin/baocode" << 'EOF'
#!/bin/sh
exec /opt/baocode/baocode "$@"
EOF
chmod 755 "$stage/usr/bin/baocode"

cat > "$stage/usr/share/applications/baocode.desktop" << 'EOF'
[Desktop Entry]
Name=BaoCode
Comment=Desktop app for Claude Code
Exec=baocode %U
Icon=baocode
Terminal=false
Type=Application
Categories=Development;
StartupWMClass=dev.baocode.desktop
EOF

# libgtk-3-0 is what the engine links. libblkid1 and liblzma5 are the
# extra libraries Flutter's Linux bundle expects on the system.
cat > "$stage/DEBIAN/control" << EOF
Package: baocode
Version: ${marketing}
Section: devel
Priority: optional
Architecture: amd64
Depends: libgtk-3-0, libblkid1, liblzma5
Maintainer: BaoCode <noreply@baocode.dev>
Description: BaoCode desktop for Ubuntu
 Flutter desktop UI for Claude Code. Window stays on this machine.
EOF

out="$root/build/installers"
mkdir -p "$out"
dpkg-deb --build --root-owner-group "$stage" \
  "$out/BaoCode-${marketing}-linux-amd64.deb"
tar -C "$bundle" -czf "$out/BaoCode-${marketing}-linux-amd64.tar.gz" .
echo "Wrote $out/BaoCode-${marketing}-linux-amd64.deb"
echo "Wrote $out/BaoCode-${marketing}-linux-amd64.tar.gz"
