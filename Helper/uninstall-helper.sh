#!/bin/bash
# Gỡ helper điều khiển quạt. Helper tự trả quạt về auto khi bị dừng.
set -uo pipefail
LABEL="com.tai.macpulse.fanhelper"
launchctl bootout "system/$LABEL" 2>/dev/null || true
rm -f "/Library/LaunchDaemons/$LABEL.plist" "/Library/PrivilegedHelperTools/$LABEL"
rm -rf "/Library/Application Support/MacPulse"
echo "OK"
