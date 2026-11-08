#!/bin/bash
###############################################################################
# sing-box-mini 一键安装脚本（轻量三协议版）
#
# 定位：为小内存 / 小硬盘机器准备的 sing-box 精简发行：
#   - 核心为定制编译版（仅保留三协议所需能力）：二进制约 40M（官方版约 78M）
#   - 协议三件套：VLESS + Reality（TCP）/ Hysteria2（UDP）/ Shadowsocks 2022
#   - 服务带内存刹车（GOMEMLIMIT + GOGC），空载约 34M、带流量峰值 50M 内
#
# 用法：
#   安装：curl -fsSL https://raw.githubusercontent.com/lnant/sing-box-auto/main/sing-box-mini.sh | sudo bash
#   菜单：sudo sbm
#   卸载：sudo sbm 选 6，或 curl … | sudo bash -s -- uninstall
#
# 特性：
#   - 全程零交互：UUID、密钥、密码、端口全部自动生成（端口 10000-60000 随机）
#   - 幂等：重复运行保持 UUID/密钥/端口不变，客户端链接不变
#   - 独立目录 /etc/s-box-mini、独立服务名 sing-box-mini，可与全功能版同机共存
#   - 受限容器（OpenVZ 等）自动适配系统 DNS 解析，正常机器配置不受影响
#   - 纯 IPv6 机器自动经 DNS64 绕行下载核心；核心下载带 sha256 校验
#   - 安装后打印三条链接，并保存到 /root/singbox-mini-links.txt
###############################################################################
set -euo pipefail

ACTION="${1:-install}"
# 通过 sbm 快捷命令调用且无参数时默认进菜单；其他方式（脚本文件/管道）无参数默认执行安装
if [[ $# -eq 0 && "$(basename "$0")" == "sbm" ]]; then
  ACTION="menu"
fi
SCRIPT_VERSION="0.1.1"
CORE_VERSION_DEFAULT="1.14.4"   # 仓库尚无更新的核心 Release 时的兜底版本
REPO="lnant/sing-box-auto"

if [[ "$ACTION" == "version" ]]; then
  echo "sing-box-mini v${SCRIPT_VERSION}（轻量三协议版：Reality / Hysteria2 / Shadowsocks 2022）"
  exit 0
fi

SB_DIR="${MINI_DIR:-/etc/s-box-mini}"
UNIT="sing-box-mini"
ENV_FILE="$SB_DIR/mini.env"
LINKS_FILE="/root/singbox-mini-links.txt"
SNI_REALITY="apple.com"
SNI_HY2="www.microsoft.com"
SS_METHOD="2022-blake3-aes-128-gcm"

if [[ "$EUID" -ne 0 ]]; then
  echo "[错误] 请以 root 运行，例如：sudo bash $0"
  exit 1
fi

#----------------------------- 1. 系统识别 -----------------------------------
detect_os() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS_ID="${ID:-unknown}"
  else
    OS_ID="unknown"
  fi
  if command -v apt-get >/dev/null 2>&1; then PKG="apt"
  elif command -v dnf >/dev/null 2>&1; then PKG="dnf"
  elif command -v yum >/dev/null 2>&1; then PKG="yum"
  elif command -v apk >/dev/null 2>&1; then PKG="apk"
  else echo "[错误] 不支持的系统：找不到 apt/dnf/yum/apk"; exit 1; fi
  echo "[信息] 系统：${OS_ID}，包管理器：${PKG}"
}

detect_arch() {
  case "$(uname -m)" in
    x86_64)  ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    *) echo "[错误] 不支持的架构：$(uname -m)（定制核心仅提供 amd64 / arm64）"; exit 1 ;;
  esac
  echo "[信息] 架构：${ARCH}"
}

check_memory() {
  local mem_kb swap_kb
  mem_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
  swap_kb=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
  if [ "$mem_kb" -gt 0 ] && [ "$mem_kb" -lt 1048576 ] && [ "$swap_kb" -eq 0 ]; then
    echo "[警告] 内存较小 ($((mem_kb / 1024))M) 且无 swap，装依赖时包管理器可能 OOM 卡死"
    echo "[警告] 建议先加 swap 后再装；继续安装…"
  fi
}

