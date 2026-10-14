#!/bin/zsh
# Tạo file .dmg: MacPulse.app, lối tắt Applications để kéo thả, hướng dẫn mở lần đầu.
#   tools/make-dmg.sh <đường dẫn MacPulse.app> <file .dmg đầu ra>
set -euo pipefail
APP="$1"
OUT="$2"
ROOT="${0:A:h}/.."
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/MacPulse.app"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/docs/Doc-truoc-khi-mo.txt" "$STAGE/Đọc trước khi mở.txt"
rm -f "$OUT"
hdiutil create -quiet -volname "MacPulse" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 "$OUT"
echo "Đã tạo $OUT"
