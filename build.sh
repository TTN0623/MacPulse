#!/bin/zsh
# Dựng MacPulse.app vào .build/ (chỉ chip Apple, macOS 14 trở lên).
#   ./build.sh            dựng .build/MacPulse.app
#   ./build.sh --install  dựng rồi cài vào ~/Applications và mở lại
# Có chứng chỉ Apple thì ký thật: DEVELOPER_ID="Developer ID Application: Tên (TEAMID)" ./build.sh
set -e
cd "${0:A:h}"
BUILD="$PWD/.build"
APP="$BUILD/MacPulse.app"
TARGET="arm64-apple-macos14.0"
mkdir -p "$BUILD"
swiftc -O -target $TARGET Sources/*.swift -o "$BUILD/MacPulse"
swiftc -O -target $TARGET Sources/SMC.swift Helper/main.swift -o "$BUILD/MacPulseFanHelper"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/MacPulse" "$APP/Contents/MacOS/MacPulse"
cp "$BUILD/MacPulseFanHelper" Helper/install-helper.sh Helper/uninstall-helper.sh "$APP/Contents/Resources/"
cp AppIcon.icns docs/nhiet-do-m4pro.md "$APP/Contents/Resources/"
# Ký helper bằng khóa cập nhật, để helper đang chạy (root) tự thay bản mới mà không hỏi mật khẩu.
if [ -f "$HOME/.config/macpulse/update_ed25519.key" ]; then
  swift tools/update-key.swift sign "$BUILD/MacPulseFanHelper" 2>/dev/null > "$APP/Contents/Resources/MacPulseFanHelper.sig"
else
  echo "Chưa có khóa ký (~/.config/macpulse/update_ed25519.key): helper sẽ không tự cập nhật được."
fi
cp Info.plist "$APP/Contents/Info.plist"

if [ -n "${DEVELOPER_ID:-}" ]; then
  # Ký thật + hardened runtime để notarize được; helper ký trước, app ký sau.
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP/Contents/Resources/MacPulseFanHelper"
  codesign --force --options runtime --timestamp --entitlements MacPulse.entitlements --sign "$DEVELOPER_ID" "$APP"
else
  codesign --force --deep --sign - "$APP"
fi
codesign --verify --deep "$APP"
echo "Đã dựng $APP ($(plutil -extract CFBundleShortVersionString raw Info.plist))"

if [ "${1:-}" = "--install" ]; then
  DEST="$HOME/Applications/MacPulse.app"
  pkill -x MacPulse 2>/dev/null && sleep 1 || true
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  open "$DEST"
  echo "Đã cài và mở $DEST"
fi