install_deps() {
  local need="" pkgs="" c
  command -v curl >/dev/null 2>&1 || need="$need curl"
  command -v jq >/dev/null 2>&1 || need="$need jq"
  command -v openssl >/dev/null 2>&1 || need="$need openssl"
  command -v sha256sum >/dev/null 2>&1 || need="$need sha256sum"
  { command -v ss >/dev/null 2>&1 || command -v ip >/dev/null 2>&1; } || need="$need iproute"
  if [[ -z "${need// }" ]]; then
    echo "[信息] 依赖已齐全，跳过安装"
    return 0
  fi
  echo "[信息] 安装缺失依赖：$need …"
  case "$PKG" in
    apt) apt-get update -y >/dev/null 2>&1 || true
         pkgs=""
         for c in $need; do
           case "$c" in
             iproute) pkgs="$pkgs iproute2" ;;
             sha256sum) pkgs="$pkgs coreutils" ;;
             *) pkgs="$pkgs $c" ;;
           esac
         done
         DEBIAN_FRONTEND=noninteractive apt-get install -y $pkgs ca-certificates >/dev/null 2>&1 || true ;;
    dnf|yum) pkgs=""
         for c in $need; do
           case "$c" in
             iproute) pkgs="$pkgs iproute" ;;
             sha256sum) pkgs="$pkgs coreutils" ;;
             *) pkgs="$pkgs $c" ;;
           esac
         done
         $PKG install -y $pkgs >/dev/null 2>&1 || true ;;
    apk) pkgs=""
         for c in $need; do
           case "$c" in
             iproute) pkgs="$pkgs iproute2" ;;
             sha256sum) pkgs="$pkgs coreutils" ;;
             *) pkgs="$pkgs $c" ;;
           esac
         done
         apk add --no-cache $pkgs ca-certificates >/dev/null 2>&1 || true ;;
  esac
  command -v curl >/dev/null 2>&1 || { echo "[错误] curl 安装失败"; exit 1; }
  command -v jq >/dev/null 2>&1 || { echo "[错误] jq 安装失败"; exit 1; }
}

check_container() {
  if [[ -f /.dockerenv ]] || { command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt --container >/dev/null 2>&1; }; then
    echo "[提示] 检测到容器环境：开机自启在容器中通常不生效，本次安装只保证容器运行期间可用"
  fi
}

#----------------------------- 2. GitHub 可达性（纯 IPv6 绕行） ----------------
RESOLV_CONF="${RESOLV_CONF:-/etc/resolv.conf}"
DNS64_SERVERS=("2a01:4f8:c2c:123f::1" "2a01:4ff:f0:9876::1" "2a01:4f9:c010:3f02::1")
_GH_OK=""

gh_probe() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 12 https://api.github.com 2>/dev/null) || true
  [[ -n "$code" && "$code" != "000" ]]
}

ensure_github() {
  [[ "$_GH_OK" == "1" ]] && return 0
  if gh_probe; then _GH_OK=1; return 0; fi
  echo "[信息] GitHub 直连不通，检测是否为纯 IPv6 / IPv4 出站异常环境…" >&2
  if ! curl -6 -fsS --connect-timeout 5 --max-time 10 https://www.cloudflare.com/cdn-cgi/trace >/dev/null 2>&1; then
    echo "[警告] 本机也没有 IPv6 出站，无法自动绕行到 GitHub。" >&2
    echo "[警告] 可手动把核心二进制预置到 $SB_DIR/sing-box 后重跑安装（脚本会跳过下载）。" >&2
    return 1
  fi
  local s
  for s in "${DNS64_SERVERS[@]}"; do
    if grep -qF "$s" "$RESOLV_CONF" 2>/dev/null; then
      echo "[警告] 已在使用公共 DNS64 但 GitHub 仍不可达，本次不重复修改 DNS。" >&2
      return 1
    fi
  done
  if [[ -L "$RESOLV_CONF" ]] && readlink "$RESOLV_CONF" 2>/dev/null | grep -q "systemd/resolve"; then
    echo "[警告] resolv.conf 由 systemd-resolved 托管，无法自动切换 DNS64；请手动改上行 DNS 后重试。" >&2
    return 1
  fi
  [[ -w "$RESOLV_CONF" ]] || { echo "[警告] $RESOLV_CONF 不可写，无法自动切换 DNS64。" >&2; return 1; }
  local bak="${RESOLV_CONF}.sbox-bak"
  [[ -f "$bak" ]] || cp -L "$RESOLV_CONF" "$bak" 2>/dev/null || true
  echo "[信息] 引导：切换 DNS 到公共 DNS64（nat64.net），经 NAT64 绕行访问 GitHub…" >&2
  { for s in "${DNS64_SERVERS[@]}"; do echo "nameserver $s"; done; } > "$RESOLV_CONF"
  local try
  for try in 1 2 3; do
    if gh_probe; then
      _GH_OK=1
      echo "[信息] DNS64 已生效，GitHub 可达，继续安装。原 DNS 备份在 $bak。" >&2
      return 0
    fi
    [[ "$try" -lt 3 ]] && sleep $((try * 3))
  done
  [[ -f "$bak" ]] && cp "$bak" "$RESOLV_CONF" 2>/dev/null || true
  echo "[警告] DNS64 绕行未生效，已还原 DNS；请预置二进制或检查 IPv6 线路后重试。" >&2
  return 1
}

