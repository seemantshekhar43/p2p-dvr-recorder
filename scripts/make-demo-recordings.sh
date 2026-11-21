#!/bin/bash
# Generate fake recordings (colored test patterns) so you can try the web viewer without a DVR.
#   scripts/make-demo-recordings.sh [DIR] [CHANNELS] [MINUTES]
# Then run:  REC_DIR=DIR CHANNELS="1 2 3 4" VIEWER_CACHE_DIR=/tmp/viewer-cache python3 viewer/nvr_viewer.py
# Needs ffmpeg (with libx264). Segments are 60 s long and laid out like nvr-record's output (UTC file names).
set -euo pipefail
dir=${1:-/tmp/nvr-demo}; chans=${2:-4}; minutes=${3:-20}
now=$(date +%s); base=$(( now / 60 * 60 - minutes * 60 ))
for ch in $(seq 1 "$chans"); do
  mkdir -p "$dir/ch$ch"
  for i in $(seq 0 $(( minutes - 1 ))); do
    start=$(( base + i * 60 ))
    name=$(date -u -d "@$start" +%Y%m%d-%H%M%S 2>/dev/null || date -u -r "$start" +%Y%m%d-%H%M%S)
    ffmpeg -v error -y -f lavfi -i "testsrc2=size=640x360:rate=10:duration=60" -f lavfi -i "color=c=0x$(printf '%02x%02x%02x' $((ch*40)) $((255-ch*40)) 160):size=640x360:rate=10:duration=60" \
      -filter_complex "[0][1]blend=all_mode=overlay:all_opacity=0.35" -c:v libx264 -preset ultrafast -crf 32 -pix_fmt yuv420p "$dir/ch$ch/$name.mkv"
    touch -d "@$(( start + 60 ))" "$dir/ch$ch/$name.mkv" 2>/dev/null || touch -t "$(date -r $(( start + 60 )) +%Y%m%d%H%M.%S)" "$dir/ch$ch/$name.mkv"
  done
done
echo "wrote $(find "$dir" -name '*.mkv' | wc -l) demo segments under $dir"
