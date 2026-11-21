#!/bin/sh
# Soak + forced-reconnect test, run inside the dev container (no systemd there,
# so tiny restart loops stand in for Restart=always).
#   soak.sh <minutes> <kill-tunnel-at-minute>
set -u
MIN="${1:-45}"; KILL_AT="${2:-10}"
export REC_DIR=/out/rec NVR_LISTEN=1554 SEGMENT_SECONDS=300 CHANNELS="1 2 3 4 5 6" STATE_DIR=/tmp/h STALE_SECONDS=420
export PATH=/src/deploy/bin:/tmp/b/debug:$PATH
mkdir -p "$REC_DIR" /out/logs
swift build --scratch-path /tmp/b 2>&1 | tail -1
loop() { name=$1; shift; while :; do "$@" >>"/out/logs/$name.log" 2>&1; echo "$(date +%T) $name exited $?" >>/out/logs/events.log; sleep 5; done; }
loop tunnel nvr-tunnel &
sleep 10
for c in 1 2 3 4 5 6; do loop ch$c nvr-record $c & done
t=0
while [ $t -lt $((MIN * 60)) ]; do
  sleep 60; t=$((t + 60))
  echo "$(date +%T) min=$((t / 60)) $(nvr-health) cpu/rss: $(ps -eo comm,rss,pcpu | awk '/nvr-tunnel|ffmpeg/{r[$1]+=$2;c[$1]+=$3} END{for(k in r) printf "%s=%dMB/%.1f%% ", k, r[k]/1024, c[k]}')" >>/out/logs/health.log
  if [ $((t / 60)) -eq "$KILL_AT" ]; then echo "$(date +%T) KILLING tunnel" >>/out/logs/events.log; pkill -x nvr-tunnel; fi
done
echo "$(date +%T) done" >>/out/logs/events.log
pkill -f nvr-record; pkill -x nvr-tunnel; kill 0
