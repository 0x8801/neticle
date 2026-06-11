#!/bin/zsh
# QA: (re)start Neticle.app and verify it is alive and publishing state.
set -u
cd "$(dirname "$0")/.."

if pkill -x Neticle 2>/dev/null; then
    echo "• killed old instance"
    sleep 1
fi
rm -f /tmp/neticle-state.json

open "$PWD/Neticle.app" || { echo "FAIL: open failed"; exit 1; }
sleep 6

PID=$(pgrep -x Neticle || true)
if [[ -z "$PID" ]]; then
    echo "FAIL: Neticle not running after launch"
    exit 1
fi
echo "• RUNNING pid=$PID"

if [[ ! -f /tmp/neticle-state.json ]]; then
    echo "FAIL: no state file written"
    exit 1
fi
echo "• state file:"
cat /tmp/neticle-state.json
echo
echo "• resource usage:"
ps -o %cpu,%mem,rss,etime -p "$PID"
