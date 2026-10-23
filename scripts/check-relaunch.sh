#!/usr/bin/env bash
#
# End-to-end check of Sources/App/AppRelaunch.swift with a sheet open: builds a
# tiny .app around it, asks for a relaunch three times, and passes only if the
# first process quit and exactly one new process started.
#
# Usage: scripts/check-relaunch.sh
set -euo pipefail
cd "$(dirname "$0")/.."

# pwd -P: processes see /private/var/..., mktemp prints /var/...
WORK=$(cd "$(mktemp -d)" && pwd -P)
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

# On any exit: stop what is left of the test app, by pid, and only processes
# running from this run's own folder; then remove the folder.
# Waiting relaunch shells go first: stopping the app before them would set
# them off.
cleanup() {
  for pid in $(pgrep -f "$APP" || true); do
    case "$(ps -o command= -p "$pid" 2>/dev/null)" in
      */bin/sh*"$APP"*) kill "$pid" 2>/dev/null || true ;;
    esac
  done
  for pid in $(pgrep -f "$APP/Contents/MacOS/RelaunchCheck" || true); do
    case "$(ps -o command= -p "$pid" 2>/dev/null)" in
      "$APP/Contents/MacOS/RelaunchCheck"*) kill "$pid" 2>/dev/null || true ;;
    esac
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

open -n "$APP" --args --marker "$MARKER"

# Wait up to 20 s for the first launch to quit and one relaunch to report.
for _ in $(seq 1 200); do
  if grep -q '^relaunched ' "$MARKER" 2>/dev/null; then break; fi
  sleep 0.1
done
sleep 1   # time for a second, unwanted relaunch to show up

cat "$MARKER" 2>/dev/null || true
first_pid=$(sed -n 's/^first \([0-9]*\) .*/\1/p' "$MARKER" 2>/dev/null || true)
if ! grep -q '^first [0-9]* sheet=true$' "$MARKER" 2>/dev/null; then
  echo "FAIL: the test did not run with a sheet open" >&2
  exit 1
fi
if [ -n "$first_pid" ] && ps -p "$first_pid" >/dev/null; then
  echo "FAIL: the first process ($first_pid) did not quit" >&2
  exit 1
fi
again=$(grep -c '^relaunched ' "$MARKER" || true)
if [ "$again" != 1 ]; then
  echo "FAIL: expected exactly one relaunch, got $again" >&2
  exit 1
fi
echo "PASS: quit with a sheet open, relaunched exactly once"
