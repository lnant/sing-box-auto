#!/bin/bash
# sing-box-mini 定制核心构建脚本（可复现构建）
# 产物：sing-box-slim-linux-amd64 / sing-box-slim-linux-arm64
# 设计口径：只保留三协议（Reality / Hysteria2 / Shadowsocks 2022)＋WARP 所需能力，
# 砍掉 gVisor/TUN、Tailscale、Clash API 等大块；不做 UPX 等二次压缩。
set -euo pipefail
SING_BOX_VERSION="${SING_BOX_VERSION:-v1.14.4}"
TAGS="with_quic,with_wireguard,with_utls,with_acme"
export CGO_ENABLED=0 GOFLAGS=-mod=mod
cd "$(dirname "$0")"
if [ ! -d src ]; then
  git clone --depth 1 --branch "$SING_BOX_VERSION" https://github.com/SagerNet/sing-box.git src
fi
cd src
for arch in amd64 arm64; do
  echo "== building linux/$arch =="
  GOOS=linux GOARCH=$arch go build -trimpath \
    -ldflags "-s -w -buildid=" \
    -tags "$TAGS" \
    -o "../sing-box-slim-linux-$arch" ./cmd/sing-box
done
cd ..
sha256sum sing-box-slim-linux-amd64 sing-box-slim-linux-arm64
ls -l sing-box-slim-linux-amd64 sing-box-slim-linux-arm64
