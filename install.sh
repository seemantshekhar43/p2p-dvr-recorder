#!/bin/bash
# Install p2p-dvr-recorder on a Debian/Ubuntu host (run as root, from the repo checkout).
#
#   ./install.sh [--binary PATH] [--prefix DIR] [--user NAME] [--uid N] [--env-file PATH] [--skip-deps] [--no-start]
#
# Binary: --binary PATH, else dist/nvr-tunnel-linux-<arch> (see scripts/build-release.sh), else the
# already installed one (script-only upgrade), else built with `swift build` if Swift is installed.
# Safe to re-run: an existing env file is never overwritten; services whose binary or
# script changed are restarted, the rest are left running.
set -euo pipefail

PREFIX=/usr/local; SVC_USER=nvr; SVC_UID=; ENV_FILE=/etc/nvr-recorder/env; BIN=; DEPS=1; START=1
while [ $# -gt 0 ]; do
  case $1 in
    --binary) BIN=${2:?}; shift 2 ;;
    --prefix) PREFIX=${2:?}; shift 2 ;;
    --user) SVC_USER=${2:?}; shift 2 ;;
    --uid) SVC_UID=${2:?}; shift 2 ;;
    --env-file) ENV_FILE=${2:?}; shift 2 ;;
    --skip-deps) DEPS=0; shift ;;
    --no-start) START=0; shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
cd "$(dirname "$0")"
say() { printf '==> %s\n' "$*"; }

if [ "$DEPS" -eq 1 ]; then
  command -v apt-get >/dev/null || { echo "no apt-get; install ffmpeg and curl yourself and pass --skip-deps" >&2; exit 1; }
  say "installing ffmpeg and curl"
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ffmpeg curl ca-certificates python3 >/dev/null
fi

if [ -z "$BIN" ]; then
  case $(uname -m) in x86_64) arch=amd64 ;; aarch64) arch=arm64 ;; *) arch=$(uname -m) ;; esac
  if [ -f "dist/nvr-tunnel-linux-$arch" ]; then BIN="dist/nvr-tunnel-linux-$arch"
  elif [ -x "$PREFIX/bin/nvr-tunnel" ]; then BIN="$PREFIX/bin/nvr-tunnel"; say "no --binary given: keeping the installed nvr-tunnel"
  elif command -v swift >/dev/null; then
    say "building nvr-tunnel with swift"
    swift build -c release --static-swift-stdlib --product nvr-tunnel
    BIN=.build/release/nvr-tunnel
  else
    echo "no binary: pass --binary PATH, or run scripts/build-release.sh $arch first" >&2; exit 1
  fi
fi
[ -f "$BIN" ] || { echo "binary not found: $BIN" >&2; exit 1; }

# Only restart what changed: a tunnel restart drops the relay session and costs a recording gap.
BIN_CHANGED=0; REC_CHANGED=0
cmp -s "$BIN" "$PREFIX/bin/nvr-tunnel" 2>/dev/null || BIN_CHANGED=1
cmp -s deploy/bin/nvr-record "$PREFIX/bin/nvr-record" 2>/dev/null || REC_CHANGED=1

say "installing binaries to $PREFIX/bin"
install -d "$PREFIX/bin"
[ "$BIN" -ef "$PREFIX/bin/nvr-tunnel" ] || install -m 755 "$BIN" "$PREFIX/bin/nvr-tunnel"
install -m 755 deploy/bin/nvr-record deploy/bin/nvr-retention deploy/bin/nvr-health "$PREFIX/bin/"
install -m 755 viewer/nvr_viewer.py "$PREFIX/bin/nvr-viewer"
install -d "$PREFIX/share/nvr-viewer"
install -m 644 viewer/index.html "$PREFIX/share/nvr-viewer/index.html"

# --uid pins the uid, so on an unprivileged LXC you know the host-side owner of a bind mount
# (host uid = 100000 + container uid).
id "$SVC_USER" >/dev/null 2>&1 || {
  say "creating system user $SVC_USER"
  useradd --system --no-create-home --shell /usr/sbin/nologin ${SVC_UID:+--uid "$SVC_UID"} "$SVC_USER"
}

install -d -m 755 "$(dirname "$ENV_FILE")"
if [ -f "$ENV_FILE" ]; then say "keeping existing $ENV_FILE"
else say "creating $ENV_FILE"; install -m 600 deploy/nvr-recorder.env.example "$ENV_FILE"; fi

# Read the settings this script needs from the env file.
set -a; . "$ENV_FILE"; set +a
REC_DIR=${REC_DIR:-/mnt/recordings}
say "preparing $REC_DIR"
mkdir -p "$REC_DIR"
chown "$SVC_USER:$SVC_USER" "$REC_DIR"
runuser -u "$SVC_USER" -- test -w "$REC_DIR" || echo "WARNING: $SVC_USER cannot write to $REC_DIR (check mount permissions)" >&2

if [ ! -d /run/systemd/system ]; then
  say "systemd is not running here; files installed, units not installed"
  exit 0
fi

say "installing systemd units"
for u in deploy/systemd/*; do
  sed -e "s#/usr/local/#$PREFIX/#g" -e "s#^User=nvr#User=$SVC_USER#" -e "s#^Group=nvr#Group=$SVC_USER#" \
      -e "s#/etc/nvr-recorder/env#$ENV_FILE#g" "$u" >"/etc/systemd/system/$(basename "$u")"
done
systemctl daemon-reload

if [ -z "${CAM_SERIAL:-}" ] || [ -z "${CAM_PASSWORD:-}" ]; then
  say "CAM_SERIAL / CAM_PASSWORD are not set in $ENV_FILE"
  echo "Edit it, then re-run: ./install.sh --skip-deps --binary $BIN" >&2
  exit 0
fi
[ "$START" -eq 1 ] || { say "--no-start: units installed, nothing enabled"; exit 0; }

say "enabling services"
systemctl enable nvr-tunnel.service nvr-retention.timer nvr-health.timer nvr-viewer.service >/dev/null
if [ "$BIN_CHANGED" -eq 1 ]; then systemctl restart nvr-tunnel.service; else systemctl start nvr-tunnel.service; fi
systemctl start nvr-retention.timer nvr-health.timer
systemctl restart nvr-viewer.service
for c in ${CHANNELS:-1 2 3 4 5 6}; do
  systemctl enable "nvr-recorder@$c.service" >/dev/null
  if [ "$BIN_CHANGED" -eq 1 ] || [ "$REC_CHANGED" -eq 1 ]; then systemctl restart "nvr-recorder@$c.service"; else systemctl start "nvr-recorder@$c.service"; fi
done
say "done. Check: systemctl status nvr-tunnel; journalctl -u nvr-tunnel -f; $PREFIX/bin/nvr-health"
