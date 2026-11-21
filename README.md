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

## Web viewer

`nvr-viewer` (Python 3, standard library only) serves a page with one timeline lane per channel for the selected
day. Click a lane to play from that moment, press `1`-`9` to switch camera at the same wall-clock time, `[` `]` for
the previous/next segment, arrows to skip. MKV segments are remuxed to MP4 on first request (`ffmpeg -c copy`, about
0.2 s) into a size-capped cache so browsers can play them. HEVC needs Safari or Chrome with hardware decoding; every
segment also has a download link. Half-width streams (for example 960x1080) are shown at 16:9 by default (Aspect: Auto).

It listens on `127.0.0.1:8080` with no auth by default. To reach it from other machines set `VIEWER_BIND`,
`VIEWER_USER` and `VIEWER_PASSWORD` in the env file, and put it behind a reverse proxy with TLS. Deep links look like
`/#ch=2&t=<epoch seconds>`.

## Install (Debian / Ubuntu, as root)

    # 1. Get a binary: build on any machine with Docker, for the target CPU (amd64 or arm64)
    scripts/build-release.sh amd64
    # 2. On the target host, from this checkout:
    ./install.sh --binary dist/nvr-tunnel-linux-amd64

`install.sh` installs ffmpeg and curl, the binaries, a non-root `nvr` system user, the systemd units,
and creates `/etc/nvr-recorder/env` (mode 600) from `deploy/nvr-recorder.env.example`. If the env file
has no `CAM_SERIAL` / `CAM_PASSWORD` yet it stops there: edit the file, then re-run
`./install.sh --skip-deps --binary ...`. Re-running is safe (the env file is never overwritten) and
restarts the services so a new binary takes effect. Options: `--prefix`, `--user`, `--uid` (pin the service user's uid, handy for bind mounts in unprivileged LXCs), `--env-file`,
`--skip-deps`, `--no-start`. Without `--binary` it uses `dist/` or builds with `swift build` if Swift is installed.

If you shrink `CHANNELS`, disable the old instances yourself: `systemctl disable --now nvr-recorder@N`.

All settings (device, ports, cloud, channels, stream type, storage path, segment length, retention
hours, quota, ntfy) are environment variables documented in `deploy/nvr-recorder.env.example`.

Credentials live only in `/etc/nvr-recorder/env`. ffmpeg takes them in the RTSP URL, so they are
visible in `ps` to local users, and `nvr-record` masks them in ffmpeg's output.
