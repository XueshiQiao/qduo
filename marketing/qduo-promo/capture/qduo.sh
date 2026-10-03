#!/usr/bin/env bash
# Start / stop the QDuo-Debug build (main) on the isolated demo home.
#   qduo.sh demo <style>   quit the running QDuo-Debug, relaunch it on .home with <style>
#   qduo.sh restore        quit the demo one, relaunch QDuo-Debug normally (real config)
# Quits by exact PID, never by name pattern.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DEBUG_APP="$(cd "$HERE/../../../build" && pwd)/dd/Build/Products/Debug/QDuo-Debug.app"
# The demo runs a Release build of main signed with the team's development
# certificate (build-release.sh): unlike the ad-hoc Debug build, it carries the
# keychain group, so it can read the cloud voices' API keys.
DEMO_APP="$(cd "$HERE/../../../build" && pwd)/promo-rel/Build/Products/Release/QDuo.app"
# Only the two builds this script starts (under the repo's build/ folder): never
# the QDuo installed in /Applications, which has the same process name.
BUILD_DIR="$(cd "$HERE/../../../build" && pwd)"
quit_running() {
  for pid in $(pgrep -x QDuo-Debug || true) $(pgrep -x QDuo || true); do
    case "$(ps -p "$pid" -o comm= 2>/dev/null || true)" in
      "$BUILD_DIR"/*|"$HERE"/../../../build/*) ;;   # either spelling of the path
      *) continue ;;
    esac
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" 2>/dev/null || true; fi
  done
}
case "${1:-}" in
  demo)
    python3 "$HERE/make_home.py" "${2:?style}" >/dev/null
    quit_running
    # Started as a child of this shell, not through `open`: an ad-hoc signed Debug
    # build loses its Accessibility grant on every rebuild, and a child process is
    # judged by the permission of the terminal that started it instead.
    CFFIXED_USER_HOME="$HERE/.home" nohup "$DEMO_APP/Contents/MacOS/QDuo" >/dev/null 2>&1 &
    disown
    for _ in $(seq 100); do pgrep -x QDuo >/dev/null && break; sleep 0.1; done
    sleep 2 ;;
  restore)
    quit_running
    nohup "$DEBUG_APP/Contents/MacOS/QDuo-Debug" >/dev/null 2>&1 &
    disown ;;
  *) echo "usage: $0 demo <liquidGlass|donut|capsule> | restore" >&2; exit 2 ;;
esac
