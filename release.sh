#!/bin/zsh
# Phát hành MacPulse lên GitHub Releases, người dùng cũ sẽ được app tự báo và tự cập nhật.
#   ./release.sh 1.1.0
# Trước khi chạy:
#   - Thêm mục "## 1.1.0" vào CHANGELOG.md (nội dung mục này thành ghi chú phát hành) và commit mọi thay đổi.
#   - gh đã đăng nhập (gh auth login); khóa ký ở ~/.config/macpulse/update_ed25519.key.
# Có chứng chỉ Apple thì thêm: DEVELOPER_ID="Developer ID Application: …" NOTARY_PROFILE=<hồ sơ notarytool>
set -euo pipefail
cd "${0:A:h}"
VERSION="${1:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Cách dùng: ./release.sh 1.2.3"; exit 1; }
GH="$(command -v gh || echo "$HOME/.local/bin/gh")"
[ -x "$GH" ] || { echo "Chưa có gh. Xem docs/PHAT-TRIEN.md"; exit 1; }
"$GH" auth status >/dev/null 2>&1 || { echo "gh chưa đăng nhập: chạy  $GH auth login"; exit 1; }

NOTES=$(awk -v v="## $VERSION" '$0==v {f=1; next} /^## / {f=0} f' CHANGELOG.md)
[ -n "${NOTES//[[:space:]]/}" ] || { echo "Thiếu mục '## $VERSION' trong CHANGELOG.md"; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "Còn thay đổi chưa commit, hãy commit trước."; exit 1; }
git rev-parse "v$VERSION" >/dev/null 2>&1 && { echo "Tag v$VERSION đã có."; exit 1; }

# 1. Tăng phiên bản
BUILD=$(( $(plutil -extract CFBundleVersion raw Info.plist) + 1 ))
plutil -replace CFBundleShortVersionString -string "$VERSION" Info.plist
plutil -replace CFBundleVersion -string "$BUILD" Info.plist

# 2. Dựng app
./build.sh
APP=.build/MacPulse.app
mkdir -p dist
ZIP="dist/MacPulse-$VERSION.zip"
DMG="dist/MacPulse-$VERSION.dmg"
rm -f "$ZIP" "$ZIP.sig" "$DMG"

# 3. Công chứng với Apple (chỉ khi có chứng chỉ)
if [ -n "${NOTARY_PROFILE:-}" ]; then
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
fi

# 4. Gói cập nhật + chữ ký, file .dmg cho người dùng mới, mã SHA-256
ditto -c -k --keepParent "$APP" "$ZIP"
swift tools/update-key.swift sign "$ZIP" 2>/dev/null > "$ZIP.sig"
tools/make-dmg.sh "$APP" "$DMG"
if [ -n "${DEVELOPER_ID:-}" ]; then codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG"; fi
if [ -n "${NOTARY_PROFILE:-}" ]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi
(cd dist && shasum -a 256 "MacPulse-$VERSION.zip" "MacPulse-$VERSION.dmg" > "MacPulse-$VERSION.sha256")

# 5. Commit phiên bản, gắn tag, đẩy lên GitHub, tạo bản phát hành
git add Info.plist
git commit -m "Phát hành $VERSION"
git tag "v$VERSION"
git push origin HEAD "v$VERSION"
"$GH" release create "v$VERSION" "$ZIP" "$ZIP.sig" "$DMG" "dist/MacPulse-$VERSION.sha256" \
  --title "MacPulse $VERSION" --notes "$NOTES"
echo "Đã phát hành $VERSION"
