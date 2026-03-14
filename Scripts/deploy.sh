#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BINARY_SRC="$PROJECT_DIR/.build/release/RJ45Switch"
BINARY_DST="/usr/local/bin/RJ45Switch"
PLIST_PATH="$HOME/Library/LaunchAgents/com.rj45switch.app.plist"

# Build release
echo "Building release..."
cd "$PROJECT_DIR"
swift build -c release

# Copy binary
echo "Copying binary to $BINARY_DST (requires sudo)..."
sudo cp "$BINARY_SRC" "$BINARY_DST"

# Ensure LaunchAgents directory exists
mkdir -p "$HOME/Library/LaunchAgents"

# Create plist
cat > "$PLIST_PATH" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.rj45switch.app</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/RJ45Switch</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
</dict>
</plist>
EOF

# Load LaunchAgent
launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load "$PLIST_PATH"

echo "Deployed successfully."
echo "Verify with: launchctl list | grep rj45"