#----------------------------- 3. 端口 ---------------------------------------
port_in_use() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -tunlp 2>/dev/null | grep -Eo ':[0-9]+' | grep -qw ":$p" && return 0
  fi
  return 1
}

rand_port() {
  # 参数 $1：已分配端口列表（空格分隔，如 " 12345 23456 "），避免三协议连抽互相撞号：
  # 连抽的端口在写配置/启动服务前都还没监听，port_in_use 查不到彼此，必须靠这份列表互斥
  # 无参调用时 $1 未绑定，set -u 下会直接炸，用 ${1:-} 容错
  local allocated="${1:-}" p tries=0
  while (( tries < 100 )); do
    p=$(( (RANDOM * 32768 + RANDOM) % 50001 + 10000 ))
    if [[ "$allocated" != *" $p "* ]] && ! port_in_use "$p"; then echo "$p"; return 0; fi
    tries=$((tries + 1))
  done
  echo "[错误] 无法分配随机空闲端口" >&2
  return 1
}

#----------------------------- 4. 受限容器自适应 ------------------------------
restricted_net_nameserver() {
  local _ns=""
  if [[ -r /etc/resolv.conf ]]; then
    _ns=$(awk '$1=="nameserver" {print $2; exit}' /etc/resolv.conf 2>/dev/null || true)
  fi
  [[ -n "$_ns" ]] || _ns="127.0.0.53"
  printf '%s\n' "$_ns"
}

