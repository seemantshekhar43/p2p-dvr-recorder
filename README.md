# p2p-dvr-recorder

Records a CP Plus (Dahua-family) DVR reached over InstaOn/P2P, keeping a rolling
2-day window. Tunnel code is derived from [rajpdus/cammob](https://github.com/rajpdus/cammob)
at `c83546e` (MIT), ported to Linux Swift.

## Pieces

| Piece | What |
|---|---|
| `Sources/DahuaP2P`, `DahuaRTSP` | InstaOn relay handshake, PTCP, realm tunnelling, RTSP client |
| `Sources/TunnelKit` | Local TCP forwarder (127.0.0.1) that survives tunnel reconnects |
| `nvr-tunnel` | Daemon: keeps the relay tunnel up, reconnects with backoff |
| `camtool` | Debug CLI: `probe`, `stream`, `channels`, `tunnel` |
| `deploy/bin/nvr-record` | One ffmpeg `-c copy` per channel into 30 min MKV segments |
| `deploy/bin/nvr-retention` | Deletes segments older than `RETENTION_HOURS` (48) |
| `deploy/bin/nvr-health` | Stale-segment + disk-quota check, ntfy on state change |
| `deploy/systemd/` | Units and timers for all of the above |

The STUN punch is off by default (the relay path is the verified one); `CAM_PUNCH=1` opts in.

## Build and test (Linux, via Docker)

macOS builds are not supported right now (swift-crypto's BoringSSL fails to find C++ headers
with the current Command Line Tools). Use the dev image:

    docker build -f Dockerfile.dev -t nvr-swift-dev .
    docker run --rm -v "$PWD":/src -v nvr-build:/tmp/b -w /src nvr-swift-dev swift test --scratch-path /tmp/b

Live end-to-end (needs `CAM_SERIAL` and `CAM_PASSWORD` in the environment, never on disk):

    docker run --rm -e CAM_SERIAL -e CAM_PASSWORD -v "$PWD":/src -v nvr-build:/tmp/b nvr-swift-dev /src/scripts/linux-e2e.sh
    docker run -d  -e CAM_SERIAL -e CAM_PASSWORD -v "$PWD":/src -v nvr-build:/tmp/b -v "$PWD/sandbox/soak-out":/out nvr-swift-dev /src/scripts/soak.sh 30 10

## Install (Debian 13 / Ubuntu 24.04)

    apt install ffmpeg zlib1g-dev curl      # plus a Swift 6 toolchain to build
    swift build -c release --product nvr-tunnel
    install .build/release/nvr-tunnel /usr/local/bin/
    install deploy/bin/nvr-* /usr/local/bin/
    install -d -m 700 /etc/nvr-recorder
    install -m 600 deploy/nvr-recorder.env.example /etc/nvr-recorder/env   # then fill it in
    cp deploy/systemd/* /etc/systemd/system/
    systemctl enable --now nvr-tunnel nvr-retention.timer nvr-health.timer
    for c in $(. /etc/nvr-recorder/env; echo $CHANNELS); do systemctl enable --now nvr-recorder@$c; done

All settings (channels, stream type, ports, cloud, segment length, retention, quota, ntfy) are
environment variables documented in `deploy/nvr-recorder.env.example`.

Credentials live only in `/etc/nvr-recorder/env`. Note ffmpeg takes them in the RTSP URL, so they are
visible in `ps` to local users, and `nvr-record` masks them in ffmpeg's output.
