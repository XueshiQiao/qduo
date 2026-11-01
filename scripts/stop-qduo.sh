#!/usr/bin/env bash
#
# Stop every running QDuo, whichever build it is: the installed release
# (QDuo.app) AND the Debug build (QDuo-Debug.app). Both register the same global
# hotkeys, so leaving one alive next to the other makes every hotkey fire twice
# (two rings at once).
#
# Never kills by name. For each candidate PID it reads the executable path and only
# stops it if that path ends in `.app/Contents/MacOS/<name>` for one of the two
# names above. Then `kill <pid>` (normal quit), wait up to ~5s, and `kill -9 <pid>`
# only if that PID is still alive.
#
# Usage: scripts/stop-qduo.sh
set -euo pipefail
cd "$(dirname "$0")/.."

# Names are read out of project.yml, like run.sh does.
DEBUG_NAME=$(awk '/^        Debug:/{f=1} f && /PRODUCT_NAME:/{print $2; exit}' project.yml)
RELEASE_NAME=$(awk '/^name:/ {print $NF; exit}' project.yml)
: "${DEBUG_NAME:?could not read the Debug PRODUCT_NAME from project.yml}"
: "${RELEASE_NAME:?could not read the app name from project.yml}"

pids=()
for name in "$RELEASE_NAME" "$DEBUG_NAME"; do
  for pid in $(pgrep -x "$name" || true); do
    exe=$(ps -o comm= -p "$pid" 2>/dev/null || true)
    case "$exe" in
      *".app/Contents/MacOS/$name")
        echo "› stopping pid $pid ($exe)"
        pids+=("$pid") ;;
      *) echo "› skipping pid $pid: unexpected path ($exe)" ;;
    esac
  done
done

[ ${#pids[@]} -gt 0 ] || { echo "› no QDuo running"; exit 0; }

for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done

for pid in "${pids[@]}"; do
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.5
  done
  if kill -0 "$pid" 2>/dev/null; then
    echo "› pid $pid ignored the quit, sending kill -9"
    kill -9 "$pid" 2>/dev/null || true
    # The process table entry goes away a moment after kill -9, not instantly.
    for _ in 1 2 3 4 5 6; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.5
    done
  fi
done

for pid in "${pids[@]}"; do
  if kill -0 "$pid" 2>/dev/null; then echo "pid $pid is still alive" >&2; exit 1; fi
done
echo "› all stopped"
