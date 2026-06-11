#!/bin/zsh
# QA: sustained ~10 s download with per-second sampling of Neticle's state.
# Prints curl's own transfer stats at the end so the meter can be checked
# against ground truth.
set -u

curl -s -o /dev/null \
     -w 'curl#1: code=%{http_code} size=%{size_download}B time=%{time_total}s avg=%{speed_download}B/s\n' \
     --max-time 10 "https://ash-speed.hetzner.com/1GB.bin" &
CURL=$!
curl -s -o /dev/null \
     -w 'curl#2: code=%{http_code} size=%{size_download}B time=%{time_total}s avg=%{speed_download}B/s\n' \
     --max-time 10 "https://proof.ovh.net/files/1Gb.dat" &
CURL2=$!

for i in $(seq 1 13); do
    /usr/bin/python3 - "$i" <<'PY'
import json, sys, time
s = json.load(open("/tmp/neticle-state.json"))
top = "  ||  ".join(l for l in s["menuLines"][:3])
print("t+%02ds  title=%-22r  %s" % (int(sys.argv[1]), s["title"], top))
PY
    sleep 1
done
wait $CURL $CURL2 2>/dev/null