restricted_net_dev() {
  ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

# 三项指纹同时成立才算受限：①OpenVZ ②默认路由 dev 以 venet 开头 ③默认路由无网关
restricted_net_env() {
  local _ovz=0
  if command -v systemd-detect-virt >/dev/null 2>&1 \
     && [[ "$(systemd-detect-virt 2>/dev/null || true)" == "openvz" ]]; then
    _ovz=1
  fi
  [[ -e /proc/user_beancounters ]] && _ovz=1
  (( _ovz == 1 )) || return 1
  command -v ip >/dev/null 2>&1 || return 1
  local _dev
  _dev=$(restricted_net_dev)
  [[ "$_dev" == venet* ]] || return 1
  local _def
  _def=$(ip route show default 2>/dev/null | head -n 1)
  [[ -n "$_def" && "$_def" != *" via "* ]] || return 1
  return 0
}

# 受限时给配置追加的顶层 dns + route 段（普通 UDP 指向系统解析 + 关接口枚举）；
# 非受限输出空——正常机器生成的配置与无此段时完全一致
restricted_net_tail() {
  restricted_net_env || return 0
  local _ns _dev _route="\"auto_detect_interface\": false"
  _ns=$(restricted_net_nameserver)
  _dev=$(restricted_net_dev)
  if [[ -n "$_dev" ]]; then _route="$_route, \"default_interface\": \"$_dev\""; fi
  printf ',\n  "dns": {"servers": [{"type": "udp", "server": "%s", "tag": "sys"}], "final": "sys"},\n  "route": {%s}' "$_ns" "$_route"
}

#----------------------------- 5. 定制核心 -----------------------------------
core_asset() { echo "sing-box-mini-linux-${ARCH}"; }

# 下载指定版本核心并验 sha256，装到 $SB_DIR/sing-box；成功返回 0
download_core() {
  local ver="$1" tmp
  tmp=$(mktemp -d)
  echo "[信息] 下载定制核心 v${ver}（${ARCH}）…"
  curl -fSL --retry 2 -o "$tmp/$(core_asset)" \
    "https://github.com/${REPO}/releases/download/core-v${ver}/$(core_asset)" || { rm -rf "$tmp"; return 1; }
  curl -fSL --retry 2 -o "$tmp/SHA256SUMS" \
    "https://github.com/${REPO}/releases/download/core-v${ver}/SHA256SUMS" || { rm -rf "$tmp"; return 1; }
  ( cd "$tmp" && grep " $(core_asset)\$" SHA256SUMS | sha256sum -c - >/dev/null 2>&1 ) \
    || { echo "[错误] 核心 sha256 校验不通过，已放弃"; rm -rf "$tmp"; return 1; }
  install -m 755 "$tmp/$(core_asset)" "$SB_DIR/sing-box"
  echo "$ver" > "$SB_DIR/core.version"
  rm -rf "$tmp"
  echo "[信息] 核心 v${ver} 安装完成（sha256 校验通过）"
}

# 仓库里最新的 core-v* 版本（不带 v）；取不到返回空
fetch_latest_core() {
  ensure_github || true
  curl -fsSL --max-time 15 "https://api.github.com/repos/${REPO}/releases?per_page=30" 2>/dev/null \
    | jq -r '.[].tag_name' 2>/dev/null | grep -m1 '^core-v' | sed 's/^core-v//' || true
}

install_core() {
  mkdir -p "$SB_DIR"
  if [[ -x "$SB_DIR/sing-box" ]]; then
    echo "[信息] 核心已存在（v$(cat "$SB_DIR/core.version" 2>/dev/null || echo 未知)），跳过下载"
    return 0
  fi
  local ver=""
  ver=$(fetch_latest_core)
  [[ -n "$ver" ]] || ver="$CORE_VERSION_DEFAULT"
  download_core "$ver" || { echo "[错误] 核心下载失败"; exit 1; }
}

do_update_core() {
  [[ -x "$SB_DIR/sing-box" ]] || { echo "[错误] 尚未安装，无法更新核心"; return 1; }
  local cur latest
  cur=$(cat "$SB_DIR/core.version" 2>/dev/null || echo "")
  latest=$(fetch_latest_core)
  [[ -n "$latest" ]] || { echo "[错误] 获取最新核心版本失败"; return 1; }
  if [[ "$cur" == "$latest" ]]; then
    echo "[信息] 核心已是最新 v${cur}"
    return 0
  fi
  echo "[信息] 核心更新：v${cur} → v${latest}"
  cp -f "$SB_DIR/sing-box" "$SB_DIR/sing-box.bak"
  if ! download_core "$latest"; then
    mv -f "$SB_DIR/sing-box.bak" "$SB_DIR/sing-box"
    echo "[错误] 新核心下载失败，已恢复旧版"
    return 1
  fi
  if [[ -f "$SB_DIR/sb.json" ]] && ! "$SB_DIR/sing-box" check -c "$SB_DIR/sb.json" >/dev/null 2>&1; then
    mv -f "$SB_DIR/sing-box.bak" "$SB_DIR/sing-box"
    echo "$cur" > "$SB_DIR/core.version"
    echo "[错误] 新核心与现有配置不兼容，已回滚到 v${cur}"
    return 1
  fi
  setup_service
  echo "[完成] 核心已更新到 v${latest}（旧版备份在 $SB_DIR/sing-box.bak）"
}

#----------------------------- 6. 身份与端口 ----------------------------------
save_env() {
  cat > "$ENV_FILE" <<EOF
UUID="$UUID"
PRIVKEY="$PRIVKEY"
PUBKEY="$PUBKEY"
SHORTID="$SHORTID"
PORT_REALITY="$PORT_REALITY"
PORT_HY2="$PORT_HY2"
PORT_SS="$PORT_SS"
HY2_PASS="$HY2_PASS"
SS_KEY="$SS_KEY"
EOF
  chmod 600 "$ENV_FILE"
}

gen_identity() {
  echo "[信息] 生成 UUID、Reality 密钥对与各协议密码…"
  if "$SB_DIR/sing-box" generate uuid >/dev/null 2>&1; then
    UUID=$("$SB_DIR/sing-box" generate uuid)
  else
    UUID=$(cat /proc/sys/kernel/random/uuid)
  fi
  local kp
  kp=$("$SB_DIR/sing-box" generate reality-keypair)
  PRIVKEY=$(echo "$kp" | awk '/PrivateKey/{print $2}' | tr -d '"')
  PUBKEY=$(echo "$kp" | awk '/PublicKey/{print $2}' | tr -d '"')
  SHORTID=$("$SB_DIR/sing-box" generate rand --hex 4 2>/dev/null || openssl rand -hex 4)
  HY2_PASS=$(openssl rand -hex 16)
  SS_KEY=$(openssl rand -base64 16 | tr -d '\n')
  if [[ -z "$PRIVKEY" || -z "$PUBKEY" || -z "$SHORTID" || -z "$HY2_PASS" || -z "$SS_KEY" ]]; then
    echo "[错误] 密钥/密码生成失败"; exit 1
  fi
  local used=" "
  PORT_REALITY=$(rand_port "$used") || { echo "[错误] 端口分配失败"; exit 1; }
  used+=" $PORT_REALITY "
  PORT_HY2=$(rand_port "$used") || { echo "[错误] 端口分配失败"; exit 1; }
  used+=" $PORT_HY2 "
  PORT_SS=$(rand_port "$used") || { echo "[错误] 端口分配失败"; exit 1; }
  echo "[信息] 端口分配：Reality=$PORT_REALITY HY2=$PORT_HY2 SS=$PORT_SS"
  save_env
}

load_or_gen_identity() {
  if [[ -f "$ENV_FILE" ]]; then
    . "$ENV_FILE"
    if [[ -n "${UUID:-}" && -n "${PRIVKEY:-}" && -n "${PUBKEY:-}" && -n "${SHORTID:-}" \
       && -n "${PORT_REALITY:-}" && -n "${PORT_HY2:-}" && -n "${PORT_SS:-}" \
       && -n "${HY2_PASS:-}" && -n "${SS_KEY:-}" ]]; then
      echo "[信息] 检测到已有配置，身份与端口保持不变（幂等重跑）"
      return 0
    fi
    echo "[警告] 已有配置不完整，将重新生成身份信息"
  fi
  gen_identity
}

gen_hy2_cert() {
  if [[ -f "$SB_DIR/hy2-cert.pem" && -f "$SB_DIR/hy2-key.pem" ]]; then return 0; fi
  echo "[信息] 生成 Hysteria2 自签证书…"
  openssl req -x509 -newkey rsa:2048 -keyout "$SB_DIR/hy2-key.pem" -out "$SB_DIR/hy2-cert.pem" \
    -days 3650 -nodes -subj "/CN=${SNI_HY2}" \
    -addext "subjectAltName=DNS:${SNI_HY2}" >/dev/null 2>&1 \
    || { echo "[错误] 自签证书生成失败"; exit 1; }
  chmod 600 "$SB_DIR/hy2-key.pem"
}

#----------------------------- 7. 写配置 --------------------------------------
write_config() {
  echo "[信息] 写入 sing-box 配置（三协议）…"
  local tail
  tail=$(restricted_net_tail)
  [[ -n "$tail" ]] && echo "[信息] 检测到受限容器网络，已启用系统 DNS 自适应"
  cat > "$SB_DIR/sb.json" <<EOF
{
  "log": {"level": "info", "timestamp": true},
  "inbounds": [
    {
      "type": "vless", "tag": "reality-in",
      "listen": "::", "listen_port": $PORT_REALITY,
      "users": [{"uuid": "$UUID", "flow": "xtls-rprx-vision"}],
      "tls": {
        "enabled": true, "server_name": "$SNI_REALITY",
        "reality": {
          "enabled": true,
          "handshake": {"server": "$SNI_REALITY", "server_port": 443},
          "private_key": "$PRIVKEY",
          "short_id": ["$SHORTID"]
        }
      }
    },
    {
      "type": "hysteria2", "tag": "hy2-in",
      "listen": "::", "listen_port": $PORT_HY2,
      "users": [{"name": "main", "password": "$HY2_PASS"}],
      "tls": {
        "enabled": true, "server_name": "$SNI_HY2",
        "certificate_path": "$SB_DIR/hy2-cert.pem",
        "key_path": "$SB_DIR/hy2-key.pem"
      }
    },
    {
      "type": "shadowsocks", "tag": "ss-in",
      "listen": "::", "listen_port": $PORT_SS,
      "method": "$SS_METHOD",
      "password": "$SS_KEY"
    }
  ],
  "outbounds": [{"type": "direct", "tag": "direct"}]$tail
}
EOF
  "$SB_DIR/sing-box" check -c "$SB_DIR/sb.json" >/dev/null 2>&1 \
    || { echo "[错误] 配置校验失败"; exit 1; }
  echo "[信息] 配置校验通过"
}

#----------------------------- 8. 防火墙 --------------------------------------
open_firewall() {
  local ports="$PORT_REALITY $PORT_HY2 $PORT_SS"
  echo "[信息] 放行防火墙端口：${ports}（TCP+UDP）…"
  local p
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    for p in $ports; do
      firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null 2>&1
      firewall-cmd --permanent --add-port="${p}/udp" >/dev/null 2>&1
    done
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    for p in $ports; do
      ufw allow "${p}/tcp" >/dev/null 2>&1
      ufw allow "${p}/udp" >/dev/null 2>&1
    done
  fi
  if command -v iptables >/dev/null 2>&1; then
    for p in $ports; do
      iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null \
        || iptables -I INPUT 1 -p tcp --dport "$p" -j ACCEPT 2>/dev/null || true
      iptables -C INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null \
        || iptables -I INPUT 1 -p udp --dport "$p" -j ACCEPT 2>/dev/null || true
    done
    command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1 || true
  fi
  if command -v ip6tables >/dev/null 2>&1; then
    for p in $ports; do
      ip6tables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null \
        || ip6tables -I INPUT 1 -p tcp --dport "$p" -j ACCEPT 2>/dev/null || true
      ip6tables -C INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null \
        || ip6tables -I INPUT 1 -p udp --dport "$p" -j ACCEPT 2>/dev/null || true
    done
  fi
  local first_port="${ports%% *}" fw_ok=0
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null \
     && firewall-cmd --list-ports 2>/dev/null | grep -qw "${first_port}/tcp"; then
    fw_ok=1
  elif command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active" \
     && ufw status 2>/dev/null | grep -qw "$first_port"; then
    fw_ok=1
  elif command -v iptables >/dev/null 2>&1 \
     && iptables -C INPUT -p tcp --dport "$first_port" -j ACCEPT 2>/dev/null; then
    fw_ok=1
  elif command -v ip6tables >/dev/null 2>&1 \
     && ip6tables -C INPUT -p tcp --dport "$first_port" -j ACCEPT 2>/dev/null; then
    fw_ok=1
  fi
  if (( fw_ok == 1 )); then
    echo "[信息] 防火墙已放行"
  else
    echo "[警告] 未能确认防火墙放行成功（本机可能使用纯 nftables 等未覆盖的防火墙）"
    echo "[警告] 请手动放行端口：${ports}（TCP+UDP），云厂商安全组同样需要放行"
  fi
}

fix_selinux() {
  if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce 2>/dev/null)" == "Enforcing" ]]; then
    echo "[信息] 检测到 SELinux 为 Enforcing，切换为 Permissive…"
    setenforce 0 2>/dev/null || true
    [[ -f /etc/selinux/config ]] && sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
  fi
}

