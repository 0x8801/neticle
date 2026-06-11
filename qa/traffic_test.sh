#!/bin/zsh
# QA: generate ~10 s of download traffic and sample Neticle's published state
# before, during, and after. PASS criteria checked by the caller:
#   - downMbps during >> baseline
#   - "curl" appears in top consumers during the download
set -u
STATE=/tmp/neticle-state.json

show_state() {
    echo "--- $1 ---"
    /usr/bin/python3 - <<'PY'
import json, time
s = json.load(open("/tmp/neticle-state.json"))
print("age_s=%.1f  title=%r" % (time.time() - s["updatedAt"], s["title"]))
print("total: down=%.2f Mbps up=%.2f Mbps  (window=%ss)" % (s["downMbps"], s["upMbps"], s["windowSeconds"]))
for line in s["menuLines"]:
    print("menu | " + line)
PY
}

show_state baseline
curl -s -o /dev/null --max-time 12 "https://speed.cloudflare.com/__down?bytes=500000000" &
CURL=$!
sleep 5
show_state "during t+5s"
sleep 4
show_state "during t+9s"
wait $CURL 2>/dev/null
sleep 4
show_state "after"
