#!/bin/zsh
# Packages build/Aqua.app into a disk image with an Applications shortcut.
# Usage: scripts/make-dmg.sh [output.dmg]
set -euo pipefail

ROOT=${0:A:h:h}
APP="$ROOT/build/Aqua.app"
OUT=${1:-"$ROOT/build/Aqua.dmg"}
[[ -d "$APP" ]] || { echo "Build the app first: scripts/build-app.sh" >&2; exit 1; }

STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$OUT"
hdiutil create -volname "Aqua" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$OUT" >/dev/null
hdiutil verify "$OUT" >/dev/null
echo "Built $OUT"
