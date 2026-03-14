#!/bin/bash
set -euo pipefail

APP_PATH="$HOME/Applications/RJ45Switch.app/Contents/MacOS/RJ45Switch"
PLIST_PATH="$HOME/Library/LaunchAgents/com.rj45switch.plist"

mkdir -p "$HOME/Library/LaunchAgents"

cat > "$PLIST_PATH" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.rj45switch</string>
    <key>ProgramArguments</key>
    <array>
        <string>${APP_PATH}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
</dict>
</plist>
EOF

launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load "$PLIST_PATH"

echo "LaunchAgent installed: $PLIST_PATH"
