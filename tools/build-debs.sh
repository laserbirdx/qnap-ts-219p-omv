#!/bin/sh
# Build qnap-ts219p-boot_*.deb and openmediavault-qnap-ts219p_*.deb
set -e
HERE=$(cd "$(dirname "$0")/.." && pwd)
DIST="$HERE/dist"
mkdir -p "$DIST"

for pkg in qnap-ts219p-boot openmediavault-qnap-ts219p; do
    SRC="$HERE/packages/$pkg"
    VER=$(awk -F': *' '$1=="Version"{print $2}' "$SRC/DEBIAN/control")
    ARCH=$(awk -F': *' '$1=="Architecture"{print $2}' "$SRC/DEBIAN/control")
    OUT="$DIST/${pkg}_${VER}_${ARCH}.deb"
    dpkg-deb --root-owner-group -Zxz -b "$SRC" "$OUT"
done
ls -lh "$DIST"/*.deb
