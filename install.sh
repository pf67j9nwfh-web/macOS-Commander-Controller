#!/bin/sh
# Install macOS Commander Controller as a background LaunchAgent in this user's GUI session. Run on the Mac itself (or over ssh).
# Afterwards: ssh user@host nc -U ~/.mac-commander.sock   speaks MCP (one JSON message per line).
set -e
D="$HOME/mac-commander"; L=local.mac-commander; P="$HOME/Library/LaunchAgents/$L.plist"
mkdir -p "$D" "$HOME/Library/LaunchAgents"
cp "$(dirname "$0")/mac-commander.py" "$D/"
cat > "$P" <<PL
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>Label</key><string>$L</string>
<key>ProgramArguments</key><array><string>/usr/bin/python3</string><string>$D/mac-commander.py</string><string>--socket</string><string>$HOME/.mac-commander.sock</string></array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>LimitLoadToSessionType</key><string>Aqua</string>
<key>StandardErrorPath</key><string>$D/log.txt</string></dict></plist>
PL
launchctl bootout gui/$(id -u)/$L 2>/dev/null || true
launchctl bootstrap gui/$(id -u) "$P"
echo installed; echo "Grant Accessibility (and Screen Recording if asked) to python3 in System Settings > Privacy & Security."