ensure_time_sync() {
  if command -v timedatectl >/dev/null 2>&1; then
    timedatectl set-ntp true >/dev/null 2>&1 || true
  fi
}

#----------------------------- 9. 服务 ----------------------------------------
setup_service() {
  echo "[信息] 配置并启动服务…"
  if [[ -d /run/systemd/system ]] || pidof systemd >/dev/null 2>&1; then
    cat > "/etc/systemd/system/${UNIT}.service" <<EOF
[Unit]
Description=sing-box-mini service
After=network.target nss-lookup.target

[Service]
User=root
WorkingDirectory=$SB_DIR
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
Environment=GOMEMLIMIT=48MiB
Environment=GOGC=50
ExecStart=$SB_DIR/sing-box run -c $SB_DIR/sb.json
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$UNIT" >/dev/null 2>&1 || true
    systemctl restart "$UNIT" || true
    sleep 2
    if systemctl is-active --quiet "$UNIT"; then
      echo "[信息] sing-box-mini 运行中"
    else
      echo "[错误] 服务启动失败，日志如下："
      journalctl -u "$UNIT" --no-pager -n 20 2>/dev/null || true
      exit 1
    fi
  else
    echo "[警告] 未检测到 systemd，改用后台方式启动（带同样的内存刹车参数）"
    pkill -f "$SB_DIR/sing-box run" >/dev/null 2>&1 || true
    GOMEMLIMIT=48MiB GOGC=50 nohup "$SB_DIR/sing-box" run -c "$SB_DIR/sb.json" \
      >/var/log/sing-box-mini.log 2>&1 &
    sleep 2
    pgrep -f "$SB_DIR/sing-box run" >/dev/null || { echo "[错误] 后台启动失败"; exit 1; }
    if command -v crontab >/dev/null 2>&1; then
      (crontab -l 2>/dev/null | grep -v "sing-box-mini" ; echo "@reboot sleep 10 && GOMEMLIMIT=48MiB GOGC=50 $SB_DIR/sing-box run -c $SB_DIR/sb.json >/var/log/sing-box-mini.log 2>&1") | crontab - >/dev/null 2>&1 || true
    fi
    echo "[信息] sing-box-mini 已在后台启动"
  fi
}

