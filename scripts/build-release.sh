#!/bin/bash
# Build a release nvr-tunnel for Linux in Docker, with the Swift runtime linked in
# (only glibc and zlib are needed on the target).   usage: scripts/build-release.sh [amd64|arm64]
set -euo pipefail
arch=${1:-$(case $(uname -m) in x86_64) echo amd64 ;; *) echo arm64 ;; esac)}
cd "$(dirname "$0")/.."
docker build -q --platform "linux/$arch" -f Dockerfile.dev -t "p2p-dvr-recorder-dev:$arch" . >/dev/null
mkdir -p dist
docker run --rm --platform "linux/$arch" -v "$PWD":/src -w /src "p2p-dvr-recorder-dev:$arch" sh -c '
  swift build -c release --static-swift-stdlib --product nvr-tunnel --scratch-path /tmp/b &&
  cp /tmp/b/release/nvr-tunnel /src/dist/nvr-tunnel-linux-'"$arch"
echo "built dist/nvr-tunnel-linux-$arch"
