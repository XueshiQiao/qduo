#!/usr/bin/env bash
#
# End-to-end check of Sources/App/AppRelaunch.swift with a sheet open: builds a
# tiny .app around it, asks for a relaunch three times, and passes only if the
# first process quit and exactly one new process started.
#
# Usage: scripts/check-relaunch.sh
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
APP="$WORK/RelaunchCheck.app"
mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>RelaunchCheck</string>
<key>CFBundleIdentifier</key><string>local.qduo.relaunch-check</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST

swiftc -O Sources/App/AppRelaunch.swift Sources/Core/FileLog.swift Sources/Core/Brand.swift \
  Tools/RelaunchCheck/main.swift -o "$APP/Contents/MacOS/RelaunchCheck"

MARKER="$WORK/marker.txt"
open -n "$APP" --args --marker "$MARKER"
sleep 6

first=$(grep -c '^first ' "$MARKER" 2>/dev/null || true)
again=$(grep -c '^relaunched ' "$MARKER" 2>/dev/null || true)
left=$(pgrep -f "$APP/Contents/MacOS/RelaunchCheck" || true)
cat "$MARKER" 2>/dev/null || true
if [ -n "$left" ]; then
  echo "FAIL: the first process did not quit (pid $left). Stop it by pid." >&2
  exit 1
fi
if [ "$first" != 1 ] || [ "$again" != 1 ]; then
  echo "FAIL: expected one first launch and exactly one relaunch, got $first and $again" >&2
  exit 1
fi
rm -rf "$WORK"
echo "PASS: quit with a sheet open, relaunched exactly once"