restart_service() {
  if systemctl is-active --quiet "$UNIT" 2>/dev/null || [[ -f "/etc/systemd/system/${UNIT}.service" ]]; then
    systemctl restart "$UNIT" && echo "[信息] 已重启" || echo "[错误] 重启失败"
    # 重启后验活（与 setup_service 对齐）：systemctl restart 返回成功不等于进程
    # 活着——新配置若端口冲突，进程随即退出，不验活就会打印新链接报喜（静默失败）
    sleep 2
    if ! systemctl is-active --quiet "$UNIT"; then
      echo "[错误] 重启后服务未运行，日志如下："
      journalctl -u "$UNIT" --no-pager -n 20 2>/dev/null || true
    fi
  else
    pkill -f "$SB_DIR/sing-box run" >/dev/null 2>&1 || true
    sleep 1
    GOMEMLIMIT=48MiB GOGC=50 nohup "$SB_DIR/sing-box" run -c "$SB_DIR/sb.json" \
      >/var/log/sing-box-mini.log 2>&1 &
    echo "[信息] 已重启（后台模式）"
  fi
}

setup_shortcut() {
  # sbm 快捷命令：先下到临时文件校验内容再替换，避免下坏文件覆盖可用版本
  local tmp
  tmp=$(mktemp)
  if curl -fsSL --max-time 30 -o "$tmp" \
      "https://raw.githubusercontent.com/${REPO}/main/sing-box-mini.sh" 2>/dev/null \
     && head -n 1 "$tmp" | grep -q '^#!/bin/bash' && grep -q 'sing-box-mini' "$tmp"; then
    install -m 755 "$tmp" /usr/local/bin/sbm
    echo "[信息] 快捷命令已安装：sbm（root 下运行打开菜单）"
  else
    echo "[警告] 快捷命令下载失败，可稍后重跑安装或手动下载脚本使用"
  fi
  rm -f "$tmp"
  # 若本次是本地文件运行，把脚本副本留在 SB_DIR 便于离线管理
  if [[ -f "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "/usr/local/bin/sbm" ]]; then
    cp -f "${BASH_SOURCE[0]}" "$SB_DIR/sing-box-mini.sh" 2>/dev/null || true
    chmod 755 "$SB_DIR/sing-box-mini.sh" 2>/dev/null || true
  fi
}

#----------------------------- 10. 链接 ---------------------------------------
get_ip() {
  local src ip=""
  for src in "https://icanhazip.com" "https://ip.sb" "https://ifconfig.me/ip" "https://api.ipify.org"; do
    ip=$(curl -fsSL --max-time 8 -4 "$src" 2>/dev/null | tr -d '[:space:]' || true)
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then echo "$ip"; return 0; fi
  done
  for src in "https://icanhazip.com" "https://ip.sb" "https://ifconfig.me/ip"; do
    ip=$(curl -fsSL --max-time 8 -6 "$src" 2>/dev/null | tr -d '[:space:]' || true)
    if [[ "$ip" == *:* && "$ip" =~ ^[0-9a-fA-F:]+$ ]]; then echo "[$ip]"; return 0; fi
  done
  echo ""
}

print_links() {
  [[ -f "$ENV_FILE" ]] || { echo "[错误] 尚未安装"; return 1; }
  . "$ENV_FILE"
  local ip host vl_link hy_link ss_user ss_link
  ip="$(get_ip)"
  host="$(hostname)"
  vl_link="vless://${UUID}@${ip}:${PORT_REALITY}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI_REALITY}&fp=chrome&pbk=${PUBKEY}&sid=${SHORTID}&type=tcp&headerType=none#mini-reality-${host}"
  hy_link="hysteria2://${HY2_PASS}@${ip}:${PORT_HY2}/?insecure=1&sni=${SNI_HY2}#mini-hy2-${host}"
  ss_user=$(printf '%s' "${SS_METHOD}:${SS_KEY}" | base64 -w0 2>/dev/null | tr '+/' '-_' | tr -d '=')
  ss_link="ss://${ss_user}@${ip}:${PORT_SS}#mini-ss-${host}"
  {
    echo "================ sing-box-mini 节点链接 ================"
    echo "生成时间：$(date '+%Y-%m-%d %H:%M:%S')"
    echo
    if [[ -z "$ip" ]]; then
      echo "[警告] 未能获取公网 IP：下方链接的服务器地址为空，使用前请把 @: 替换为 @服务器IP:"
      echo
    fi
    echo "VLESS + Reality (TCP/${PORT_REALITY})"
    echo "$vl_link"
    echo
    echo "Hysteria2 (UDP/${PORT_HY2})"
    echo "$hy_link"
    echo
    echo "Shadowsocks 2022 (TCP+UDP/${PORT_SS})"
    echo "$ss_link"
    echo
    echo "======================================================="
    echo "提示：链接已保存到 $LINKS_FILE；管理菜单：sudo sbm"
  } | tee "$LINKS_FILE"
  chmod 600 "$LINKS_FILE"
}

#----------------------------- 11. 卸载 ---------------------------------------
do_uninstall() {
  echo "[信息] 卸载 sing-box-mini…"
  systemctl stop "$UNIT" >/dev/null 2>&1 || true
  systemctl disable "$UNIT" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${UNIT}.service"
  systemctl daemon-reload >/dev/null 2>&1 || true
  pkill -f "$SB_DIR/sing-box run" >/dev/null 2>&1 || true
  if command -v crontab >/dev/null 2>&1; then
    (crontab -l 2>/dev/null | grep -v "sing-box-mini") | crontab - >/dev/null 2>&1 || true
  fi
  rm -f /usr/local/bin/sbm
  rm -rf "$SB_DIR" "$LINKS_FILE"
  rm -f /var/log/sing-box-mini.log
  echo "[信息] 卸载完成（防火墙放行规则未动，如需清理请手动处理）"
}

#----------------------------- 12. 菜单 ---------------------------------------
# 选择类读取：20 秒超时/回车=默认；超时保留已输入（|| true，不覆盖变量）
read_choice() {
  local _v=""
  if [[ -r /dev/tty ]]; then
    read -t 20 -rp "$1" _v </dev/tty || true
  else
    read -t 20 -rp "$1" _v || true
  fi
  printf '%s' "$_v"
}

do_menu() {
  [[ -f "$ENV_FILE" ]] || { echo "[错误] 尚未安装，请先运行安装"; exit 1; }
  while true; do
    local st="未运行"
    systemctl is-active --quiet "$UNIT" 2>/dev/null && st="运行中"
    echo
    echo "======== sing-box-mini v${SCRIPT_VERSION} ========"
    echo " 状态：$st ｜ 核心：v$(cat "$SB_DIR/core.version" 2>/dev/null || echo 未知)"
    echo " 1) 查看链接"
    echo " 2) 重启服务"
    echo " 3) 更换端口（三个端口重新随机）"
    echo " 4) 重置身份（UUID/密钥/密码全换，旧链接失效）"
    echo " 5) 更新核心"
    echo " 6) 卸载"
    echo " 0) 退出（回车/20 秒无输入默认退出）"
    local c
    c=$(read_choice "请选择 [0-6]：")
    case "$c" in
      1) print_links ;;
      2) restart_service ;;
      3)
        . "$ENV_FILE"
        local used=" "
        PORT_REALITY=$(rand_port "$used"); used+=" $PORT_REALITY "
        PORT_HY2=$(rand_port "$used"); used+=" $PORT_HY2 "
        PORT_SS=$(rand_port "$used")
        save_env; write_config; open_firewall; restart_service; print_links
        ;;
      4)
        local y
        y=$(read_choice "确认重置身份？旧链接将全部失效 [y/N]：")
        if [[ "$y" == "y" || "$y" == "Y" ]]; then
          gen_identity; gen_hy2_cert; write_config; restart_service; print_links
        else
          echo "已取消"
        fi
        ;;
      5) detect_arch; do_update_core ;;
      6)
        local y2
        y2=$(read_choice "确认卸载 sing-box-mini？[y/N]：")
        if [[ "$y2" == "y" || "$y2" == "Y" ]]; then do_uninstall; exit 0; else echo "已取消"; fi
        ;;
      0|"") echo "退出"; exit 0 ;;
      *) echo "无效选择：$c" ;;
    esac
  done
}

#----------------------------- 主流程 ------------------------------------------
main() {
  case "$ACTION" in
    install)
      detect_os
      detect_arch
      ensure_github || true
      check_memory
      check_container
      install_deps
      ensure_time_sync
      install_core
      load_or_gen_identity
      gen_hy2_cert
      write_config
      open_firewall
      fix_selinux
      setup_service
      setup_shortcut
      print_links
      echo
      echo "[完成] sing-box-mini 已就绪：三条链接见上，管理菜单运行 sudo sbm"
      ;;
    uninstall) do_uninstall ;;
    update-core) detect_arch; do_update_core ;;
    links) print_links ;;
    restart) restart_service ;;
    menu) do_menu ;;
    *) echo "用法：$0 [install|uninstall|update-core|links|restart|menu|version]"; exit 1 ;;
  esac
}

# 直接执行或经 curl 管道执行时跑主流程；被 source 加载时不跑（便于测试）
if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]}" == "$0" ]]; then
  main
fi
