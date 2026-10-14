#!/bin/bash
# Cài helper điều khiển quạt. App gọi script này bằng quyền admin:
#   install-helper.sh <đường dẫn file helper> <tên người dùng> [1 = cho helper tự cập nhật, không hỏi lại mật khẩu]
set -euo pipefail
SRC="$1"
OWNER="$2"
AUTO="${3:-0}"
LABEL="com.tai.macpulse.fanhelper"
DEST="/Library/PrivilegedHelperTools/$LABEL"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
DIR="/Library/Application Support/MacPulse"

launchctl bootout "system/$LABEL" 2>/dev/null || true

install -o root -g wheel -m 755 "$SRC" "$DEST"

# Thư mục của root, riêng file yêu cầu thuộc người dùng để app ghi được.
mkdir -p "$DIR"
chown root:wheel "$DIR"
chmod 755 "$DIR"
echo auto > "$DIR/fan-request"
echo none > "$DIR/power-request"
echo none > "$DIR/helper-update-request"
chown "$OWNER" "$DIR/fan-request" "$DIR/power-request" "$DIR/helper-update-request"
chmod 644 "$DIR/fan-request" "$DIR/power-request" "$DIR/helper-update-request"
# Cờ "Luôn cho phép": file của root, app đọc được nhưng không sửa được.
if [ "$AUTO" = "1" ]; then echo 1 > "$DIR/helper-auto-update"; else rm -f "$DIR/helper-auto-update"; fi
[ -f "$DIR/helper-auto-update" ] && chown root:wheel "$DIR/helper-auto-update" && chmod 644 "$DIR/helper-auto-update"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$DEST</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>/Library/Logs/MacPulseFanHelper.log</string>
</dict></plist>
EOF
chown root:wheel "$PLIST"
chmod 644 "$PLIST"

launchctl bootstrap system "$PLIST"
echo "OK"
