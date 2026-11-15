#!/bin/sh
# Build macOS Commander Controller and install it as a background LaunchAgent in this user's GUI session.
# Needs the Xcode Command Line Tools (clang). Run on the Mac itself, or over ssh.
# Afterwards:  ssh user@host nc -U .mac-commander.sock   speaks MCP (one JSON message per line).
set -e
D="$HOME/mac-commander"; L=local.mac-commander; P="$HOME/Library/LaunchAgents/$L.plist"; BIN="$D/macos-commander-controller"
mkdir -p "$D" "$HOME/Library/LaunchAgents"
clang -O2 -fobjc-arc -framework Foundation -framework ApplicationServices -o "$BIN.new" "$(dirname "$0")/macos-commander-controller.m"
cat > "$P" <<PL
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>Label</key><string>$L</string>
<key>ProgramArguments</key><array><string>$BIN</string><string>--socket</string><string>$HOME/.mac-commander.sock</string></array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>LimitLoadToSessionType</key><string>Aqua</string>
<key>StandardErrorPath</key><string>$D/log.txt</string></dict></plist>
PL
launchctl bootout gui/$(id -u)/$L 2>/dev/null || true
mv -f "$BIN.new" "$BIN"; rm -f "$D/mac-commander.py"
launchctl bootstrap gui/$(id -u) "$P"
echo "installed $BIN"
"$BIN" --check
echo "If anything says NOT granted: $BIN --request   (then switch on $BIN in System Settings > Privacy & Security > Accessibility and Screen & System Audio Recording)"
