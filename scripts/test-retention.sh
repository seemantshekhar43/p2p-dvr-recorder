#!/bin/bash
# Retention behavior test (needs GNU find and touch -d, so run it on Linux, e.g. in the dev container or on the LXC).
#   scripts/test-retention.sh
set -euo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/ch1" "$T/ch2" "$T/ch3"
mk() { touch "$T/$1/$2.mkv"; [ "$3" = 0 ] || touch -d "$3 hours ago" "$T/$1/$2.mkv"; }
mk ch1 old50h 50; mk ch1 keep47h 47; mk ch1 fresh 0                        # feed alive
for x in 240 241 260 287 289 300; do mk ch2 "f${x}h" "$x"; done            # feed silent for 10 days
fail=0; check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2' want '$3'"; fail=1; fi; }
REC_DIR=$T RETENTION_HOURS=48 sh deploy/bin/nvr-retention
check "live channel keeps 47h, drops 50h" "$(ls "$T/ch1" | tr '\n' ' ')" "fresh.mkv keep47h.mkv "
check "silent channel keeps its last 48h" "$(ls "$T/ch2" | sort | tr '\n' ' ')" "f240h.mkv f241h.mkv f260h.mkv f287h.mkv "
check "empty channel is fine" "$(ls "$T/ch3" | wc -l | tr -d ' ')" "0"
REC_DIR=$T RETENTION_HOURS=24 sh deploy/bin/nvr-retention
check "override to 24h" "$(ls "$T/ch1" "$T/ch2" | grep -v '^$' | grep -v ':' | sort | tr '\n' ' ')" "f240h.mkv f241h.mkv f260h.mkv fresh.mkv "
exit $fail
