# p2p-dvr-recorder

Record a **CP Plus / Dahua-family DVR that you can only reach through the vendor's P2P cloud** (the "scan the QR code in the app" kind, InstaOn or Easy4ip) onto **your own disk**, keep a rolling window of footage, and **watch it back in a browser**.

Those DVRs usually do not expose RTSP to the internet, and they do not let a normal NVR program log in over P2P. This project does the P2P part for you: it opens the vendor's relay tunnel, exposes the DVR's ordinary RTSP port on `127.0.0.1`, and records it with plain `ffmpeg -c copy` (no re-encoding, so it is cheap on CPU).

- Records every channel of the DVR over **one** tunnel, as 30 minute MKV segments
- Keeps the last N hours per channel, alerts you (ntfy) when a camera goes quiet or the disk fills up
- Web viewer: 1, 4 or 8 camera layouts, synchronized playback across cameras, clickable timeline, click a camera to focus it
- Runs as plain systemd services on Debian/Ubuntu (a Proxmox LXC works well), or just try the viewer on demo footage first
- Every setting is an environment variable

> **Status:** built and used on one DVR (CP Plus, HEVC, 6 cameras, InstaOn). The tunnel code is a Linux port of [rajpdus/cammob](https://github.com/rajpdus/cammob) (MIT), which reports working on other CP Plus and Dahua firmware. Reports from other devices are welcome.

---

## How it works

```
DVR (remote site, 1 to 8+ cameras, one P2P serial)
   |   vendor P2P cloud: lookup, then a relay (UDP)
   v
nvr-tunnel                 one relay session, DVR's RTSP port appears on 127.0.0.1:1554
   |
   v
nvr-record (one ffmpeg per channel)      ffmpeg -c copy, 30 minute segments
   |
   v
/mnt/recordings/chN/YYYYmmdd-HHMMSS.mkv            file names are UTC
   |                         |                          |
   v                         v                          v
nvr-retention (hourly)    nvr-health (every minute)    nvr-viewer (web UI, port 8080)
keeps last N hours        stale camera / disk alerts   remuxes MKV to MP4 on demand
```

## What you need

| | |
|---|---|
| A DVR | CP Plus / Dahua-family with P2P (InstaOn or Easy4ip) enabled, and its **P2P serial** (also called device ID: shown in the DVR's network or P2P menu, in the vendor app, and encoded in the QR code) plus the DVR login (usually `admin`) |
| A host | Debian 13 or Ubuntu 24.04 (or newer), systemd, x86_64 (tested) or arm64 (builds and runs in a container, lightly tested). 1 vCPU and 1 GB RAM is plenty: 6 cameras use about 0.3 GB and a few percent CPU. A Proxmox LXC works well. |
| Disk | See [Storage planning](#storage-planning). Put recordings on a big disk, not the system disk. |
| A binary | Built by CI or by you (below). The tunnel is one binary, `nvr-tunnel`, with the Swift runtime linked in. Prebuilt binaries are built on Ubuntu 24.04, so on an **older distribution** (Debian 12, Ubuntu 22.04) build it on that host instead. |
| Optional | An [ntfy](https://ntfy.sh) topic for alerts, a reverse proxy for HTTPS |

Check the cameras are on first: the vendor app should show live video from outside your home network.

## Quick start

```bash
git clone https://github.com/seemantshekhar43/p2p-dvr-recorder.git
cd p2p-dvr-recorder
```

**1. Get the `nvr-tunnel` binary** (pick one):

- **Build it with Docker** on any machine, for the CPU of the target host (`amd64` for most PCs and servers, `arm64` for a Raspberry Pi):
  ```bash
  scripts/build-release.sh amd64        # writes dist/nvr-tunnel-linux-amd64
  ```
- **Download it** from the GitHub Actions run or Release of this repo (artifact `nvr-tunnel-linux-amd64`).
- **Build it on the host** if a Swift 6 toolchain is installed ([swift.org/install](https://www.swift.org/install/linux/)): `install.sh` does this automatically when it finds `swift` and no binary, or run `swift build -c release --static-swift-stdlib --product nvr-tunnel` yourself. Use this on Debian 12 and Ubuntu 22.04.

**2. Install** (on the host, as root; copy the repo and the binary there first if you built elsewhere):

```bash
sudo ./install.sh --binary dist/nvr-tunnel-linux-amd64
```

This installs `ffmpeg`, `curl` and `python3`, the binaries into `/usr/local/bin`, a non-root `nvr` user, the systemd units, and creates `/etc/nvr-recorder/env` (mode 600). With no credentials yet it stops there on purpose.

**3. Configure**: put your serial and password in the env file, then run the installer again to start everything.

```bash
sudo nano /etc/nvr-recorder/env        # set CAM_SERIAL and CAM_PASSWORD (and REC_DIR if not /mnt/recordings)
sudo ./install.sh --skip-deps
```

**4. Check it works** (give it about a minute):

```bash
sudo nvr-health                         # prints "ok used=..." when every channel is writing
journalctl -u nvr-tunnel -f             # "tunnel up via ..." means the relay is connected
ls -lh /mnt/recordings/ch1              # a growing .mkv
```

**5. Watch it.** The viewer listens on `127.0.0.1:8080` by default. From your own computer: `ssh -L 8080:127.0.0.1:8080 you@host`, then open <http://localhost:8080>. To serve it on your network properly, see [Web viewer: exposing it](#exposing-it-safely).

### Try the viewer without a DVR

No hardware needed: generate fake recordings (test patterns) and point the viewer at them.

```bash
sudo apt install ffmpeg python3
scripts/make-demo-recordings.sh /tmp/nvr-demo 4 20        # 4 cameras, 20 minutes of history
REC_DIR=/tmp/nvr-demo CHANNELS="1 2 3 4" VIEWER_NAMES="Gate,Hall,Garden,Garage" \
  VIEWER_CACHE_DIR=/tmp/viewer-cache python3 viewer/nvr_viewer.py
# open http://127.0.0.1:8080
```

## Web viewer

```
+--------------------------------------------------------------------------------+
| Recordings  [1][4][8]  < Cameras 1-4 >                 < 22/11/2026 >  [Today] |
+--------------------------------------------------------------------------------+
|  Gate  REC   02:12:54  [] [<>]  |  Hall  REC   02:12:54  [] [<>]               |
|  +---------------------------+  |  +---------------------------+               |
|  |                           |  |  |                           |               |
|  |          video            |  |  |          video            |               |
|  +---------------------------+  |  +---------------------------+               |
|  ...  (2 x 2, or 4 x 2 in the eight-camera layout)                             |
+--------------------------------------------------------------------------------+
| (<) [>] (>)  1x   Sun, 22 Nov 2026 02:12:54   [Latest]                [1h 6h 24h]|
| Gate    |      ################          |   timeline: one lane per camera     |
| Hall    |      ################          |   red line = playhead               |
| ...     |                                |   orange = still recording          |
+--------------------------------------------------------------------------------+
```

- **Layouts**: `1` one camera (with a camera list on the left), `4` a 2 x 2 grid (a pager appears when you have more than four cameras), `8` a 4 x 2 grid. Switch with the buttons at the top or the `1`, `4`, `8` keys.
- **Click a camera to focus it.** Click any tile, a name in the camera list, or a name on the timeline. Press `Esc` or the close button to return to the grid. The playback time is kept, so you are looking at the same moment on a different camera.
- **Move just one camera.** Press the **link button** on a tile (or `s` in the one-camera view) to "adjust only this camera": the seek buttons, arrow keys, `[` `]`, `Latest` and timeline clicks then move only that camera, while the others keep playing in sync. A chip on the tile shows how far it is from the rest (for example `-0:40`; click it to re-sync), a marker on its timeline lane shows where it actually is, and a bar under the controls offers **Re-sync** and **Done** (`Esc` also leaves the mode). The offset stays until you re-sync it, is remembered in your browser, and is also handy for lining up a camera whose clock is a few seconds off.
- **Synchronized playback.** Every visible camera plays against one shared clock, so you can follow someone across cameras. Cameras that have no footage at that moment show "No recording".
- **Timeline.** One lane per camera for the selected day, in your browser's time zone. Click or drag to jump (a click in a gap snaps to the nearest recording), zoom with `1h` / `6h` / `24h`, `Latest` jumps to the newest footage. Orange blocks are still being recorded.
- **Controls**: play/pause, 10 second skip, speed 0.5x to 8x, previous/next day, fullscreen per camera.
- **Keyboard**: `space` play, `left`/`right` 10 s (with shift 1 min), `[` `]` previous/next recording, `1` `4` `8` layout, `s` adjust only this camera, `Esc` leave that mode or go back to the grid, `f` fullscreen.
- **Segments and downloads**: expand the panel under the timeline to download any segment as the original `mkv` or a browser-friendly `mp4`.
- **Deep links**: the address bar always holds the layout, camera and time (`#v=1&ch=2&t=1795290900`), so you can bookmark or share a moment.
- **Camera names**: set `VIEWER_NAMES="Gate,Hall,Garden"` (in `CHANNELS` order) instead of CH1, CH2, ...
- **Aspect ratio.** Some DVRs record 1080p as a half-width 960x1080 stream (non-square pixels). The viewer detects that and shows it at 16:9.

**Browser support.** Browsers cannot play MKV, so the server remuxes a segment to MP4 on first request (stream copy, about 0.2 s, cached). H.264 plays everywhere. **HEVC/H.265** (what most newer DVRs use) plays in Safari and in Chrome/Edge with hardware decoding; Firefox generally cannot. If a recording will not play, the viewer says so, and you can download it and use VLC.

### Exposing it safely

The viewer has no TLS and only basic auth. By default it listens on `127.0.0.1` only. To use it from other devices:

1. In `/etc/nvr-recorder/env` set `VIEWER_BIND=0.0.0.0`, `VIEWER_USER` and a **strong** `VIEWER_PASSWORD`, then `sudo systemctl restart nvr-viewer`.
2. Put it behind HTTPS, ideally reachable only over a VPN such as Tailscale or WireGuard. Do not forward port 8080 to the internet.

Caddy (the basic-auth header passes straight through to the viewer):

```
cams.example.com {
	reverse_proxy 127.0.0.1:8080
}
```

nginx:

```
location / {
    proxy_pass http://127.0.0.1:8080;
    proxy_set_header Host $host;
    proxy_buffering off;
}
```

## Configuration

All settings live in `/etc/nvr-recorder/env` (see `deploy/nvr-recorder.env.example`, which has a comment for each). After editing, restart the service that reads it (`nvr-tunnel`, `nvr-viewer`, or `nvr-recorder@N`). Retention and health settings are picked up on their next timer run.

| Variable | Default | Meaning |
|----------|---------|---------|
| `CAM_SERIAL` | none, required | The DVR's P2P serial |
| `CAM_USER` / `CAM_PASSWORD` | `admin` / none, required | DVR login |
| `NVR_CLOUD` | `auto` | `instaon`, `easy4ip` or `auto` (tries both) |
| `NVR_LISTEN` / `NVR_REMOTE` | `1554` / `554` | Local port the tunnel exposes / the DVR's RTSP port |
| `NVR_BUSY_RETRY` | `120` | Seconds to keep retrying while the DVR still holds an old relay session |
| `CAM_PUNCH` | unset | Set to `1` to try the direct (STUN punch) path. Off by default: the relay path is the reliable one. |
| `REC_DIR` | `/mnt/recordings` | Where recordings go (one `chN` folder per channel) |
| `CHANNELS` | `1 2 3 4 5 6` | Channels to record, health-check and show |
| `SUBTYPE` | `0` | `0` main stream, `1` sub-stream. Override one channel with `SUBTYPE_3=1`. |
| `SEGMENT_SECONDS` | `1800` | Length of each segment file |
| `RETENTION_HOURS` | `48` | How much footage to keep, per channel |
| `QUOTA_GB` / `QUOTA_ALERT_PCT` | `150` / `90` | Disk allocation the health check measures against, and the alert threshold |
| `STALE_SECONDS` | `180` | Alert if a channel's newest segment is older than this |
| `NTFY_URL` / `NTFY_TOKEN` | unset | ntfy topic URL (and bearer token if the server needs one) for alerts |
| `VIEWER_BIND` / `VIEWER_PORT` | `127.0.0.1` / `8080` | Viewer listen address and port |
| `VIEWER_USER` / `VIEWER_PASSWORD` | `viewer` / unset | Basic-auth login. No password means no auth. |
| `VIEWER_NAMES` | unset | Camera names, comma separated, in `CHANNELS` order |
| `VIEWER_CACHE_MB` | `2048` | Size cap of the MP4 remux cache |

Record only some channels: `CHANNELS="1 3 5"`. If you later remove a channel, also run `sudo systemctl disable --now nvr-recorder@N`.

## Storage planning

```
GB for the whole window = total Mbps x 3600 x hours / 8 / 1000
```

| Cameras at | 24 hours | 48 hours | 7 days |
|-----------|---------:|---------:|-------:|
| 4 x 1 Mbps | 43 GB | 86 GB | 302 GB |
| 6 x 1 Mbps | 65 GB | 130 GB | 454 GB |
| 8 x 2 Mbps | 173 GB | 346 GB | 1210 GB |

Measure your real bitrate for a day (`du -sh /mnt/recordings`) before sizing the disk: it rises with motion and at night. To shrink it, lower the **frame rate** on the DVR first (25 to 15 fps costs little visible quality), then the bitrate cap (DVR web UI, Settings, Encode, Main Stream), or record a quiet camera on its sub-stream (`SUBTYPE_N=1`).

**Retention keeps the most recent `RETENTION_HOURS` of footage per channel**, measured from that channel's newest segment, not from the clock. If the DVR or one camera goes offline for days (power cut, network down), its last 48 hours stay on disk until it records again. The disk quota only **alerts**, it never deletes. Footage is not backed up anywhere.

Run a one-off clean-up with a different window: `sudo bash -c 'set -a; . /etc/nvr-recorder/env; RETENTION_HOURS=24 nvr-retention'`.

## Operating it

```bash
sudo systemctl status nvr-tunnel nvr-viewer 'nvr-recorder@*'   # state of everything
journalctl -u nvr-tunnel -n 50 --no-pager                      # tunnel (relay connect, reconnects)
journalctl -u nvr-recorder@3 -n 50 --no-pager                  # one camera's ffmpeg
sudo systemctl restart nvr-tunnel                              # recorders reconnect on their own
sudo nvr-health                                                # one-shot health check
```

**Updating**: `git pull && sudo ./install.sh --skip-deps`. It never overwrites your env file and restarts only what changed (a tunnel restart causes a short gap, so it is skipped when the binary is unchanged). To ship a new binary add `--binary path/to/nvr-tunnel`.

**Power cuts and outages.** If the DVR loses power or internet, the tunnel keeps retrying with backoff and everything resumes by itself when the DVR returns; `nvr-health` alerts you after `STALE_SECONDS` and again when it recovers. If the host reboots, all services start on boot.

**Uninstall**: `sudo systemctl disable --now nvr-tunnel nvr-viewer nvr-retention.timer nvr-health.timer 'nvr-recorder@*'`, then remove `/etc/systemd/system/nvr-*`, `/usr/local/bin/nvr-*`, `/usr/local/share/nvr-viewer`, `/etc/nvr-recorder` and (if you like) your recordings.

### Running it in a Proxmox LXC

Works well as an **unprivileged** container (Debian 12/13 or Ubuntu, 1 to 2 cores, 1 to 2 GB RAM). Keep the root disk on fast storage and put recordings on a big disk via a bind mount:

```bash
# on the Proxmox host: pick a uid for the service user, own the directory with the mapped uid (100000 + uid)
mkdir -p /mnt/hdd/nvr && chown 101500:101500 /mnt/hdd/nvr
pct set 156 --mp0 /mnt/hdd/nvr,mp=/mnt/recordings --onboot 1
# inside the container
./install.sh --uid 1500 --binary dist/nvr-tunnel-linux-amd64
```

`--uid 1500` pins the `nvr` user's uid so the host-side ownership matches. On Debian 13 unprivileged containers you may also need persistent journald if you ship logs with Alloy or Promtail.

## Troubleshooting

| Symptom | Likely cause and fix |
|---------|----------------------|
| `tunnel open failed: device busy` over and over | The DVR allows **one relay session at a time** and keeps a closed one for about 15 to 20 seconds. Something else (the vendor app, a second recorder) holds it. Close it, wait, or restart `nvr-tunnel`. |
| `device refused or ignored the connection to port 554` | You are probably on the same LAN as the DVR and the direct path was chosen. Leave `CAM_PUNCH` unset (the default) so the relay path is used. |
| `DNS lookup failed` right after boot | The network was not up yet. It retries and recovers within seconds. |
| No `tunnel up` line, device "offline" | Check the serial, that P2P is enabled on the DVR and shows online in the vendor app, and that the host has outbound UDP. |
| ffmpeg keeps restarting for one channel | `journalctl -u nvr-recorder@N`. Wrong channel number, or that camera is off. |
| `nvr-health` says a channel is stale | That camera or recorder stopped. A very quiet camera can have a small, rarely written file; raise `STALE_SECONDS` if it is a false alarm. |
| One camera shows a black picture in the viewer | The camera itself is sending black (night, covered lens). The on-screen text from the DVR still renders. Check the camera physically. |
| "Cannot play this recording" | HEVC in a browser without HEVC decoding. Use Safari or hardware-decoding Chrome, or download the segment and use VLC. |
| Segments are tiny or empty right after a restart | Normal: a segment cut short by a tunnel restart is short. |
| Disk fills faster than expected | Check `du -sh /mnt/recordings/ch*`, lower the DVR's fps or bitrate, or use `SUBTYPE_N=1`. |

## Limitations

- **Dahua-family DVRs reachable through InstaOn or Easy4ip P2P only.** It is not a general-purpose RTSP recorder (use Frigate, Shinobi or ZoneMinder for plain RTSP cameras).
- **One relay session per DVR.** While the recorder runs, using the vendor app remotely at the same time may conflict. This is being tested (see the repository issues). On the DVR's own LAN the app can connect directly.
- No live view yet (recordings are viewable seconds to minutes behind, after the segment's data is flushed), no audio, no motion detection or object recognition, no multi-user accounts.
- The viewer authenticates with basic auth only and should sit behind HTTPS and a VPN.

## Security notes

- The DVR password lives in `/etc/nvr-recorder/env` (mode 600, root only). ffmpeg takes it in the RTSP URL, so it is visible in `ps` to other local users on the host, and `nvr-record` masks it in ffmpeg's log output. Do not run this on a shared multi-user machine.
- Services run as the unprivileged `nvr` user. The viewer only ever reads from `REC_DIR` and its own cache, and only serves exact `chN/YYYYmmdd-HHMMSS` names.
- Recordings are not encrypted. Treat the disk like the cameras' footage, because it is.

## Development

```
Sources/DahuaP2P     InstaOn handshake, PTCP, realm tunnelling   (Linux port of rajpdus/cammob)
Sources/DahuaRTSP    RTSP client + the DVR's HTTP CGI
Sources/TunnelKit    local TCP forwarder that survives tunnel reconnects
Sources/nvr-tunnel   the tunnel daemon (reconnect, backoff)
Sources/camtool      debug CLI: probe, channels, stream, tunnel
viewer/              web viewer: nvr_viewer.py (server) + index.html (UI), tests
deploy/              nvr-record, nvr-retention, nvr-health, systemd units, env example
scripts/             build-release.sh, make-demo-recordings.sh, soak.sh, test-retention.sh, linux-e2e.sh
install.sh           installer
```

```bash
# Swift side (Linux, via Docker: macOS builds are not supported right now)
docker build -f Dockerfile.dev -t p2p-dvr-dev .
docker run --rm -v "$PWD":/src -w /src p2p-dvr-dev swift test

# Viewer and retention tests (any Linux)
python3 -m unittest discover -s viewer
scripts/test-retention.sh

# Talk to a real DVR without installing anything (credentials from the environment, never on disk)
CAM_PASSWORD=... swift run camtool channels YOUR_SERIAL -u admin
```

CI (`.github/workflows/build.yml`) builds and tests on x86_64 for every push, and attaches binaries to releases from tags.

## Credits and license

The relay tunnel is a Linux Swift port of [rajpdus/cammob](https://github.com/rajpdus/cammob) (MIT, pinned at commit `c83546e`), which reverse-engineered the InstaOn handshake and tunnelled RTSP/HTTP through it. MIT licensed, see `LICENSE`. Not affiliated with CP Plus, Dahua, InstaOn or Easy4ip.
