#!/bin/sh
cd /src
swift build --scratch-path /tmp/b --product camtool 2>&1 | tail -1
/tmp/b/debug/camtool tunnel "$CAM_SERIAL" -u admin -l 1554 >/tmp/tunnel.log 2>&1 &
TP=$!
sleep 8
for c in 1 2 3 4 5 6; do
  echo "== ch$c"
  ffprobe -v error -rtsp_transport tcp -show_entries stream=codec_name,width,height -of compact "rtsp://admin:$CAM_PASSWORD@127.0.0.1:1554/cam/realmonitor?channel=$c&subtype=0" 2>&1 | head -3
done
ffmpeg -v error -rtsp_transport tcp -i "rtsp://admin:$CAM_PASSWORD@127.0.0.1:1554/cam/realmonitor?channel=1&subtype=0" -c copy -t 20 -y /tmp/t.mkv && ffprobe -v error -show_entries format=duration,bit_rate -of compact /tmp/t.mkv
kill $TP; head -5 /tmp/tunnel.log
