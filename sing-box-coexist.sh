#!/bin/bash
###############################################################################
# sing-box-coexist 一键安装脚本（全功能版 full）
#
# 定位：同仓功能最全的一支——以官方 sing-box 核心为底，九个入站全开，
#   再加可选的 Argo 隧道链与 WARP 出站：
#   - 核心为官方 sing-box（SagerNet/sing-box 官方 Release），
#     支持 sing-box 的数十种主流协议，脚本功能按此持续补齐；
#     跟随官方核心更新，后续可支持更多协议与功能
#   - 当前脚本提供：VLESS + Reality（TCP）/ VMess + WS（TCP）/
#     Hysteria2（UDP）/ TUIC v5（UDP）/ AnyTLS（TCP）/
#     Shadowsocks 2022（TCP+UDP）/ Trojan（TCP）/ Naive（TCP）/
#     VLESS + WS + TLS 域名链（TCP）；另带 WARP 出站（WireGuard 端点：
#     纯 IPv6 机器默认开启 IPv4 经 WARP，有 IPv4 出口默认关闭，失败降级）
#   - Argo 隧道（可选，默认关）：VMess 再经 Cloudflare 隧道出一条链，
#     与域名链共存互备；临时隧道（trycloudflare）或固定隧道
#     （Token + 域名，ingress 在 Cloudflare 侧指向本机 VMess 端口）。
#     装机时一问决定开/关（或用 SBOX_ARGO 参数），菜单里随时可开关
#
# 用法：
#   安装：curl -fsSL https://raw.githubusercontent.com/lnant/sing-box-auto/main/sing-box-coexist.sh | sudo bash
#   菜单：sbc（快捷方式自动提权，不用敲 sudo；旧名 sbox 兼容）
#   卸载：sbc 选 11，或 curl … | sudo bash -s -- uninstall
#
# 特性：
#   - 交互只出现在装机时几个可选项（自己的域名 / Argo / 公网 IP 手填），
#     其余全自动：UUID、密钥、密码、端口全部自动生成（端口 10000-60000 随机）
#   - 幂等：重复运行保持 UUID/密钥/端口不变，客户端链接不变；
#     能读回旧版七合一（coexist-v1.1.4 及更早）的 auto.env，UUID/端口不漂移
#   - 本体目录 /etc/s-box、服务名 sing-box-auto（Argo 单元 sing-box-auto-argo）
#   - 受限容器（OpenVZ 等）自动适配系统 DNS 解析，正常机器配置不受影响
#   - 纯 IPv6 机器自动经 DNS64 绕行下载核心；核心下载带 sha256 校验
#   - 安装后打印全部链接，并保存到 /root/singbox-links.txt
###############################################################################
set -euo pipefail

ACTION="${1:-install}"
# 通过 sbc 快捷命令调用且无参数时默认进菜单；其他方式（脚本文件/管道）无参数默认执行安装
if [[ $# -eq 0 ]] && { [[ "$(basename "$0")" == "sbc" ]] || [[ "$(basename "$0")" == "sbox" ]]; }; then
  ACTION="menu"
fi
SCRIPT_VERSION="1.2.1"
CORE_VERSION_DEFAULT="1.14.4"   # 官方仓库取不到最新版时的兜底版本（官方 sing-box 版本号）
CORE_REPO="SagerNet/sing-box"   # 核心二进制发布仓：官方仓库（脚本本体仍在本仓）
REPO="lnant/sing-box-auto"

if [[ "$ACTION" == "version" ]]; then
  echo "sing-box-coexist v${SCRIPT_VERSION}（全功能版 full，官方 sing-box 核心）"
  exit 0
fi

SB_DIR="${SBOX_DIR:-/etc/s-box}"
UNIT="sing-box-auto"
ARGO_UNIT="${UNIT}-argo"       # Argo 隧道的 systemd 服务名（cloudflared 交 systemd 托管，崩溃自动拉起）
ENV_FILE="$SB_DIR/auto.env"
LINKS_FILE="/root/singbox-links.txt"
ARGO_ENV_FILE="$SB_DIR/argo.env"   # 持久化：Argo 隧道开关与固定隧道参数（600 权限，只 grep 解析、从不 source）
INPUT_TIMEOUT=60                # 输入类等待秒数：60 秒无输入自动按默认走下一步
CHOICE_TIMEOUT=20               # 选择类等待秒数：20 秒无选择/回车一律取默认选择
WARP_ENV_FILE="$SB_DIR/warp.env" # 持久化：WARP 出站模式与 wgcf 一次性注册参数（菜单管理，600 权限）
SNI_REALITY="apple.com"
SNI_HY2="www.microsoft.com"
SNI_SELF="www.bing.com"
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
    *) echo "[错误] 不支持的架构：$(uname -m)（本脚本仅支持 amd64 / arm64）"; exit 1 ;;
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
  command -v tar >/dev/null 2>&1 || need="$need tar"
  { command -v ss >/dev/null 2>&1 || command -v ip >/dev/null 2>&1; } || need="$need iproute"
  command -v crontab >/dev/null 2>&1 || need="$need cron"
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
             cron) pkgs="$pkgs cron" ;;
             sha256sum) pkgs="$pkgs coreutils" ;;
             *) pkgs="$pkgs $c" ;;
           esac
         done
         DEBIAN_FRONTEND=noninteractive apt-get install -y $pkgs ca-certificates >/dev/null 2>&1 || true ;;
    dnf|yum) pkgs=""
         for c in $need; do
           case "$c" in
             iproute) pkgs="$pkgs iproute" ;;
             cron) pkgs="$pkgs cronie" ;;
             sha256sum) pkgs="$pkgs coreutils" ;;
             *) pkgs="$pkgs $c" ;;
           esac
         done
         $PKG install -y $pkgs >/dev/null 2>&1 || true ;;
    apk) pkgs=""
         for c in $need; do
           case "$c" in
             iproute) pkgs="$pkgs iproute2" ;;
             cron) pkgs="$pkgs dcron" ;;
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
  # 两个入口任一通就算可达：个别环境（如某些沙盒）只挡 api.github.com
  # 子域、github.com 本体与 Release 下载反而是通的，只探一个会误报「直连
  # 不通」吓到用户（2026-11-24 sbx 实测）
  local code url
  for url in https://api.github.com https://github.com; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 12 "$url" 2>/dev/null) || true
    [[ -n "$code" && "$code" != "000" ]] && return 0
  done
  return 1
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
  # 参数 $1：已分配端口列表（空格分隔，如 " 12345 23456 "），避免连抽时互相撞号：
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

# 无 IPv6 出口检测：无全局 IPv6 地址、且无 IPv6 默认路由才判真。纯结构判断、
# 不发包探测；命令缺失一律判假（宁可漏报不可误报，与受限检测同一口径）。
# 背景（2026-11-19 实测）：这类机器（如部分云厂商的纯 IPv4 实例）没有 IPv6
# 出口，客户端发来的 IPv6 目标连接必然 network unreachable——手机等客户端
# 自带 IPv6、常把域名解析成 v6 地址直发过来，失败后未必回落 v4，体感就是
# 「节点时好时坏」；而安装时的历次验证用的都是域名目标（解析走 v4），验不出。
no_v6_egress() {
  command -v ip >/dev/null 2>&1 || return 1
  if ip -6 addr show scope global 2>/dev/null | grep -q 'inet6'; then return 1; fi
  if [[ -n "$(ip -6 route show default 2>/dev/null)" ]]; then return 1; fi
  return 0
}

# 给配置追加的顶层 dns + route 段；两类自适应都没命中时输出空——正常机器
# 生成的配置与无此段时完全一致。两类可叠加、共用同一个 dns/route 对象：
#  ① 受限网络（restricted_net_env）：dns 走普通 UDP 指向系统解析（type
#     "local" 在受限环境实测无效），route 关接口探测并写死默认网卡；
#  ② 无 IPv6 出口（no_v6_egress）：默认解析策略 ipv4_only（域名不再解析出
#     v6），并给 IPv6 目标加 reject 规则，让客户端立刻失败回落 v4、不干等。
# $1 可选：调用方既有的 route 内字段（如 WARP 的 final），非空时并入同一
# 个 route 对象，避免顶层出现两个 "route" 键。$1 已带 rules 时不再叠加
# reject 规则（v6 由调用方在自己的 rules 里处理）；$1 带 final: warp 时
# 同样不叠 reject（v6 目标落 final 经 WARP 出去）。整段 ② 只有 WARP all
# 模式才不启用；WARP ipv4 模式的 $1 同为 final: warp，但它的分流就靠 ②
# 的 ipv4_only 解析策略实现，② 必须照常启用（靠全局 WARP_MODE 区分）。
restricted_net_tail() {
  local _extra="${1:-}"
  local _restricted=0 _nov6=0
  if restricted_net_env; then _restricted=1; fi
  if no_v6_egress; then
    if [[ "$_extra" != *'"final": "warp"'* || "${WARP_MODE:-off}" != "all" ]]; then _nov6=1; fi
  fi
  (( _restricted == 1 || _nov6 == 1 )) || return 0
  local _route="" _dns=""
  if (( _restricted == 1 )); then
    local _ns _dev
    _ns=$(restricted_net_nameserver)
    _dev=$(restricted_net_dev)
    _route="\"auto_detect_interface\": false"
    if [[ -n "$_dev" ]]; then _route="$_route, \"default_interface\": \"$_dev\""; fi
    _dns="\"dns\": {\"servers\": [{\"type\": \"udp\", \"server\": \"$_ns\", \"tag\": \"sys\"}], \"final\": \"sys\"}"
    if (( _nov6 == 1 )); then
      _route="$_route, \"default_domain_resolver\": {\"server\": \"sys\", \"strategy\": \"ipv4_only\"}"
      if [[ "$_extra" != *'"rules"'* && "$_extra" != *'"final": "warp"'* ]]; then
        _route="$_route, \"rules\": [{\"ip_version\": 6, \"action\": \"reject\"}]"
      fi
    fi
  else
    _dns="\"dns\": {\"servers\": [{\"type\": \"local\", \"tag\": \"local\"}]}"
    _route="\"default_domain_resolver\": {\"server\": \"local\", \"strategy\": \"ipv4_only\"}"
    if [[ "$_extra" != *'"rules"'* && "$_extra" != *'"final": "warp"'* ]]; then
      _route="$_route, \"rules\": [{\"ip_version\": 6, \"action\": \"reject\"}]"
    fi
  fi
  if [[ -n "$_extra" ]]; then _route="$_route, $_extra"; fi
  if (( _restricted == 0 && _nov6 == 1 )) && [[ -z "$_extra" ]]; then
    _route="$_route, \"final\": \"direct\""
  fi
  printf ',\n  %s,\n  "route": {%s}' "$_dns" "$_route"
}

#----------------------------- 5. 官方核心 -----------------------------------
core_asset() { echo "sing-box-$1-linux-${ARCH}.tar.gz"; }
core_dirname() { echo "sing-box-$1-linux-${ARCH}"; }

# 下载指定版本官方核心并验 sha256，装到 $SB_DIR/sing-box；成功返回 0
# 官方 Release 是 tar.gz 包（内含同名目录与 sing-box 二进制），且不附
# 校验文件：改用 GitHub API 为每个资产公布的 sha256 摘要（digest）核对，
# 与原先下校验文件对照是同一强度；摘要取不到或对不上都放弃不用。
download_core() {
  local ver="$1" tmp asset want got
  asset=$(core_asset "$ver")
  tmp=$(mktemp -d)
  echo "[信息] 下载官方核心 v${ver}（${ARCH}）…"
  curl -fSL --retry 2 --connect-timeout 10 --speed-limit 10240 --speed-time 30 -o "$tmp/$asset" \
    "https://github.com/${CORE_REPO}/releases/download/v${ver}/${asset}" || { rm -rf "$tmp"; return 1; }
  want=$(curl -fsSL --max-time 15 "https://api.github.com/repos/${CORE_REPO}/releases/tags/v${ver}" 2>/dev/null \
    | jq -r --arg n "$asset" '.assets[] | select(.name == $n) | .digest // empty' 2>/dev/null \
    | sed 's/^sha256://') || true
  got=$(sha256sum "$tmp/$asset" 2>/dev/null | awk '{print $1}')
  if [[ -z "$want" || "$want" != "$got" ]]; then
    echo "[错误] 核心 sha256 校验不通过，已放弃"; rm -rf "$tmp"; return 1
  fi
  tar -xzf "$tmp/$asset" -C "$tmp" || { rm -rf "$tmp"; return 1; }
  install -m 755 "$tmp/$(core_dirname "$ver")/sing-box" "$SB_DIR/sing-box"
  echo "$ver" > "$SB_DIR/core.version"
  rm -rf "$tmp"
  echo "[信息] 核心 v${ver} 安装完成（sha256 校验通过）"
}

# 官方仓库最新稳定版 Release 的版本号（不带 v）；取不到返回空。
# 用 /releases/latest 只认稳定版，不会误取官方的预发布（如 1.15.0-alpha）
fetch_latest_core() {
  ensure_github || true
  curl -fsSL --max-time 15 "https://api.github.com/repos/${CORE_REPO}/releases/latest" 2>/dev/null \
    | jq -r '.tag_name // empty' 2>/dev/null | sed 's/^v//' || true
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

#----------------------------- 5.5 TLS 域名（自己的域名手动加记录 / 临时域名）----
# 本脚本不要 Cloudflare 令牌、不进任何人的解析后台：想用自己的域名，
# 记录由装机人自己去面板加，脚本只负责把要加的记录打出来、再验解析
# 对不对。不要域名（或非交互安装）就用 sslip.io 临时域名 + 自签证书。

# TLS_DOMAIN 是不是用户自己的域名（不是临时 sslip、不是兜底伪装名）
is_user_domain() {
  [[ -n "${TLS_DOMAIN:-}" ]] || return 1
  [[ "$TLS_DOMAIN" != "$SNI_SELF" ]] || return 1
  [[ "$TLS_DOMAIN" != *.sslip.io ]] || return 1
  return 0
}

# 验解析：灰云下查 $1 的实际解析（走 Cloudflare 的公共 DoH 只读查询，
# 不需要任何令牌），结果里要有本机地址 $3 才算过。DNS 生效有延迟：
# 每 5 秒查一次、最长约 1 分钟再下结论。判定不过时把最后一次实际
# 查到的地址打出来（借 233boy 的做法：光说「没有本机地址」分不清
# 是黄云没关、记录填错还是没生效），报错文案与出口选择由调用方
# （手动域名流程）处理。
# 黄云必须关着：开了黄云解析到的是 Cloudflare 的地址，永远对不上。
verify_domain_dns() {
  local _fqdn="$1" _rtype="$2" _want="$3"
  local _tries="${DNS_VERIFY_TRIES:-12}" _sleep="${DNS_VERIFY_SLEEP:-5}"
  local _i _resp _got _want_lc _got_disp
  _want_lc=$(printf '%s' "$_want" | tr 'A-F' 'a-f')
  echo "[信息] 正在验证 $_fqdn 的解析（最长约 1 分钟）…"
  for _i in $(seq 1 "$_tries"); do
    _resp=$(curl -fsSL --max-time 10 "https://cloudflare-dns.com/dns-query?name=$_fqdn&type=$_rtype" \
      -H 'accept: application/dns-json' 2>/dev/null || true)
    _got=$(printf '%s' "$_resp" | jq -r '.Answer[]?.data // empty' 2>/dev/null || true)
    if printf '%s\n' "$_got" | tr 'A-F' 'a-f' | grep -Fxq "$_want_lc"; then
      echo "[信息] 解析验证通过：$_fqdn → $_want"
      return 0
    fi
    (( _i < _tries )) && sleep "$_sleep"
  done
  if [[ -n "$_got" ]]; then
    _got_disp=$(printf '%s\n' "$_got" | awk 'NF && !seen[$0]++ {printf "%s%s", (n++ ? ", " : ""), $0}')
    echo "[信息] 实际查到 $_fqdn 的解析：$_got_disp（里面没有本机地址 $_want）"
  else
    echo "[信息] 实际查到 $_fqdn 的解析：（没有任何记录）"
  fi
  return 1
}

# 把要加的解析记录原样打出来（手动域名流程专用）：$1=子域名 $2=类型 $3=本机 IP
print_record_block() {
  echo
  echo "请去你的域名解析面板加上这一条记录（已经加过就照这个核对一遍）："
  echo "  类型 Type：$2"
  echo "  名称 Name：$1"
  echo "  内容 Content：$3"
  echo "  代理状态 Proxy status：关（DNS only／仅限 DNS）——不要开黄云！开了黄云解析到的是 Cloudflare 的地址，验证过不了"
  echo "  TTL：自动（Auto）"
}

# 自己的域名流程（安装与菜单「改域名」共用）：一个输入提示、每轮
# 20 秒窗口。第一轮直接回车或超时不输入 = 不用域名（返回 1，不算
# 错误）；输入了域名就打印应加的记录、随即验解析（轮询约 1 分钟，
# 给传播和去面板补加记录留时间），对上就定下来（TLS_DOMAIN=该域名、
# 证书自签且 SAN 带它，返回 0）。判定不过后进入重试轮：回车 =
# 复查当前域名（不用重输，借 233boy 的节奏）、输入新域名 = 换域名
# 再查；复查或换域名仍不过、或重试轮 20 秒超时没输入，都记 1 次
# 错误：提示必须带「未解析正确域名」与「不要开黄云」两句、重打
# 应加的记录，再回到输入提示。满 3 次错误返回 1 并置
# DOMAIN_GAVE_UP=1（调用方据此回落临时域名继续，不退出安装）。
# 格式不对只警告重输、不计次。全程不要令牌，脚本不碰解析后台。
# 返回 0=已定下用户域名；1=没定（放弃或三次用完）。无可用公网 IP
# 时没法验解析，直接返回 1。
prompt_user_domain() {
  DOMAIN_GAVE_UP=0
  PROMPT_DOMAIN_SET=0
  local _ip _bare _rtype
  _ip="$(get_ip)"
  _bare="${_ip#[}"; _bare="${_bare%]}"   # 归一化：裸地址
  [[ -n "$_bare" ]] || return 1
  if [[ "$_bare" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    _rtype="A"
  elif [[ "$_bare" == *:* ]]; then
    _rtype="AAAA"
  else
    return 1
  fi
  local _timeout="${DOMAIN_PROMPT_TIMEOUT:-20}"
  local _errors=0 _attempted=0 _fqdn="" _ans="" _rc=0
  echo "[信息] 域名链（VLESS+WS+TLS）默认用临时域名 + 自签证书；有自己的域名也可以用："
  echo "       记录由你自己去域名面板加，脚本只负责打印要加的记录、再验解析，全程不要任何令牌。"
  while true; do
    _ans=""; _rc=0
    if (( _attempted == 0 && _errors == 0 )); then
      # 第一轮：回车或超时不输入 = 不用域名，不算错误
      read -t "$_timeout" -rp "要用自己的域名就输入完整子域名（如 a.example.com）；直接回车或 ${_timeout} 秒不输入 = 不用域名： " _ans || _rc=$?
      _ans=$(printf '%s' "$_ans" | tr -d '[:space:]' | tr 'A-Z' 'a-z')
      if [[ -z "$_ans" ]]; then
        echo "[信息] 不用自己的域名"
        return 1
      fi
    else
      # 重试轮：回车 = 复查当前域名（不用重输）；输入新域名 = 换域名再查；超时没输入算一次错
      read -t "$_timeout" -rp "回车 = 复查当前域名 ${_fqdn}，输入新域名 = 换域名再查（${_timeout} 秒不输入算一次错，已错 ${_errors}/3 次）： " _ans || _rc=$?
      _ans=$(printf '%s' "$_ans" | tr -d '[:space:]' | tr 'A-Z' 'a-z')
      if (( _rc > 128 )); then
        # 超时没输入：和判定不过一样记 1 次错误（不复查）
        _errors=$((_errors+1))
        echo "[错误] 未解析正确域名：${_timeout} 秒没有输入，也算一次（已错 ${_errors}/3 次）。"
        echo "提醒：不要开黄云——开了黄云，解析到的就是 Cloudflare 的地址，和本机 IP 对不上，验证过不了；保持灰云即可，装完后照结尾提示去面板打开。"
        print_record_block "$_fqdn" "$_rtype" "$_bare"
        if (( _errors >= 3 )); then
          DOMAIN_GAVE_UP=1
          return 1
        fi
        continue
      fi
      if [[ -z "$_ans" ]]; then
        # 回车：直接对当前域名再验一遍（仍走带超时的 verify_domain_dns）
        if verify_domain_dns "$_fqdn" "$_rtype" "$_bare"; then
          TLS_DOMAIN="$_fqdn"
          TLS_DOMAIN_AUTO=0
          PROMPT_DOMAIN_SET=1
          DOMAIN_ORANGE_NOTE="备注：域名 $_fqdn 这条记录现在是灰云（仅解析）。装完了，你可以去面板把它的黄云（橙色云代理）打开；注意 SSL 模式选「完全」，不要选「完全（严格）」——源站是自签证书，严格模式会报错。链接不用换。"
          echo "[信息] TLS 域名已定：$TLS_DOMAIN（自签证书，SAN 带该域名）"
          return 0
        fi
        _errors=$((_errors+1))
        echo "[错误] $_fqdn 未解析正确域名：复查了一遍仍没通过（已错 ${_errors}/3 次）。"
        echo "提醒：不要开黄云——开了黄云，解析到的就是 Cloudflare 的地址，和本机 IP 对不上，验证过不了；保持灰云即可，装完后照结尾提示去面板打开。"
        echo "其他可能原因：记录内容填错了（要填本机 IP $_bare）、或解析还没生效（刚加的记录）。"
        print_record_block "$_fqdn" "$_rtype" "$_bare"
        if (( _errors >= 3 )); then
          DOMAIN_GAVE_UP=1
          return 1
        fi
        continue
      fi
    fi
    if ! [[ "$_ans" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; then
      echo "[警告] 域名格式不对（要完整子域名、至少带一个点），重输一次（不计次）"
      continue
    fi
    _fqdn="$_ans"
    _attempted=1
    print_record_block "$_fqdn" "$_rtype" "$_bare"
    echo "[信息] 现在开始验解析（约 1 分钟）：还没去面板加记录的，现在去加还来得及。"
    if verify_domain_dns "$_fqdn" "$_rtype" "$_bare"; then
      TLS_DOMAIN="$_fqdn"
      TLS_DOMAIN_AUTO=0
      PROMPT_DOMAIN_SET=1
      DOMAIN_ORANGE_NOTE="备注：域名 $_fqdn 这条记录现在是灰云（仅解析）。装完了，你可以去面板把它的黄云（橙色云代理）打开；注意 SSL 模式选「完全」，不要选「完全（严格）」——源站是自签证书，严格模式会报错。链接不用换。"
      echo "[信息] TLS 域名已定：$TLS_DOMAIN（自签证书，SAN 带该域名）"
      return 0
    fi
    _errors=$((_errors+1))
    echo "[错误] $_fqdn 未解析正确域名：解析到的地址里没有本机地址 $_bare（已错 ${_errors}/3 次）。"
    echo "提醒：不要开黄云——开了黄云，解析到的就是 Cloudflare 的地址，和本机 IP 对不上，验证过不了；保持灰云即可，装完后照结尾提示去面板打开。"
    echo "其他可能原因：记录内容填错了（要填本机 IP $_bare）、或解析还没生效（刚加的记录）。"
    print_record_block "$_fqdn" "$_rtype" "$_bare"
    if (( _errors >= 3 )); then
      DOMAIN_GAVE_UP=1
      return 1
    fi
  done
}

# 安装时的域名提问（薄封装）：只在 install + stdin 是终端 + 没有
# 非交互标记时走 prompt_user_domain；定不下来（三轮放弃或三次错误）
# 就回落临时域名继续装——三次错误用完时多说一句：先临时装、装完
# 可在管理菜单里改域名。非交互保持原行为分毫不变。
maybe_prompt_manual_domain() {
  [[ "${ACTION:-}" == "install" ]] || return 0
  [[ -t 0 ]] || return 0
  [[ -z "${SBOX_YES:-}" ]] || return 0
  if prompt_user_domain; then
    return 0
  fi
  if [[ "${DOMAIN_GAVE_UP:-0}" == "1" ]]; then
    echo "[信息] 域名先不定了：用临时域名继续安装；装完后想用自己的域名，运行 sbc 选「改域名」即可，不用重装。"
  fi
  return 0
}

# 菜单「改域名」：跑同一套自己的域名流程；定下来就换证书（SAN 要带
# 新域名）、重写配置、重启服务、重出链接；没定下来保持当前域名不动
do_change_domain() {
  [[ -t 0 ]] || { echo "[错误] 改域名需要在终端里操作"; return 1; }
  local _old="${TLS_DOMAIN:-}"
  if ! prompt_user_domain; then
    echo "[信息] 没改成：保持当前域名 ${_old:-（临时域名）} 不变"
    return 0
  fi
  save_env
  # 证书 SAN 里是旧域名，删掉重签才带新域名
  rm -f "$SB_DIR/cert.pem" "$SB_DIR/private.key"
  gen_certs
  # 新域名刚验完解析：顺手试签真证书（意向先行，服务起来后验证步把关）
  TLS_CERT_MODE="self"; TLS_ACME_CHALLENGE=""
  ensure_vtls_cert 1
  save_env
  write_config
  restart_service
  acme_verify_or_fallback || true
  print_links
  [[ -n "${DOMAIN_ORANGE_NOTE:-}" ]] && echo "$DOMAIN_ORANGE_NOTE"
}

# 菜单「更新证书」：有自有域名先试 ACME 真证书（ensure 定意向、写
# 配置重启、验证步把关），签成最好；签不成、或本来就是临时域名，
# 就重签自签证书（原「更新自签证书」的行为）。env 已由菜单载入。
do_update_cert() {
  if is_user_domain; then
    echo "[信息] 为 $TLS_DOMAIN 更新证书：先试 Let's Encrypt 真证书…"
    TLS_CERT_MODE="self"; TLS_ACME_CHALLENGE=""
    ensure_vtls_cert 1
    if [[ "${TLS_CERT_MODE:-self}" == "acme" ]]; then
      write_config
      restart_service
      if acme_verify_or_fallback; then
        print_links
        echo "[完成] 已换上 Let's Encrypt 真证书（核心自动续期，链接已去掉允许不安全）"
        return 0
      fi
      # 验证步已回落自签并重写配置重启；下面再把自签本身换新一张
    fi
  fi
  rm -f "$SB_DIR/cert.pem" "$SB_DIR/private.key" "$SB_DIR/hy2-cert.pem" "$SB_DIR/hy2-key.pem"
  gen_hy2_cert; gen_certs; write_config; restart_service
  if is_user_domain; then
    echo "[完成] 自签证书已更新（真证书这次没签成，放行 80/443 后再来这里重试即可）"
  else
    echo "[完成] 自签证书已更新（域名与链接不变）"
  fi
}

# 公网 IP 探测不到时让装机人手填（仅交互安装）：挂在 load_or_gen_identity
# 里、ensure_tls_domain 之前——安装流程第一次需要公网 IP 的上游，只问这
# 一次，后面的 sslip 兜底、证书 SAN、链接生成都经 get_ip 读同一个值。
# 填对了存进 auto.env 的 PUBLIC_IP，重跑不再问。每次输入限时 20 秒，
# 超时和填错、空填一样算一次失败，三次用完就明确提示并退出安装
# （exit 1）：地址不对硬装出来的链接全是坏的，不如停下来问清。
# 非交互（管道 / SBOX_YES / 已存 PUBLIC_IP / 探测得到）不问、行为不变。
maybe_prompt_public_ip() {
  [[ "${ACTION:-}" == "install" ]] || return 0
  [[ -t 0 ]] || return 0
  [[ -z "${SBOX_YES:-}" ]] || return 0
  [[ -z "${PUBLIC_IP:-}" ]] || return 0
  [[ -n "$(get_ip)" ]] && return 0
  echo "[信息] 未能自动检测到本机公网 IP（几个探测站都没给出结果）"
  local _timeout="${IP_PROMPT_TIMEOUT:-20}"
  local _try=0 _in="" _rc=0
  while (( _try < 3 )); do
    _try=$((_try+1))
    _in=""; _rc=0
    read -t "$_timeout" -rp "请输入这台机器的公网 IP（IPv4 或 IPv6，${_timeout} 秒内输入，第 ${_try}/3 次）： " _in || _rc=$?
    if (( _rc > 128 )); then
      # read 超时返回码 >128；半截输入也不算数，和空填一样计一次
      echo "[警告] ${_timeout} 秒内没输完（超时也算一次），还剩 $((3-_try)) 次机会"
      continue
    fi
    _in=$(printf '%s' "$_in" | tr -d '[:space:]')
    _in="${_in#[}"; _in="${_in%]}"
    if [[ "$_in" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] \
       || { [[ "$_in" == *:* ]] && [[ "$_in" =~ ^[0-9a-fA-F:]+$ ]]; }; then
      PUBLIC_IP="$_in"
      echo "[信息] 已采用手动填写的公网 IP：$PUBLIC_IP（会存入配置，证书 SAN 与链接都用它，重跑不再问）"
      return 0
    fi
    echo "[警告] 这个 IP 格式不对（空填也算一次），还剩 $((3-_try)) 次机会"
  done
  echo "[错误] 未取得可用的公网 IP，安装终止；确认这台机器的公网 IP 后重跑安装即可。"
  exit 1
}

# TLS 域名决策：已有域名（含重跑时 env 里存着的自己的域名）直接沿用、
# 不再走手动步；没有时交互安装先问一句要不要用自己的域名（手动流，
# 见 maybe_prompt_manual_domain）；不要或非交互时用公网 IP 生成
# sslip.io 临时域名（解析直达本机、立即可用；IPv4 点换横杠、IPv6
# 冒号换横杠，两种写法均可解析出对应记录），走自签直连。
ensure_tls_domain() {
  if [[ -n "${TLS_DOMAIN:-}" ]]; then
    TLS_DOMAIN_AUTO="${TLS_DOMAIN_AUTO:-0}"
    return 0
  fi
  maybe_prompt_manual_domain
  if [[ -n "${TLS_DOMAIN:-}" ]]; then
    return 0
  fi
  local _ip _bare
  _ip="$(get_ip)"
  _bare="${_ip#[}"; _bare="${_bare%]}"   # 归一化：裸地址
  if [[ "$_bare" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    TLS_DOMAIN="${_bare//./-}.sslip.io"
    TLS_DOMAIN_AUTO=1
    echo "[信息] TLS 域名自动生成（临时）：$TLS_DOMAIN（自签直连）"
  elif [[ "$_bare" == *:* ]]; then
    # sslip.io 的 IPv6 写法：冒号换横杠（:: 自然变成 --），可解析出 AAAA
    TLS_DOMAIN="${_bare//:/-}.sslip.io"
    TLS_DOMAIN_AUTO=1
    echo "[信息] TLS 域名自动生成（临时，IPv6）：$TLS_DOMAIN（自签直连）"
  else
    TLS_DOMAIN="$SNI_SELF"
    TLS_DOMAIN_AUTO=1
    echo "[警告] 未能获取公网 IP（v4/v6 均无），TLS 域名暂用 $SNI_SELF（链接以 IP 直连）"
  fi
}

# 本机全部可达地址（前后带空格、空格分隔，一次运行内缓存）：公网查询到的
# IP（v4 或 v6）+ 网卡上的全部 global 地址。证书 SAN 收集本机 IP 时用。
_LOCAL_IP_SET=""
local_ip_set() {
  if [[ -n "$_LOCAL_IP_SET" ]]; then printf '%s' "$_LOCAL_IP_SET"; return 0; fi
  local _set="" _ip _a
  _ip=$(get_ip | tr -d '[]')
  [[ -n "$_ip" ]] && _set="$_ip"
  if command -v ip >/dev/null 2>&1; then
    for _a in $(ip -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1); do
      [[ " $_set " == *" $_a "* ]] || _set="$_set $_a"
    done
  fi
  _LOCAL_IP_SET=" $_set "
  printf '%s' "$_LOCAL_IP_SET"
}

# base64 不换行（兼容 busybox）
b64() { base64 -w 0 2>/dev/null || base64 | tr -d '\n'; }

#----------------------------- 6. 身份与端口 ----------------------------------
# 为域名 TLS 入站挑端口：优选 Cloudflare 中转支持的 HTTPS 端口（将来套 CF 不用再换），
# 全被占才回退随机端口（回退后该链直连可用，但不能套 Cloudflare 橙色云）
pick_vtls_port() {
  local allocated="$1" p
  for p in 443 8443 2053 2083 2087 2096; do
    if [[ "$allocated" != *" $p "* ]] && ! port_in_use "$p"; then
      echo "$p"
      return 0
    fi
  done
  rand_port "$allocated"
}

# 落盘身份/端口/域名状态（600 权限）。PORT_VLESS 是旧版七合一对 Reality
# 端口的键名，同值双写一份：万一回退到旧版脚本，旧版能原样读回不漂移
save_env() {
  cat > "$ENV_FILE" <<EOF
UUID="$UUID"
PRIVKEY="$PRIVKEY"
PUBKEY="$PUBKEY"
SHORTID="$SHORTID"
PORT_REALITY="$PORT_REALITY"
PORT_VLESS="$PORT_REALITY"
PORT_VMESS="$PORT_VMESS"
PORT_HY2="$PORT_HY2"
PORT_TUIC="$PORT_TUIC"
PORT_ANYTLS="$PORT_ANYTLS"
PORT_SS="$PORT_SS"
PORT_TROJAN="$PORT_TROJAN"
PORT_NAIVE="$PORT_NAIVE"
PORT_VTLS="${PORT_VTLS:-}"
HY2_PASS="$HY2_PASS"
SS_KEY="$SS_KEY"
TROJAN_PASS="$TROJAN_PASS"
TUIC_PASS="$TUIC_PASS"
ANYTLS_PASS="$ANYTLS_PASS"
NAIVE_USER="$NAIVE_USER"
NAIVE_PASS="$NAIVE_PASS"
TLS_DOMAIN="${TLS_DOMAIN:-}"
TLS_DOMAIN_AUTO="${TLS_DOMAIN_AUTO:-1}"
TLS_CERT_MODE="${TLS_CERT_MODE:-self}"
TLS_ACME_CHALLENGE="${TLS_ACME_CHALLENGE:-}"
PUBLIC_IP="${PUBLIC_IP:-}"
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
  TROJAN_PASS=$(openssl rand -hex 16)
  TUIC_PASS=$(openssl rand -hex 16)
  ANYTLS_PASS=$(openssl rand -hex 16)
  NAIVE_USER=$(openssl rand -hex 6)
  NAIVE_PASS=$(openssl rand -hex 16)
  if [[ -z "$PRIVKEY" || -z "$PUBKEY" || -z "$SHORTID" || -z "$HY2_PASS" || -z "$SS_KEY" \
     || -z "$TROJAN_PASS" || -z "$TUIC_PASS" || -z "$ANYTLS_PASS" || -z "$NAIVE_USER" || -z "$NAIVE_PASS" ]]; then
    echo "[错误] 密钥/密码生成失败"; exit 1
  fi
  local used=" "
  PORT_REALITY=$(rand_port "$used") || { echo "[错误] 端口分配失败"; exit 1; }
  used+=" $PORT_REALITY "
  PORT_VMESS=$(rand_port "$used") || { echo "[错误] 端口分配失败"; exit 1; }
  used+=" $PORT_VMESS "
  PORT_HY2=$(rand_port "$used") || { echo "[错误] 端口分配失败"; exit 1; }
  used+=" $PORT_HY2 "
  PORT_TUIC=$(rand_port "$used") || { echo "[错误] 端口分配失败"; exit 1; }
  used+=" $PORT_TUIC "
  PORT_ANYTLS=$(rand_port "$used") || { echo "[错误] 端口分配失败"; exit 1; }
  used+=" $PORT_ANYTLS "
  PORT_SS=$(rand_port "$used") || { echo "[错误] 端口分配失败"; exit 1; }
  used+=" $PORT_SS "
  PORT_TROJAN=$(rand_port "$used") || { echo "[错误] 端口分配失败"; exit 1; }
  used+=" $PORT_TROJAN "
  PORT_NAIVE=$(rand_port "$used") || { echo "[错误] 端口分配失败"; exit 1; }
  used+=" $PORT_NAIVE "
  PORT_VTLS=$(pick_vtls_port "$used") || { echo "[错误] 端口分配失败"; exit 1; }
  echo "[信息] 端口分配：Reality=$PORT_REALITY VMess-WS=$PORT_VMESS HY2=$PORT_HY2 TUIC=$PORT_TUIC AnyTLS=$PORT_ANYTLS SS=$PORT_SS Trojan=$PORT_TROJAN Naive=$PORT_NAIVE VLESS-WS-TLS=$PORT_VTLS"
  save_env
}

# 缺失凭据/端口的统一补齐（已有值一律不动）：逐个显式分配并校验，不用
# 链式 &&——失败时会留下空值直到写配置才炸。$1=1 表示来源是旧版七合一
# env/sb.json：它的 HY2/TUIC/AnyTLS 密码就是 UUID 本身，按原值补齐，
# 这三条链接逐字不变；其余来源（本版早期 env 等）随机生成。
fill_missing_identity() {
  local _legacy="${1:-0}" _filled=0 _pv _p
  if [[ -z "${HY2_PASS:-}" ]]; then
    if [[ "$_legacy" == "1" ]]; then HY2_PASS="$UUID"; else HY2_PASS=$(openssl rand -hex 16); fi
    _filled=1
  fi
  if [[ -z "${TUIC_PASS:-}" ]]; then
    if [[ "$_legacy" == "1" ]]; then TUIC_PASS="$UUID"; else TUIC_PASS=$(openssl rand -hex 16); fi
    _filled=1
  fi
  if [[ -z "${ANYTLS_PASS:-}" ]]; then
    if [[ "$_legacy" == "1" ]]; then ANYTLS_PASS="$UUID"; else ANYTLS_PASS=$(openssl rand -hex 16); fi
    _filled=1
  fi
  for _pv in TROJAN_PASS NAIVE_PASS; do
    if [[ -z "${!_pv:-}" ]]; then
      printf -v "$_pv" '%s' "$(openssl rand -hex 16)"
      _filled=1
    fi
  done
  if [[ -z "${SS_KEY:-}" ]]; then
    SS_KEY=$(openssl rand -base64 16 | tr -d '\n')
    _filled=1
  fi
  if [[ -z "${NAIVE_USER:-}" ]]; then
    NAIVE_USER=$(openssl rand -hex 6)
    _filled=1
  fi
  # 端口：已有但非数字的坏值同样按缺失处理，避免写进配置才炸
  local used=" "
  for _pv in PORT_REALITY PORT_VMESS PORT_HY2 PORT_TUIC PORT_ANYTLS PORT_SS PORT_TROJAN PORT_NAIVE PORT_VTLS; do
    if [[ "${!_pv:-}" =~ ^[0-9]+$ ]]; then used+=" ${!_pv} "; fi
  done
  for _pv in PORT_REALITY PORT_VMESS PORT_HY2 PORT_TUIC PORT_ANYTLS PORT_SS PORT_TROJAN PORT_NAIVE; do
    if ! [[ "${!_pv:-}" =~ ^[0-9]+$ ]]; then
      _p=$(rand_port "$used") || { echo "[错误] 端口分配失败，无法继续"; exit 1; }
      printf -v "$_pv" '%s' "$_p"
      used+=" $_p "
      _filled=1
    fi
  done
  if ! [[ "${PORT_VTLS:-}" =~ ^[0-9]+$ ]]; then
    PORT_VTLS=$(pick_vtls_port "$used") || { echo "[错误] 端口分配失败，无法继续"; exit 1; }
    _filled=1
  fi
  if (( _filled == 1 )); then
    echo "[信息] 已为新增协议补齐凭据与端口（原有身份与端口不变）"
  fi
  return 0
}

# 从已有 sb.json 导入身份与端口（env 丢失时的兜底）：按 type 定位入站
# （旧版七合一与本版的入站集合不同，按下标取会串位）。Reality 公钥无法
# 从私钥在 shell 里推导，旧版会把公钥存 $SB_DIR/public.key，缺它不用。
import_identity_from_config() {
  local _sel='[.inbounds[] | select(.type=="vless" and (.tls.reality.enabled==true))][0]'
  local _uuid _priv _sid _pub=""
  _uuid=$(jq -r "$_sel.users[0].uuid // empty" "$SB_DIR/sb.json" 2>/dev/null || true)
  [[ -n "$_uuid" ]] || return 1
  _priv=$(jq -r "$_sel.tls.reality.private_key // empty" "$SB_DIR/sb.json" 2>/dev/null || true)
  _sid=$(jq -r "$_sel.tls.reality.short_id[0] // empty" "$SB_DIR/sb.json" 2>/dev/null || true)
  [[ -n "$_priv" && -n "$_sid" ]] || return 1
  [[ -f "$SB_DIR/public.key" ]] && _pub=$(cat "$SB_DIR/public.key" 2>/dev/null || true)
  [[ -n "$_pub" ]] || return 1
  UUID="$_uuid"; PRIVKEY="$_priv"; PUBKEY="$_pub"; SHORTID="$_sid"
  PORT_REALITY=$(jq -r "$_sel.listen_port // empty" "$SB_DIR/sb.json" 2>/dev/null || true)
  PORT_VMESS=$(jq -r '[.inbounds[] | select(.type=="vmess")][0].listen_port // empty' "$SB_DIR/sb.json" 2>/dev/null || true)
  PORT_HY2=$(jq -r '[.inbounds[] | select(.type=="hysteria2")][0].listen_port // empty' "$SB_DIR/sb.json" 2>/dev/null || true)
  PORT_TUIC=$(jq -r '[.inbounds[] | select(.type=="tuic")][0].listen_port // empty' "$SB_DIR/sb.json" 2>/dev/null || true)
  PORT_ANYTLS=$(jq -r '[.inbounds[] | select(.type=="anytls")][0].listen_port // empty' "$SB_DIR/sb.json" 2>/dev/null || true)
  PORT_VTLS=$(jq -r '[.inbounds[] | select(.type=="vless" and (.transport.type=="ws"))][0].listen_port // empty' "$SB_DIR/sb.json" 2>/dev/null || true)
  # 旧配置里这三家的密码就是 UUID（旧版生成方式），按原值带上
  HY2_PASS="$UUID"; TUIC_PASS="$UUID"; ANYTLS_PASS="$UUID"
  return 0
}

load_or_gen_identity() {
  if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    # 旧版七合一（coexist-v1.1.4 及更早）env 兼容：Reality 端口键名是
    # PORT_VLESS，其余 UUID/密钥/VMess/HY2/TUIC/AnyTLS/VTLS 键名与本版
    # 一致，直接沿用——身份完整性只看 UUID/密钥四件套，缺的新协议凭据
    # 与端口走统一补齐，UUID 与已有端口一律不漂移
    local _legacy=0
    if [[ -z "${PORT_REALITY:-}" && -n "${PORT_VLESS:-}" ]]; then
      PORT_REALITY="$PORT_VLESS"
      _legacy=1
    fi
    # 旧版的真证书标记（TLS_ACME=1）映射到本版的证书模式
    if [[ "${TLS_ACME:-0}" == "1" && -z "${TLS_CERT_MODE:-}" ]]; then
      TLS_CERT_MODE="acme"
    fi
    if [[ -n "${UUID:-}" && -n "${PRIVKEY:-}" && -n "${PUBKEY:-}" && -n "${SHORTID:-}" ]]; then
      echo "[信息] 检测到已有配置，身份与端口保持不变（幂等重跑）"
      fill_missing_identity "$_legacy"
      maybe_prompt_public_ip
      ensure_tls_domain
      save_env
      return 0
    fi
    echo "[警告] 已有配置不完整，将尝试从现有配置导入或重新生成身份信息"
  fi
  if [[ -f "$SB_DIR/sb.json" ]] && import_identity_from_config; then
    echo "[信息] 已从现有 sing-box 配置导入身份与端口，客户端链接保持不变"
    fill_missing_identity 1
    maybe_prompt_public_ip
    ensure_tls_domain
    save_env
    return 0
  fi
  gen_identity
  maybe_prompt_public_ip
  ensure_tls_domain
  save_env
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

# Trojan/TUIC/AnyTLS/Naive/域名链共用的自签证书（CN=$SNI_SELF）；
# HY2 用自己的 hy2-cert.pem（既有链接的 sni 不变），两者互不影响
gen_certs() {
  if [[ -f "$SB_DIR/cert.pem" && -f "$SB_DIR/private.key" ]]; then
    echo "[信息] 自签证书已存在，跳过生成"
    return 0
  fi
  # SAN 带上自签伪装域名；有 TLS 域名时一并带上，域名链用同一张证书
  local _san="DNS:$SNI_SELF"
  if [[ -n "${TLS_DOMAIN:-}" && "$TLS_DOMAIN" != "$SNI_SELF" ]]; then
    _san="DNS:$SNI_SELF,DNS:$TLS_DOMAIN"
  fi
  # 再带上本机公网 IP（IP SAN）：纯 IP 型机器（无域名）按 IP 直连时，
  # 不允许 insecure 的客户端靠它完成 TLS 校验；拿不到的地址跳过该项
  local _lip
  for _lip in $(local_ip_set); do
    if [[ "$_lip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ || "$_lip" == *:* ]]; then
      _san="$_san,IP:$_lip"
    fi
  done
  echo "[信息] 生成自签证书（CN=$SNI_SELF，SAN=$_san）…"
  openssl ecparam -genkey -name prime256v1 -out "$SB_DIR/private.key" 2>/dev/null
  # 必须带 SAN：现代 TLS 会拒绝只有 CN 的证书
  # （x509: certificate relies on legacy Common Name field）
  if ! openssl req -new -x509 -days 36500 -key "$SB_DIR/private.key" \
      -out "$SB_DIR/cert.pem" -subj "/CN=$SNI_SELF" \
      -addext "subjectAltName=$_san" 2>/dev/null; then
    # 老版本 OpenSSL 不支持 -addext，回退到配置文件方式
    local _cnf
    _cnf=$(mktemp)
    cat > "$_cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $SNI_SELF
[ext]
subjectAltName = $_san
EOF
    openssl req -new -x509 -days 36500 -key "$SB_DIR/private.key" \
      -out "$SB_DIR/cert.pem" -config "$_cnf" 2>/dev/null
    rm -f "$_cnf"
  fi
  [[ -f "$SB_DIR/cert.pem" ]] || { echo "[错误] 证书生成失败"; exit 1; }
  echo "[信息] 自签证书生成成功"
}

#----------------------------- 6.5 VTLS 真证书（核心内置 ACME） ----------------
# 自有域名验完解析后顺手试签 Let's Encrypt 真证书：用官方核心
# （sing-box 1.14）内置的 ACME（certificate provider 形态，证书与账户
# 存在 $SB_DIR/acme 下、按域名分目录，核心后台自动续期），脚本只做
# 三件事：按本机情况排验证方式、服务起来后限时验呈现的证书是不是
# 公网受信任的真证书、不行就回落自签。不要令牌、不问邮箱（核心以
# 空 contact 建账户，实测可签）。失败不许卡死安装：进程在签发失败
# 时照常运行（实测），脚本这边也有界等待 + 回落兜底。
# 注意：cert.pem 是 TUIC/AnyTLS/Trojan/Naive/VTLS 五家共用的自签，
# 真证书只给 VTLS 一家用（provider 独立存储），互不影响。

# 仓里已签下的证书路径：$1=域名，命中回显路径
acme_stored_cert() {
  local _f
  for _f in "$SB_DIR/acme/certificates"/*/"$1/$1.crt"; do
    [[ -f "$_f" ]] && { printf '%s' "$_f"; return 0; }
  done
  return 1
}

# 验证方式判定（输出空格分隔的尝试顺序，空 = 一条都走不通）：
# HTTP-01 要 80 空闲（核心临时在 80 应答）；TLS-ALPN-01 在 VTLS 就
# 是 443 时借它自己的监听应答（最稳），VTLS 不在 443 时核心要自己
# 占 443 应答、需 443 空闲。排序：VTLS=443 先 ALPN 后 HTTP（443 是
# 这条链必须放行的口子）；VTLS≠443 先 HTTP 后 ALPN（80 最常放行，
# 且日后用户开黄云时 HTTP 还能续期，ALPN 只作 443 空闲时的兜底）。
# 80 被已有网站占用绝不抢占——port_in_use 判到占用就整条跳过。
acme_challenge_plan() {
  local _http=0 _alpn=0 _plan=""
  port_in_use 80 || _http=1
  if [[ "${PORT_VTLS:-}" == "443" ]] || ! port_in_use 443; then _alpn=1; fi
  if [[ "${PORT_VTLS:-}" == "443" ]]; then
    (( _alpn == 1 )) && _plan="$_plan tls-alpn-01"
    (( _http == 1 )) && _plan="$_plan http-01"
  else
    (( _http == 1 )) && _plan="$_plan http-01"
    (( _alpn == 1 )) && _plan="$_plan tls-alpn-01"
  fi
  printf '%s' "${_plan# }"
}

# 给 HTTP-01 在本地防火墙开 80/tcp（与 open_firewall 同三套机制）。
# 规则留着不撤：核心续期时还要在 80 应答，撤了续期必挂。
acme_open_port80() {
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --permanent --add-port="80/tcp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "80/tcp" >/dev/null 2>&1 || true
  fi
  if command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null \
      || iptables -I INPUT 1 -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
  fi
  if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null \
      || ip6tables -I INPUT 1 -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
  fi
}

# 证书模式决策（写配置前调用）：$1=1 才真去试签（域名刚在交互里定
# 下、或菜单里明确选了更新证书/改域名时）；不试签时只维护既有状态
# ——已是 acme 就保持 acme（仓里有证书核心直接用，没有核心起来后
# 自己补签，验证步把关），其余照旧自签。试签也只定「意向」：配置
# 先按 acme 写，服务起来后由 acme_verify_or_fallback 验真伪。
ensure_vtls_cert() {
  local _attempt="${1:-0}"
  ACME_CHALLENGES=""
  if ! is_user_domain; then
    TLS_CERT_MODE="self"; TLS_ACME_CHALLENGE=""
    return 0
  fi
  local _crt
  if [[ "${TLS_CERT_MODE:-self}" == "acme" ]] && _crt=$(acme_stored_cert "$TLS_DOMAIN") \
     && openssl x509 -checkend 2592000 -noout -in "$_crt" >/dev/null 2>&1; then
    echo "[信息] 已有 Let's Encrypt 真证书（$TLS_DOMAIN，到期还远，核心自动续期），继续使用"
    return 0
  fi
  if [[ "$_attempt" != "1" ]]; then
    if [[ "${TLS_CERT_MODE:-self}" == "acme" ]]; then
      # 重跑不主动试签，但已是 acme 的把尝试顺序备好，验证步可换方式兜底
      ACME_CHALLENGES=$(acme_challenge_plan)
      TLS_ACME_CHALLENGE="${ACME_CHALLENGES%% *}"
    else
      TLS_CERT_MODE="self"; TLS_ACME_CHALLENGE=""
    fi
    return 0
  fi
  ACME_CHALLENGES=$(acme_challenge_plan)
  if [[ -z "$ACME_CHALLENGES" ]]; then
    TLS_CERT_MODE="self"; TLS_ACME_CHALLENGE=""
    echo "[警告] 80 与 443 都被占用，这次没法试签真证书：域名链先用自签证书（运行 sbc 选「更新证书」可重试）"
    return 0
  fi
  TLS_CERT_MODE="acme"
  TLS_ACME_CHALLENGE="${ACME_CHALLENGES%% *}"
  # 80 只在真轮到 HTTP-01 时才开（ALPN 先成就不多开一个口子）
  [[ "$TLS_ACME_CHALLENGE" == "http-01" ]] && acme_open_port80
  echo "[信息] $TLS_DOMAIN 解析已验通，顺手试签 Let's Encrypt 真证书（核心内置 ACME，先试 $TLS_ACME_CHALLENGE，签发最长约 3 分钟，不要关闭终端）…"
  echo "       签不成会自动回落自签证书，安装照常完成。"
}

# VTLS 当前呈现的证书是不是公网受信任的（链校验 + 域名匹配都过）。
# staging 证书与自签都过不了系统信任校验，天然被挡下。
vtls_cert_trusted() {
  local _out
  _out=$(echo | openssl s_client -connect "127.0.0.1:${PORT_VTLS}" -servername "$TLS_DOMAIN" \
    -verify_hostname "$TLS_DOMAIN" 2>/dev/null || true)
  if [[ -z "$_out" ]]; then
    # 老版 openssl 的 s_client 没有 -verify_hostname：退回只验链
    _out=$(echo | openssl s_client -connect "127.0.0.1:${PORT_VTLS}" -servername "$TLS_DOMAIN" 2>/dev/null || true)
  fi
  printf '%s' "$_out" | grep -q "Verify return code: 0"
}

# 以真实客户端姿势验域名链：不跳过证书校验地做一次 WS 握手（curl
# 会带 ALPN 并验信任链），101 才算真能用。只验 s_client 的信任链会
# 假通过——ALPN 协商坏了时 s_client 照样过、真实客户端全灭（实测）。
vtls_real_handshake() {
  local _code
  _code=$(curl -s --max-time 8 --resolve "${TLS_DOMAIN}:${PORT_VTLS}:127.0.0.1" \
    "https://${TLS_DOMAIN}:${PORT_VTLS}/${UUID}-vt" \
    -H "Connection: Upgrade" -H "Upgrade: websocket" \
    -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: x3JJHMbDL1EzLkh9GBhXDw==" \
    -o /dev/null -w '%{http_code}' 2>/dev/null || true)
  [[ "$_code" == "101" ]]
}

# 服务起来后的把关（acme 意向时调用）：每 5 秒验一次（呈现证书受
# 信任 + 真实 WS 握手能通），约 75 秒没等到就换下一种验证方式重
# 写配置重启再验；全不行回落自签（重写配置 + 重启 + 提示菜单「更
# 新证书」可重试）。成功与回落都会 save_env 落定模式。返回 0=真
# 证书生效，1=已回落自签。
acme_verify_or_fallback() {
  [[ "${TLS_CERT_MODE:-self}" == "acme" ]] || return 0
  local _tries="${ACME_VERIFY_TRIES:-15}" _i _rest
  while true; do
    for _i in $(seq 1 "$_tries"); do
      if vtls_cert_trusted && vtls_real_handshake; then
        echo "[信息] Let's Encrypt 真证书已生效（$TLS_DOMAIN，核心自动续期）"
        DOMAIN_ORANGE_NOTE="备注：域名 $TLS_DOMAIN 用的是 Let's Encrypt 真证书（核心自动续期），VTLS 链接已去掉「允许不安全」。现在可以去面板把这条记录的黄云打开，SSL 模式选「完全（严格）」即可；链接不用换。"
        save_env
        return 0
      fi
      sleep 5
    done
    _rest="${ACME_CHALLENGES#* }"
    if [[ -n "$_rest" && "$_rest" != "$ACME_CHALLENGES" ]]; then
      ACME_CHALLENGES="$_rest"
      TLS_ACME_CHALLENGE="${_rest%% *}"
      echo "[警告] 真证书还没签下来，换 $TLS_ACME_CHALLENGE 方式再试一轮（最长约 1 分钟）…"
      [[ "$TLS_ACME_CHALLENGE" == "http-01" ]] && acme_open_port80
      write_config
      restart_service
      continue
    fi
    break
  done
  echo "[警告] 真证书这次没签成（多半是 80/443 公网进不来或被占用），域名链回落自签证书，安装照常完成；放行端口后运行 sbc 选「更新证书」可重试。"
  TLS_CERT_MODE="self"
  TLS_ACME_CHALLENGE=""
  ACME_CHALLENGES=""
  DOMAIN_ORANGE_NOTE="备注：域名 $TLS_DOMAIN 这条记录现在是灰云（仅解析）。装完了，你可以去面板把它的黄云（橙色云代理）打开；注意 SSL 模式选「完全」，不要选「完全（严格）」——源站是自签证书，严格模式会报错。链接不用换。真证书这次没签成，放行 80/443 后运行 sbc 选「更新证书」可重试。"
  save_env
  write_config
  restart_service
  return 1
}

#----------------------------- 7. 写配置 --------------------------------------
write_config() {
  echo "[信息] 写入 sing-box 配置（九个入站）…"
  # 域名 TLS 入站的 tls 段两种形态：默认本地自签证书（与七合一 VTLS
  # 口径对齐，链接带 allowInsecure）；自有域名且 ACME 意向成立时改走
  # 核心内置 ACME 真证书（certificate provider，见 6.5 节）——意向只
  # 是先按 acme 写配置，服务起来后验证步验到真证书才算数，验不到
  # 回落自签重写。其余入站始终用共用自签 cert.pem，不受影响。
  local _tls_sni="${TLS_DOMAIN:-$SNI_SELF}" vtls_tls _acme_json=""
  if [[ "${TLS_CERT_MODE:-self}" == "acme" ]] && is_user_domain; then
    local _dis_http=false _dis_alpn=false
    case "${TLS_ACME_CHALLENGE:-}" in
      http-01) _dis_alpn=true ;;
      tls-alpn-01) _dis_http=true ;;
    esac
    _acme_json="  \"certificate_providers\": [{\"type\": \"acme\", \"tag\": \"acme-vtls\", \"domain\": [\"$_tls_sni\"], \"data_directory\": \"$SB_DIR/acme\", \"disable_http_challenge\": $_dis_http, \"disable_tls_alpn_challenge\": $_dis_alpn}],
"
    # alpn 必须显式写 http/1.1：provider 模式下核心的 TLS 配置不带
    # 它时，带 ALPN 的客户端（curl / 多数 sing-box 客户端）会被服务器
    # 以 no_application_protocol 告警直接拒绝（USARM 实测定位）；
    # 文件证书模式没这毛病，故只在 acme 分支加
    vtls_tls="\"enabled\": true, \"server_name\": \"$_tls_sni\", \"alpn\": [\"http/1.1\"], \"certificate_provider\": \"acme-vtls\""
  else
    vtls_tls="\"enabled\": true, \"server_name\": \"$_tls_sni\", \"certificate_path\": \"$SB_DIR/cert.pem\", \"key_path\": \"$SB_DIR/private.key\""
  fi
  # WARP 出站：状态在 warp.env（菜单 WARP 出站管理）；关闭或注册参数不全时
  # 不生成任何 WARP 配置（零成本），换端口/身份/域名等重写配置时原样保留
  load_warp_env
  local _warp_tail="" _ep_tail="" _warp_route=""
  if [[ "$WARP_MODE" != "off" ]]; then
    if warp_profile_complete; then
      local _ep
      _ep=$(warp_endpoint_json)
      _ep_tail=",
  \"endpoints\": [$_ep]"
      if [[ "$WARP_MODE" == "all" ]]; then
        _warp_route="\"final\": \"warp\""
      else
        # ipv4 模式不用 ip_cidr 分流规则（旧写法 route 里放 0.0.0.0/0→warp
        # + final: direct）：真机二分实测定位——那条规则会把 WireGuard
        # endpoint 自己连 peer 的握手包也圈进尚未建好的隧道，握手永远发
        # 不出去；域名目标又不吃 ip_cidr、直接落直连，两头落空。故 ipv4
        # 模式的 route 与 all 一样收敛为 final: warp，「只让 IPv4 目的地
        # 走 WARP」的分流改由 restricted_net_tail 的 ipv4_only 解析策略
        # 实现：无 v6 出口时域名只解析出 v4、再经 WARP 出去（该尾段靠
        # WARP_MODE 区分 ipv4 与 all，ipv4 时 ② 照常启用、不叠 reject）。
        _warp_route="\"final\": \"warp\""
      fi
    else
      echo "[警告] WARP 模式为 $WARP_MODE 但注册参数不齐全，本次配置不启用 WARP（可在菜单「WARP 出站」里重新开启）"
    fi
  fi
  # 尾段组装：受限/无 v6 出口自适应（restricted_net_tail）判假时返回空；判真时
  # 其 route 对象需与 WARP 的 route 字段合并（把 _warp_route 作为 $1 传入）
  local _net_tail
  _net_tail=$(restricted_net_tail "$_warp_route")
  if [[ -n "$_warp_route" && -z "$_net_tail" ]]; then
    _warp_tail="$_ep_tail,
  \"route\": {$_warp_route}"
  else
    _warp_tail="$_ep_tail$_net_tail"
  fi
  if restricted_net_env; then echo "[信息] 检测到受限容器网络，已启用系统 DNS 自适应"; fi
  if no_v6_egress; then echo "[信息] 检测到本机无 IPv6 出口，已启用 IPv4 优先解析（IPv6 目标快速失败、回落 v4）"; fi
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
      "type": "vmess", "tag": "vmess-ws-in",
      "listen": "::", "listen_port": $PORT_VMESS,
      "users": [{"uuid": "$UUID", "alterId": 0}],
      "transport": {
        "type": "ws", "path": "${UUID}-vm",
        "max_early_data": 2048, "early_data_header_name": "Sec-WebSocket-Protocol"
      },
      "tls": {"enabled": false}
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
      "type": "tuic", "tag": "tuic-in",
      "listen": "::", "listen_port": $PORT_TUIC,
      "users": [{"uuid": "$UUID", "password": "$TUIC_PASS"}],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true, "alpn": ["h3"],
        "certificate_path": "$SB_DIR/cert.pem",
        "key_path": "$SB_DIR/private.key"
      }
    },
    {
      "type": "anytls", "tag": "anytls-in",
      "listen": "::", "listen_port": $PORT_ANYTLS,
      "users": [{"password": "$ANYTLS_PASS"}],
      "padding_scheme": [],
      "tls": {
        "enabled": true,
        "certificate_path": "$SB_DIR/cert.pem",
        "key_path": "$SB_DIR/private.key"
      }
    },
    {
      "type": "shadowsocks", "tag": "ss-in",
      "listen": "::", "listen_port": $PORT_SS,
      "method": "$SS_METHOD",
      "password": "$SS_KEY"
    },
    {
      "type": "trojan", "tag": "trojan-in",
      "listen": "::", "listen_port": $PORT_TROJAN,
      "users": [{"password": "$TROJAN_PASS"}],
      "tls": {
        "enabled": true, "server_name": "$SNI_SELF",
        "certificate_path": "$SB_DIR/cert.pem",
        "key_path": "$SB_DIR/private.key"
      }
    },
    {
      "type": "naive", "tag": "naive-in",
      "listen": "::", "listen_port": $PORT_NAIVE,
      "users": [{"username": "$NAIVE_USER", "password": "$NAIVE_PASS"}],
      "tls": {
        "enabled": true, "server_name": "$SNI_SELF",
        "certificate_path": "$SB_DIR/cert.pem",
        "key_path": "$SB_DIR/private.key"
      }
    },
    {
      "type": "vless", "tag": "vtls-in",
      "listen": "::", "listen_port": ${PORT_VTLS:-443},
      "users": [{"uuid": "$UUID"}],
      "transport": {
        "type": "ws", "path": "${UUID}-vt",
        "max_early_data": 2048, "early_data_header_name": "Sec-WebSocket-Protocol"
      },
      "tls": { $vtls_tls }
    }
  ],
${_acme_json}  "outbounds": [{"type": "direct", "tag": "direct"}]${_warp_tail}
}
EOF
  chmod 600 "$SB_DIR/sb.json"   # 内含 Reality 私钥等凭据，按密钥文件对待
  "$SB_DIR/sing-box" check -c "$SB_DIR/sb.json" >/dev/null 2>&1 \
    || { echo "[错误] 配置校验失败"; exit 1; }
  echo "[信息] 配置校验通过"
}

#----------------------------- 7.5 cron 守护 ----------------------------------
# Argo 隧道与无 systemd 时的 sing-box 自启都依赖 crontab 的 @reboot 条目，
# 但装好 crontab 命令不等于 cron 守护在运行（RHEL 系装完 cronie 默认不
# 启用），这里统一保证
ensure_cron_running() {
  if [[ -d /run/systemd/system ]] || pidof systemd >/dev/null 2>&1; then
    local unit=""
    if systemctl cat cron >/dev/null 2>&1; then unit="cron";
    elif systemctl cat crond >/dev/null 2>&1; then unit="crond"; fi
    if [[ -n "$unit" ]]; then
      systemctl enable --now "$unit" >/dev/null 2>&1 || true
      if systemctl is-active --quiet "$unit"; then
        echo "[信息] cron 服务运行中（$unit），@reboot 自启可用"
        return 0
      fi
    fi
    echo "[警告] 未能启用 cron 服务：重启后 Argo 隧道（及无 systemd 时的 sing-box）无法自动拉起，请手动启用 cron/crond 服务"
  fi
}

#----------------------------- 8. 防火墙 --------------------------------------
open_firewall() {
  local ports="$PORT_REALITY $PORT_VMESS $PORT_HY2 $PORT_TUIC $PORT_ANYTLS $PORT_SS $PORT_TROJAN $PORT_NAIVE $PORT_VTLS"
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
    # 服务名处理（沿用旧版七合一）：旧版用通名 sing-box.service，若是本
    # 脚本家族装的（ExecStart 指向 $SB_DIR）则迁移到专属名 $UNIT；若是
    # 别人装的 sing-box 则不碰它，只警告，本脚本用专属名与其共存
    local legacy_unit="/etc/systemd/system/sing-box.service"
    if [[ -f "$legacy_unit" ]]; then
      if grep -q "$SB_DIR/sing-box" "$legacy_unit"; then
        systemctl disable --now sing-box >/dev/null 2>&1 || true
        rm -f "$legacy_unit"
        echo "[信息] 已把服务名从 sing-box 迁移为 $UNIT"
      else
        echo "[警告] 检测到已存在的 sing-box 服务（非本脚本安装）：本脚本改用 $UNIT 与其共存，请注意端口不要冲突"
      fi
    fi
    cat > "/etc/systemd/system/${UNIT}.service" <<EOF
[Unit]
Description=sing-box-coexist service
After=network.target nss-lookup.target

[Service]
User=root
WorkingDirectory=$SB_DIR
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
Environment=GOMEMLIMIT=128MiB
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
      echo "[信息] sing-box-coexist 运行中"
    else
      echo "[错误] 服务启动失败，日志如下："
      journalctl -u "$UNIT" --no-pager -n 20 2>/dev/null || true
      exit 1
    fi
  else
    echo "[警告] 未检测到 systemd，改用后台方式启动（带同样的内存刹车参数）"
    pkill -f "$SB_DIR/sing-box run" >/dev/null 2>&1 || true
    GOMEMLIMIT=128MiB GOGC=50 nohup "$SB_DIR/sing-box" run -c "$SB_DIR/sb.json" \
      >/var/log/sing-box-coexist.log 2>&1 &
    sleep 2
    pgrep -f "$SB_DIR/sing-box run" >/dev/null || { echo "[错误] 后台启动失败"; exit 1; }
    if command -v crontab >/dev/null 2>&1; then
      (crontab -l 2>/dev/null | grep -v "sing-box-coexist" ; echo "@reboot sleep 10 && GOMEMLIMIT=128MiB GOGC=50 $SB_DIR/sing-box run -c $SB_DIR/sb.json >/var/log/sing-box-coexist.log 2>&1") | crontab - >/dev/null 2>&1 || true
    fi
    echo "[信息] sing-box-coexist 已在后台启动"
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
    GOMEMLIMIT=128MiB GOGC=50 nohup "$SB_DIR/sing-box" run -c "$SB_DIR/sb.json" \
      >/var/log/sing-box-coexist.log 2>&1 &
    echo "[信息] 已重启（后台模式）"
  fi
}

setup_shortcut() {
  # 主脚本副本留在 SB_DIR（离线管理、sbc 快捷方式、更新脚本都指它）：
  # 本地文件运行时直接拷；管道运行时本地没有文件，从 GitHub 拉一份
  # 校验后存。副本存不下来 sbc 就装不上，只警告不中断安装
  if [[ -f "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "$SB_DIR/sing-box-coexist.sh" ]]; then
    cp -f "${BASH_SOURCE[0]}" "$SB_DIR/sing-box-coexist.sh" 2>/dev/null || true
    chmod 755 "$SB_DIR/sing-box-coexist.sh" 2>/dev/null || true
  fi
  if [[ ! -f "$SB_DIR/sing-box-coexist.sh" ]]; then
    local tmp
    tmp=$(mktemp)
    if curl -fsSL --max-time 30 -o "$tmp" \
        "https://raw.githubusercontent.com/${REPO}/main/sing-box-coexist.sh" 2>/dev/null \
       && head -n 1 "$tmp" | grep -q '^#!/bin/bash' && grep -q 'sing-box-coexist' "$tmp"; then
      install -m 755 "$tmp" "$SB_DIR/sing-box-coexist.sh"
    fi
    rm -f "$tmp"
  fi
  if [[ ! -f "$SB_DIR/sing-box-coexist.sh" ]]; then
    echo "[警告] 主脚本副本没存下来，sbc 快捷命令这次装不上（可稍后重跑安装）"
    return 0
  fi
  write_sbc_wrapper
  echo "[信息] 快捷命令已安装：sbc（直接敲 sbc 打开管理菜单，自动提权）"
}

# sbc 快捷方式只是一个小包装：本体在 SB_DIR，非 root 运行时它自己
# sudo 提权，用户只敲 sbc 就行，不用敲 sudo
write_sbc_wrapper() {
  cat > /usr/local/bin/sbc <<EOF
#!/bin/bash
# sing-box-coexist 管理快捷方式（本体：$SB_DIR/sing-box-coexist.sh；非 root 自动 sudo 提权）
TARGET="$SB_DIR/sing-box-coexist.sh"
[[ -f "\$TARGET" ]] || { echo "[错误] 找不到 \$TARGET（可能已被卸载）"; exit 1; }
SUDO=""
if [[ \$EUID -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 || { echo "[错误] 需要 root：请先装 sudo 或改用 root 运行"; exit 1; }
  SUDO="sudo"
fi
if [[ \$# -eq 0 ]]; then
  exec \$SUDO "\$TARGET" menu
fi
exec \$SUDO "\$TARGET" "\$@"
EOF
  chmod 755 /usr/local/bin/sbc
  # 旧版七合一的快捷命令是 sbox（本体脚本的副本）：它还是本家族的文件
  # （旧脚本本体或本包装）时，一并换成指向同一本体的包装，老习惯可用；
  # 来历不明的同名文件不碰。首次安装没有 sbox 时也顺手装一份
  if [[ ! -e /usr/local/bin/sbox ]] \
     || grep -qE "sing-box 全自动一键安装脚本|sing-box-coexist" /usr/local/bin/sbox 2>/dev/null; then
    cp -f /usr/local/bin/sbc /usr/local/bin/sbox 2>/dev/null || true
  fi
}

# 拉最新版脚本到 $1：优先跟随最新 Release（按 coexist-v 前缀取版，不串
# 到别的版本），取不到 tag 再回退 main；每个源都校验内容 + bash -n
# 通过才算数（与七合一 fetch_latest_script 同一模式）
fetch_latest_script() {
  local dest="$1"
  local ts url tag=""
  ts=$(date +%s)
  tag=$(curl -fsSL --max-time 15 "https://api.github.com/repos/${REPO}/releases?per_page=30" 2>/dev/null \
    | jq -r '.[].tag_name' 2>/dev/null | grep -m1 '^coexist-v' || true)
  local urls=()
  if [[ -n "$tag" ]]; then
    urls+=(
      "https://raw.githubusercontent.com/${REPO}/${tag}/sing-box-coexist.sh?t=${ts}"
      "https://cdn.jsdelivr.net/gh/${REPO}@${tag}/sing-box-coexist.sh"
    )
  fi
  urls+=(
    "https://raw.githubusercontent.com/${REPO}/main/sing-box-coexist.sh?t=${ts}"
    "https://cdn.jsdelivr.net/gh/${REPO}@main/sing-box-coexist.sh"
  )
  for url in "${urls[@]}"; do
    if curl -fsSL --max-time 60 --retry 2 "$url" -o "$dest" \
       && grep -q "sing-box-coexist 一键安装脚本" "$dest" \
       && bash -n "$dest" 2>/dev/null; then
      return 0
    fi
    echo "[警告] 从 ${url%%\?*} 获取失败，尝试备用源…"
  done
  return 1
}

# 更新脚本到最新版：替换 SB_DIR 里的主脚本副本并刷新 sbc 包装；
# 成功返回 0，菜单里接着 exec 新版进菜单
do_update_script() {
  echo "[信息] 正在从 GitHub 拉取最新脚本…"
  local tmpfile
  tmpfile=$(mktemp)
  if fetch_latest_script "$tmpfile"; then
    local newver=""
    newver=$(grep -m1 '^SCRIPT_VERSION=' "$tmpfile" | cut -d'"' -f2 || true)
    install -m 755 "$tmpfile" "$SB_DIR/sing-box-coexist.sh"
    rm -f "$tmpfile"
    write_sbc_wrapper
    if [[ -n "$newver" ]]; then
      echo "[完成] 脚本已更新到 v$newver"
    else
      echo "[完成] 脚本已更新到最新版"
    fi
    return 0
  fi
  rm -f "$tmpfile"
  echo "[错误] 下载失败，请检查网络后重试"
  return 1
}

#----------------------------- 9.5 域名链本地握手自检 ------------------------------
# 装完在本机经 127.0.0.1 对域名链做一次 WS 握手（-k 不验链，自签与
# ACME 真证书都适用；真证书的信任校验在 acme_verify_or_fallback 里
# 单独做），确认服务真的在目标端口按预期应答。过不了只警告、不回
# 滚——配置和链接照常落地，修好后 sbc 里重看链接即可。
vtls_local_check() {
  [[ -n "${TLS_DOMAIN:-}" && -n "${PORT_VTLS:-}" && -n "${UUID:-}" ]] || return 0
  local _i _code
  for _i in $(seq 1 10); do
    # WS 握手成功（101）后连接保持开启，curl 会以超时退出（28）——先捕获状态码再比较
    _code=$(curl -sk --max-time 5 --resolve "${TLS_DOMAIN}:${PORT_VTLS}:127.0.0.1" \
      "https://${TLS_DOMAIN}:${PORT_VTLS}/${UUID}-vt" \
      -H "Connection: Upgrade" -H "Upgrade: websocket" \
      -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: x3JJHMbDL1EzLkh9GBhXDw==" \
      -o /dev/null -w '%{http_code}' 2>/dev/null || true)
    if [[ "$_code" == "101" ]]; then
      echo "[信息] 域名链本地握手自检通过（${TLS_DOMAIN}:${PORT_VTLS}）"
      return 0
    fi
    sleep 2
  done
  echo "[警告] 域名链本地握手自检未通过（服务日志：journalctl -u $UNIT），链接先照常保存，修好后运行 sbc 看链接"
}

#----------------------------- 9.6 WARP 出站 ----------------------------------
# sing-box 内置 WireGuard 出口：不开 TUN、不加常驻进程，关闭时配置里不生成
# 任何 WARP 内容（零成本）。注册参数由 wgcf 一次性生成（下载→注册→删除，
# 绝不常驻），全部落在 warp.env（600 权限，只用 grep 解析、从不 source），
# 之后可经菜单「WARP 出站」开关、切换模式。
# 模式：off=关闭；ipv4=IPv4 目的地经 WARP（给纯 IPv6 机器补 IPv4 出口：
# route 为 final: warp，无 v6 出口时域名先按 ipv4_only 只解析出 v4 再经
# WARP 出去）；all=全部流量经 WARP。

# 读取 warp.env 到全局变量；文件不存在或字段被污染时按关闭处理
load_warp_env() {
WARP_MODE="off"; WARP_PRIVATE_KEY=""; WARP_V4=""; WARP_V6=""
WARP_RESERVED=""; WARP_PEER_KEY=""; WARP_ENDPOINT_HOST=""; WARP_ENDPOINT_PORT=""
WARP_MTU=""; WARP_ACCOUNT="free"; WARP_LICENSE=""
[[ -f "$WARP_ENV_FILE" ]] || return 0
local _v
_v=$(grep '^WARP_MODE=' "$WARP_ENV_FILE" 2>/dev/null | cut -d'"' -f2 || true)
case "$_v" in off|ipv4|all) WARP_MODE="$_v";; esac
WARP_PRIVATE_KEY=$(grep '^WARP_PRIVATE_KEY=' "$WARP_ENV_FILE" 2>/dev/null | cut -d'"' -f2 || true)
WARP_V4=$(grep '^WARP_V4=' "$WARP_ENV_FILE" 2>/dev/null | cut -d'"' -f2 || true)
WARP_V6=$(grep '^WARP_V6=' "$WARP_ENV_FILE" 2>/dev/null | cut -d'"' -f2 || true)
WARP_RESERVED=$(grep '^WARP_RESERVED=' "$WARP_ENV_FILE" 2>/dev/null | cut -d'"' -f2 || true)
WARP_PEER_KEY=$(grep '^WARP_PEER_KEY=' "$WARP_ENV_FILE" 2>/dev/null | cut -d'"' -f2 || true)
WARP_ENDPOINT_HOST=$(grep '^WARP_ENDPOINT_HOST=' "$WARP_ENV_FILE" 2>/dev/null | cut -d'"' -f2 || true)
WARP_ENDPOINT_PORT=$(grep '^WARP_ENDPOINT_PORT=' "$WARP_ENV_FILE" 2>/dev/null | cut -d'"' -f2 || true)
WARP_MTU=$(grep '^WARP_MTU=' "$WARP_ENV_FILE" 2>/dev/null | cut -d'"' -f2 || true)
_v=$(grep '^WARP_ACCOUNT=' "$WARP_ENV_FILE" 2>/dev/null | cut -d'"' -f2 || true)
case "$_v" in free|plus|custom) WARP_ACCOUNT="$_v";; esac
WARP_LICENSE=$(grep '^WARP_LICENSE=' "$WARP_ENV_FILE" 2>/dev/null | cut -d'"' -f2 || true)
# 字符集校验：私钥字段异常说明状态文件被污染，整份状态视为不可用，
# 宁可日后重新注册，也不拿坏参数生成配置
if [[ -n "$WARP_PRIVATE_KEY" && ! "$WARP_PRIVATE_KEY" =~ ^[A-Za-z0-9+/]{42,44}={0,2}$ ]]; then
echo "[警告] warp.env 中的 WARP 私钥格式异常，已忽略现有 WARP 状态" >&2
WARP_MODE="off"; WARP_PRIVATE_KEY=""; WARP_V4=""; WARP_V6=""; WARP_RESERVED=""
WARP_PEER_KEY=""; WARP_ENDPOINT_HOST=""; WARP_ENDPOINT_PORT=""; WARP_MTU=""
WARP_ACCOUNT="free"; WARP_LICENSE=""
fi
return 0
}

# 注册参数是否齐全（生成 endpoint 配置的最低要求）
warp_profile_complete() {
[[ -n "$WARP_PRIVATE_KEY" && -n "$WARP_V4" && -n "$WARP_PEER_KEY" \
&& -n "$WARP_ENDPOINT_HOST" && -n "$WARP_ENDPOINT_PORT" ]]
}

# 原子落盘：先写临时文件再改名，避免中途断电/中断留下半份 warp.env
save_warp_env() {
local _tmp="$WARP_ENV_FILE.tmp"
{
printf 'WARP_MODE="%s"\n' "${WARP_MODE:-off}"
printf 'WARP_PRIVATE_KEY="%s"\n' "$WARP_PRIVATE_KEY"
printf 'WARP_V4="%s"\n' "$WARP_V4"
printf 'WARP_V6="%s"\n' "$WARP_V6"
printf 'WARP_RESERVED="%s"\n' "$WARP_RESERVED"
printf 'WARP_PEER_KEY="%s"\n' "$WARP_PEER_KEY"
printf 'WARP_ENDPOINT_HOST="%s"\n' "$WARP_ENDPOINT_HOST"
printf 'WARP_ENDPOINT_PORT="%s"\n' "$WARP_ENDPOINT_PORT"
printf 'WARP_MTU="%s"\n' "$WARP_MTU"
printf 'WARP_ACCOUNT="%s"\n' "${WARP_ACCOUNT:-free}"
printf 'WARP_LICENSE="%s"\n' "$WARP_LICENSE"
} > "$_tmp" && mv -f "$_tmp" "$WARP_ENV_FILE"
chmod 600 "$WARP_ENV_FILE"
}

warp_mode_desc() {
case "${WARP_MODE:-off}" in
ipv4) echo "IPv4 经 WARP（域名按 IPv4 解析后经 WARP）";;
all) echo "全部流量经 WARP";;
*) echo "关闭";;
esac
}

# 生成 sing-box 的 WireGuard endpoint JSON（调用前须 load_warp_env 且参数齐全）
warp_endpoint_json() {
local _addr="\"$WARP_V4/32\""
[[ -n "$WARP_V6" ]] && _addr="$_addr, \"$WARP_V6/128\""
local _res=""
[[ -n "$WARP_RESERVED" ]] && _res=", \"reserved\": [${WARP_RESERVED//,/,}]"
printf '%s' "{\"type\": \"wireguard\", \"tag\": \"warp\", \"address\": [$_addr], \"private_key\": \"$WARP_PRIVATE_KEY\", \"mtu\": ${WARP_MTU:-1280}, \"peers\": [{\"address\": \"$WARP_ENDPOINT_HOST\", \"port\": $WARP_ENDPOINT_PORT, \"public_key\": \"$WARP_PEER_KEY\", \"allowed_ips\": [\"0.0.0.0/0\", \"::/0\"]$_res}]}"
}

# 下载 wgcf 到 $1：先走 ensure_github 的可达性引导（纯 IPv6 机经 DNS64/NAT64
# 绕行 GitHub），再按 GitHub API 找最新版的本架构资产
warp_fetch_wgcf() {
local _dst="$1" _arch _resp _url
case "$(uname -m)" in
x86_64) _arch="amd64";;
aarch64) _arch="arm64";;
armv7l) _arch="armv7";;
armv6l) _arch="armv6";;
i386|i686) _arch="386";;
*) echo "[错误] 当前架构 $(uname -m) 没有 wgcf 官方构建" >&2; return 1;;
esac
ensure_github || true
_resp=$(curl -fsSL --max-time 20 --retry 2 "https://api.github.com/repos/ViRb3/wgcf/releases/latest" 2>/dev/null || true)
_url=$(printf '%s' "$_resp" | grep -o "\"browser_download_url\": *\"[^\"]*_linux_${_arch}\"" | head -n 1 | cut -d'"' -f4 || true)
[[ -n "$_url" ]] || { echo "[错误] 未能获取 wgcf 下载地址（GitHub 不可达或无此架构资产）" >&2; return 1;}
curl -fSL --retry 2 --max-time 120 -o "$_dst" "$_url" 2>/dev/null || { echo "[错误] wgcf 下载失败" >&2; return 1;}
chmod +x "$_dst"
}

# 用 wgcf 一次性注册并把参数解析进全局变量（不落盘，由调用方决定何时保存）。
# wgcf 只在临时目录里存在，结束即删；注册有界重试 3 次、单次 60 秒超时。
warp_register() {
echo "[信息] 正在用 wgcf 一次性注册 WARP 设备（用完即删，不常驻；下载加注册约 1 分钟，期间没有输出是正常的，请别关终端）…"
local _dir _try _ok=0
_dir=$(mktemp -d)
if ! warp_fetch_wgcf "$_dir/wgcf"; then
rm -rf "$_dir"
return 1
fi
for _try in 1 2 3; do
if ( cd "$_dir" && timeout 60 ./wgcf register --accept-tos >/dev/null 2>&1 \
&& timeout 60 ./wgcf generate >/dev/null 2>&1) \
&& [[ -f "$_dir/wgcf-profile.conf" ]]; then
_ok=1; break
fi
echo "[警告] WARP 注册第 ${_try} 次尝试失败（共 3 次）"
[[ "$_try" -lt 3 ]] && sleep $((_try * 3))
done
if [[ "$_ok" != "1" ]]; then
echo "[错误] WARP 注册失败：wgcf 三次尝试均未完成（多为 Cloudflare 注册接口不可达）"
rm -rf "$_dir"
return 1
fi
# 解析 wgcf-profile.conf：[Interface] PrivateKey/Address/MTU、[Peer] PublicKey/Endpoint
local _conf="$_dir/wgcf-profile.conf" _addr _ep
WARP_PRIVATE_KEY=$(grep -E '^PrivateKey[[:space:]]*=' "$_conf" | head -n 1 | cut -d= -f2- | tr -d ' \r' || true)
_addr=$(grep -E '^Address[[:space:]]*=' "$_conf" | head -n 1 | cut -d= -f2- | tr -d ' \r' || true)
WARP_V4=$(printf '%s' "$_addr" | tr ',' '\n' | grep -E '^[0-9.]+/' | head -n 1 | cut -d/ -f1 || true)
WARP_V6=$(printf '%s' "$_addr" | tr ',' '\n' | grep ':' | head -n 1 | cut -d/ -f1 || true)
WARP_PEER_KEY=$(grep -E '^PublicKey[[:space:]]*=' "$_conf" | head -n 1 | cut -d= -f2- | tr -d ' \r' || true)
WARP_MTU=$(grep -E '^MTU[[:space:]]*=' "$_conf" | head -n 1 | cut -d= -f2- | tr -d ' \r' || true)
_ep=$(grep -E '^Endpoint[[:space:]]*=' "$_conf" | head -n 1 | cut -d= -f2- | tr -d ' \r' || true)
WARP_ENDPOINT_HOST="${_ep%:*}"
WARP_ENDPOINT_PORT="${_ep##*:}"
# reserved：永远留空、endpoint 不写 reserved 字段。曾按 wgcf 的 client_id
# 推导三字节写入，2026-11-27 在纯 IPv6 机（HE 地址段）上 A/B 实证：带推导
# reserved 时 Cloudflare 不回握手，去掉后同账号同端点、内核 wg 与 sing-box
# 两种实现都一次握手成功，故不再推导。
WARP_RESERVED=""
rm -rf "$_dir"
WARP_ACCOUNT="free"; WARP_LICENSE=""
[[ -n "$WARP_MTU" ]] || WARP_MTU="1280"
if ! warp_profile_complete; then
echo "[错误] WARP 注册结果不完整（wgcf 输出缺少必要参数）"
return 1
fi
echo "[信息] WARP 注册完成"
return 0
}

# 生成探针配置到 $1/probe.json（本地入口端口 $2）：仅本地 mixed 入口 + WARP
# 出口、route final=warp。探针必须验「服务真正跑的那份」route/dns 形状，
# 不许用极简配置自欺：无条件走与 write_config 相同的 restricted_net_tail
# 合并（extra 同为 final: warp，随当前 WARP_MODE 区分 ipv4/all 的尾段），
# 尾段为空（普通机器 + WARP all，服务配置也只有 final: warp）时才回落
# 简单字面量——两种情形下形状都与服务配置一致。
warp_write_probe_config() {
local _dir="$1" _port="$2" _probe_tail
_probe_tail=$(restricted_net_tail '"final": "warp"')
if [[ -z "$_probe_tail" ]]; then
_probe_tail=',
"route": {"final": "warp"}'
fi
cat > "$_dir/probe.json" <<EOF
{
"log": {"level": "warn"},
"inbounds": [{"type": "mixed", "tag": "probe-in", "listen": "127.0.0.1", "listen_port": $_port}],
"endpoints": [$(warp_endpoint_json)],
"outbounds": [{"type": "direct", "tag": "direct"}]${_probe_tail}
}
EOF
}

# 出口自检：用与正式配置相同的 WARP 参数起一个临时 sing-box（仅本地 mixed
# 入口 + WARP 出口），经它取 Cloudflare trace，确认 warp=on/plus 才算通。
# 临时进程与文件用完即删，不碰正在运行的服务。成功返回 0
warp_probe() {
local _dir _port _pid _out _try
_dir=$(mktemp -d)
_port=$(rand_port)
warp_write_probe_config "$_dir" "$_port"
if ! "$SB_DIR/sing-box" check -c "$_dir/probe.json" >/dev/null 2>&1; then
echo "[错误] WARP 自检配置未通过 sing-box 校验"
rm -rf "$_dir"
return 1
fi
"$SB_DIR/sing-box" run -c "$_dir/probe.json" > "$_dir/probe.log" 2>&1 &
_pid=$!
_out=""
for _try in 1 2 3 4 5; do
sleep 3
_out=$(curl -s --max-time 10 -x "socks5h://127.0.0.1:$_port" \
"https://www.cloudflare.com/cdn-cgi/trace" 2>/dev/null \
| grep -E '^warp=' | cut -d= -f2 || true)
[[ "$_out" == "on" || "$_out" == "plus" ]] && break
_out=""
done
kill "$_pid" >/dev/null 2>&1 || true
wait "$_pid" 2>/dev/null || true
if [[ -n "$_out" ]]; then
echo "[信息] WARP 出口自检通过（Cloudflare trace 显示 warp=$_out）"
rm -rf "$_dir"
return 0
fi
echo "[错误] WARP 出口自检未通过：经 WARP 访问 Cloudflare trace 未得到 warp=on，自检日志最后几行："
tail -n 5 "$_dir/probe.log" 2>/dev/null || true
rm -rf "$_dir"
return 1
}

# 经真实服务验证 WARP 出口：临时起一个客户端 sing-box，出站指向正在运行
# 的服务本机的 VMess 入站（回环），经它取 Cloudflare trace，确认 warp=on/
# plus 且数据真能流动。为什么不能只信 warp_probe：探针是独立进程、用自己
# 的端点，服务进程的端点在模式切换后可能楔住（握手成、无数据）——
# 2026-11-24 USARM 实测切「全走」后服务黑洞 30+ 分钟、探针却报正常，手动
# 重启服务才恢复；只有经服务本体的流量验得出来。两种取 trace 的方式任一
# 成功即算过：①域名经 socks5h（远端解析）；②IPv4 字面地址（运行时经 DoH
# 查 www.cloudflare.com 的 A 记录再直连取 trace）——ipv4 模式下域名可能
# 被服务解析成 v6 走直连，必须有一条钉死走 IPv4 的路径才验得到 WARP。
# 返回 0=通过；1=不通过；2=无法验（VMess 参数缺失等），调用方按跳过处理
warp_service_check() {
[[ -n "${PORT_VMESS:-}" && -n "${UUID:-}" ]] || return 2
local _dir _port _pid _out _try _v4
_dir=$(mktemp -d)
_port=$(rand_port)
cat > "$_dir/client.json" <<EOF
{
  "log": {"level": "warn"},
  "inbounds": [{"type": "mixed", "tag": "in", "listen": "127.0.0.1", "listen_port": $_port}],
  "outbounds": [{"type": "vmess", "tag": "via-service", "server": "127.0.0.1", "server_port": $PORT_VMESS, "uuid": "$UUID", "security": "auto", "alter_id": 0, "transport": {"type": "ws", "path": "${UUID}-vm"}}]
}
EOF
if ! "$SB_DIR/sing-box" check -c "$_dir/client.json" >/dev/null 2>&1; then
rm -rf "$_dir"
return 2
fi
"$SB_DIR/sing-box" run -c "$_dir/client.json" > "$_dir/client.log" 2>&1 &
_pid=$!
_out=""
for _try in 1 2 3; do
sleep 3
_out=$(curl -s --max-time 10 -x "socks5h://127.0.0.1:$_port" \
"https://www.cloudflare.com/cdn-cgi/trace" 2>/dev/null \
| grep -E '^warp=' | cut -d= -f2 || true)
[[ "$_out" == "on" || "$_out" == "plus" ]] && break
_out=""
# 方式②：IPv4 字面地址钉死走 v4 路径（ipv4 模式下 WARP 就管这一段）
_v4=$(curl -fsSL --max-time 8 "https://cloudflare-dns.com/dns-query?name=www.cloudflare.com&type=A" \
-H 'accept: application/dns-json' 2>/dev/null \
| jq -r '.Answer[]? | select(.type==1) | .data' 2>/dev/null | head -n 1 || true)
if [[ -n "$_v4" ]]; then
_out=$(curl -s --max-time 10 -x "socks5://127.0.0.1:$_port" \
-H "Host: www.cloudflare.com" "http://$_v4/cdn-cgi/trace" 2>/dev/null \
| grep -E '^warp=' | cut -d= -f2 || true)
[[ "$_out" == "on" || "$_out" == "plus" ]] && break
_out=""
fi
done
kill "$_pid" >/dev/null 2>&1 || true
wait "$_pid" 2>/dev/null || true
if [[ -n "$_out" ]]; then
echo "[信息] 经真实服务验证通过：流量经服务入站走 WARP 出口（warp=$_out）"
rm -rf "$_dir"
return 0
fi
echo "[错误] 经真实服务验证未通过：经服务入站的流量没能走通 WARP 出口（探针进程正常不算数）"
rm -rf "$_dir"
return 1
}

# 解析 Cloudflare trace 全文（$1）：仅 warp=on/plus 时提取 ip= 与 loc=，
# 成功输出一行「WARP 出口：<ip>（<loc>）」（缺 loc 时只输出 IP），否则返回 1。
# trace 里的出口 IP 是 Cloudflare 的共享出口地址，只许展示给人看，
# 绝不写入任何节点链接、env 或配置当服务器地址用——链接与地址校验只认
# 机器真实地址（get_ip / local_ip_set），与经 WARP 探测到的一切地址无关。
warp_trace_parse() {
local _txt="$1" _w _ip _loc
_w=$(printf '%s\n' "$_txt" | grep -E '^warp=' | head -n 1 | cut -d= -f2 || true)
[[ "$_w" == "on" || "$_w" == "plus" ]] || return 1
_ip=$(printf '%s\n' "$_txt" | grep -E '^ip=' | head -n 1 | cut -d= -f2 || true)
[[ -n "$_ip" ]] || return 1
_loc=$(printf '%s\n' "$_txt" | grep -E '^loc=' | head -n 1 | cut -d= -f2 || true)
if [[ -n "$_loc" ]]; then
printf 'WARP 出口：%s（%s）\n' "$_ip" "$_loc"
else
printf 'WARP 出口：%s\n' "$_ip"
fi
}

# 展示当前 WARP 出口 IP 与落地国家，并顺带一行流媒体/AI 解锁参考：未启用
# 时直接返回 1、不输出、也不起探针；启用时起临时 sing-box 经 WARP 拉
# trace 再解析（探针配置与 warp_probe 共用，临时进程与目录用完即清理）。
# 取不到返回 1 不输出，调用方一律以 || true 承接，绝不阻塞菜单与安装流程
warp_trace_info() {
load_warp_env
[[ "$WARP_MODE" != "off" ]] || return 1
warp_profile_complete || return 1
local _dir _port _pid _txt="" _try
_dir=$(mktemp -d)
_port=$(rand_port)
warp_write_probe_config "$_dir" "$_port"
if ! "$SB_DIR/sing-box" check -c "$_dir/probe.json" >/dev/null 2>&1; then
rm -rf "$_dir"
return 1
fi
"$SB_DIR/sing-box" run -c "$_dir/probe.json" > "$_dir/probe.log" 2>&1 &
_pid=$!
for _try in 1 2 3 4 5; do
sleep 3
_txt=$(curl -s --max-time 10 -x "socks5h://127.0.0.1:$_port" \
"https://www.cloudflare.com/cdn-cgi/trace" 2>/dev/null || true)
if printf '%s' "$_txt" | grep -qE '^warp='; then break; fi
_txt=""
done
local _line=""
[[ -n "$_txt" ]] && _line=$(warp_trace_parse "$_txt" || true)
if [[ -n "$_line" ]]; then
# 同一探针会话内顺带做流媒体/AI 解锁判断（各一次短超时请求；仅展示用，
# 判断结果只依赖状态码，与出口 IP 一样绝不落盘、不写任何 env/配置/链接）
local _nf _dp _cg _nf_t _dp_t _cg_t
_nf=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -x "socks5h://127.0.0.1:$_port" "https://www.netflix.com/title/81280792" 2>/dev/null || true)
_dp=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -x "socks5h://127.0.0.1:$_port" "https://www.disneyplus.com/" 2>/dev/null || true)
_cg=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -x "socks5h://127.0.0.1:$_port" "https://api.openai.com/v1/models" 2>/dev/null || true)
case "$_nf" in 200) _nf_t="Netflix 可看" ;; 301|302|404) _nf_t="Netflix 仅自制剧" ;; 403) _nf_t="Netflix 未解锁" ;; *) _nf_t="Netflix 不通" ;; esac
case "$_dp" in 200|301|302) _dp_t="Disney+ 可达" ;; 403) _dp_t="Disney+ 未解锁" ;; *) _dp_t="Disney+ 不通" ;; esac
case "$_cg" in 401) _cg_t="ChatGPT 可达" ;; 403) _cg_t="ChatGPT 未解锁" ;; *) _cg_t="ChatGPT 不通" ;; esac
kill "$_pid" >/dev/null 2>&1 || true
wait "$_pid" 2>/dev/null || true
rm -rf "$_dir"
printf '%s\n' "$_line"
printf '解锁参考：%s · %s · %s（经 WARP 出口实测）\n' "$_nf_t" "$_dp_t" "$_cg_t"
return 0
fi
kill "$_pid" >/dev/null 2>&1 || true
wait "$_pid" 2>/dev/null || true
rm -rf "$_dir"
return 1
}

# 回滚 WARP 变更：恢复 auto.env / sb.json / warp.env 三件套备份并重启服务
# （备份不存在的 warp.env 按「原本没有」处理：回滚时删除）
warp_rollback() {
[[ -f "$ENV_FILE.bak" ]] && cp -f "$ENV_FILE.bak" "$ENV_FILE" || true
[[ -f "$SB_DIR/sb.json.bak" ]] && cp -f "$SB_DIR/sb.json.bak" "$SB_DIR/sb.json" || true
if [[ -f "$WARP_ENV_FILE.bak" ]]; then
cp -f "$WARP_ENV_FILE.bak" "$WARP_ENV_FILE"
else
rm -f "$WARP_ENV_FILE"
fi
rm -f "$ENV_FILE.bak" "$SB_DIR/sb.json.bak" "$WARP_ENV_FILE.bak"
. "$ENV_FILE" 2>/dev/null || true
setup_service
}

# 把当前全局变量里的 WARP 参数原子生效：先备份三件套、落盘新状态、生成
# 配置（子进程跑 write_config，挡住它校验失败时的 exit）、重启、出口自检；
# 任一步失败自动回滚。菜单切换走这一处，不留半成品
_warp_commit() {
local _mode="$1"
cp -f "$ENV_FILE" "$ENV_FILE.bak" 2>/dev/null || true
[[ -f "$SB_DIR/sb.json" ]] && cp -f "$SB_DIR/sb.json" "$SB_DIR/sb.json.bak" || true
[[ -f "$WARP_ENV_FILE" ]] && cp -f "$WARP_ENV_FILE" "$WARP_ENV_FILE.bak" || true
WARP_MODE="$_mode"
save_warp_env
if ! ( write_config ); then
echo "[错误] 新配置生成/校验失败，已自动回滚，WARP 模式未改变"
warp_rollback
return 1
fi
setup_service
if [[ "$_mode" != "off" ]] && ! warp_probe; then
# 新注册的 WARP 账号常有几分钟未激活期（实测最长约 10 分钟，静置后自愈）：
# 立刻判死会把能用的参数回滚掉。先静置 90 秒、用同一套参数复试一次探针，
# 复试仍不过才按原口径回滚（七合一的静置复试经验）
echo "[信息] 出口自检未通过：新注册的 WARP 账号可能还没激活，静置 90 秒后复试一次…"
sleep 90
if ! warp_probe; then
echo "[错误] WARP 已写入配置但出口自检未通过，已自动回滚到之前的状态"
warp_rollback
return 1
fi
echo "[信息] 复试通过（新账号激活较慢，属正常现象）"
fi
if [[ "$_mode" != "off" ]]; then
# 探针自检过的是独立进程，服务进程的 WARP 端点在切换后可能楔住（握手成、
# 无数据）：额外重启一次服务，再经真实服务入站验一次出口，两步都做完才
# 算生效；真实服务验不过同样回滚（口径与探针失败一致）
restart_service
local _sc=0
warp_service_check || _sc=$?
if [[ "$_sc" == "1" ]]; then
echo "[错误] WARP 探针自检通过，但经真实服务的出口验证未通过，已自动回滚到之前的状态"
warp_rollback
return 1
fi
[[ "$_sc" == "2" ]] && echo "[信息] 缺少 VMess 入站参数，跳过经真实服务的出口验证（探针自检与额外重启已完成）"
fi
rm -f "$ENV_FILE.bak" "$SB_DIR/sb.json.bak" "$WARP_ENV_FILE.bak"
echo "[完成] WARP 出站模式已更新：$(warp_mode_desc)"
# 启用成功顺手展示一次出口 IP 与落地国家（仅展示，取不到不算失败）
if [[ "$_mode" != "off" ]]; then
warp_trace_info || true
fi
return 0
}

# 切换 WARP 模式：需要时才注册（已有参数直接复用，幂等），参数就绪后交给
# _warp_commit 原子生效。调用前须已加载 auto.env（菜单分支负责）。
# $1=目标模式 off|ipv4|all  $2=1 时强制重新注册（先清参数再注册，供换 IP 用；
# 注册失败时只是内存里的参数被清，warp.env 原样未动，等于未做任何修改）
warp_apply() {
local _mode="$1" _force="${2:-0}"
load_warp_env
if [[ "$_mode" != "off" || "$_force" == "1" ]]; then
if [[ "$_force" == "1" ]]; then
WARP_PRIVATE_KEY=""; WARP_V4=""; WARP_V6=""; WARP_RESERVED=""
WARP_PEER_KEY=""; WARP_ENDPOINT_HOST=""; WARP_ENDPOINT_PORT=""; WARP_MTU=""
fi
if ! warp_profile_complete; then
if ! warp_register; then
echo "[错误] WARP 注册未完成，未做任何修改"
return 1
fi
fi
fi
_warp_commit "$_mode"
}

# 更换 WARP IP：强制重新注册一套设备参数（出口 IP 随新账号变更），保持当前
# 模式不变。一次调用只换一次——频繁注册会招 Cloudflare 注册限流（429），
# 想再换请隔段时间。底层走 warp_apply 的强制注册路径：先备份、生成新配置、
# 重启、出口自检，任一步失败自动回滚到旧参数与旧配置（原出口 IP 保住）；
# 普通模式切换的「参数齐全直接复用」幂等路径不经过这里、不受影响
warp_reroll() {
load_warp_env
if [[ "$WARP_MODE" == "off" ]]; then
echo "[提示] WARP 当前为关闭状态，没有可更换的出口 IP；请先在本菜单选 1 或 2 启用 WARP"
return 0
fi
echo "[信息] 正在更换 WARP IP（重新注册一套设备参数，模式保持：$(warp_mode_desc)）…"
if warp_apply "$WARP_MODE" 1; then
return 0
fi
echo "[提示] 更换 WARP IP 未成功，已恢复原有参数与配置（原出口 IP 保持不变）"
return 0
}

# 本机是否有可用的 IPv4 出口（与 ensure_github 的 IPv6 检测同一探法）
has_ipv4_egress() {
curl -4 -fsS --connect-timeout 5 --max-time 8 https://www.cloudflare.com/cdn-cgi/trace >/dev/null 2>&1
}

# 安装时的 WARP 决策（全程零交互，与七合一的差异点：不提问、不收许可证）：
# 已有状态直接保留、不重复决策；否则按环境定默认——无 IPv4 出口默认开启
# IPv4 经 WARP、有 IPv4 出口默认关闭。注册/自检失败一律降级为关闭并留一句
# 总结（WARP_NOTE），绝不中断安装、不留半成品（失败时不保存注册参数，
# 日后可从菜单重新开启）。
warp_install_setup() {
load_warp_env
if [[ "$WARP_MODE" != "off" ]] || warp_profile_complete; then
return 0
fi
if has_ipv4_egress; then
WARP_NOTE="WARP 出站：未开启（本机有 IPv4 出口；可在菜单「WARP 出站」里开启）"
echo "[信息] $WARP_NOTE"
return 0
fi
echo "[信息] 检测到本机无 IPv4 出口，默认开启 WARP 出站（IPv4 经 WARP）…"
if warp_register && warp_probe; then
WARP_MODE="ipv4"
save_warp_env
WARP_NOTE="WARP 出站：已开启（$(warp_mode_desc)）"
local _ti=""
_ti=$(warp_trace_info || true)
[[ -n "$_ti" ]] && WARP_NOTE="$WARP_NOTE；$_ti"
echo "[信息] $WARP_NOTE"
else
WARP_PRIVATE_KEY=""; WARP_V4=""; WARP_V6=""; WARP_RESERVED=""
WARP_PEER_KEY=""; WARP_ENDPOINT_HOST=""; WARP_ENDPOINT_PORT=""; WARP_MTU=""
WARP_MODE="off"
rm -f "$WARP_ENV_FILE"
WARP_NOTE="WARP 出站：未开启（注册或出口自检未通过，已自动跳过；可在菜单「WARP 出站」里重试）"
echo "[警告] $WARP_NOTE"
fi
return 0
}

# WARP 出站子菜单（主菜单进入，调用前已加载 auto.env）
do_warp_menu() {
while true; do
load_warp_env
echo
echo "---------- WARP 出站管理 ----------"
echo "当前模式：$(warp_mode_desc)"
if warp_profile_complete; then
echo "注册状态：已注册（参数在 $WARP_ENV_FILE，重复开启直接复用、不重新注册）"
else
echo "注册状态：未注册（首次开启时用 wgcf 一次性注册，用完即删）"
fi
if [[ "$WARP_MODE" != "off" ]] && warp_profile_complete; then
warp_trace_info || true
fi
echo " 1) IPv4 经 WARP（推荐：给纯 IPv6 机器补 IPv4 出口）"
echo " 2) 全部流量经 WARP"
echo " 3) 关闭 WARP 出站（配置里不留任何 WARP 内容，零成本）"
echo " 4) 更换 WARP IP（重新注册换一套参数，出口随之变更；频繁更换可能触发 Cloudflare 注册限流）"
echo " 0) 返回（回车/20 秒无输入默认返回）"
local c
c=$(read_choice "请选择 [0-4]：")
case "$c" in
1) warp_apply ipv4 || true;;
2) warp_apply all || true;;
3) warp_apply off || true;;
4) warp_reroll || true;;
0|"") return 0;;
*) echo "无效选择：$c";;
esac
done
}

#----------------------------- 9.7 Argo 隧道（可选，默认关） -------------------
# VMess 入站再经 Cloudflare 隧道出一条链：不暴露源站 IP、无需公网入站，
# 与 VTLS 域名链共存互备（域名链直连/套 CF、Argo 走隧道，互不影响）。
# 本节对 sb.json 零侵入：隧道是独立进程（cloudflared），转发目标是
# http://localhost:${PORT_VMESS}——开与关生成的 sing-box 配置逐字节相同，
# Argo 所需的入站就是常开的 VMess WS 入站本身。
#
# 状态文件 $ARGO_ENV_FILE（600 权限）：只用 grep 解析、从不 source——
# Token 来自用户输入，source 等于把输入当代码执行；解析后逐字段做
# 字符集校验，不合格整份状态按关闭处理。
#   文件不存在            → 关闭（合并版默认）。旧版七合一没有此文件时
#                           默认开临时隧道，合并版按新默认关；但读到旧
#                           版留下的 fixed 配置时尊重其选择、继续开
#   ARGO_ENABLED="0"      → 关闭（菜单/参数里明确关过，优先于一切）
#   ARGO_MODE="temp"      → 临时隧道（trycloudflare 域名，重启会变）
#   ARGO_MODE="fixed"     → 固定隧道（ARGO_TOKEN + ARGO_DOMAIN；转发目标
#                           在 Cloudflare 侧管理，ingress 须指向
#                           http://localhost:${PORT_VMESS}，不一致时
#                           Argo 链返回 502）
ARGO_ENABLED=0
ARGO_MODE="off"
ARGO_TOKEN=""
ARGO_DOMAIN=""

argo_load_state() {
  ARGO_ENABLED=0; ARGO_MODE="off"; ARGO_TOKEN=""; ARGO_DOMAIN=""
  [[ -f "$ARGO_ENV_FILE" ]] || return 0
  local _en _mode _tok _dom
  _en=$(grep '^ARGO_ENABLED=' "$ARGO_ENV_FILE" 2>/dev/null | cut -d'"' -f2 || true)
  _mode=$(grep '^ARGO_MODE=' "$ARGO_ENV_FILE" 2>/dev/null | cut -d'"' -f2 || true)
  _tok=$(grep '^ARGO_TOKEN=' "$ARGO_ENV_FILE" 2>/dev/null | cut -d'"' -f2 || true)
  _dom=$(grep '^ARGO_DOMAIN=' "$ARGO_ENV_FILE" 2>/dev/null | cut -d'"' -f2 || true)
  [[ "$_en" == "0" ]] && return 0   # 明确关过，优先于模式字段
  case "$_mode" in
    temp)
      ARGO_ENABLED=1; ARGO_MODE="temp" ;;
    fixed)
      if [[ "$_tok" =~ ^[A-Za-z0-9+/=_-]+$ && "$_dom" =~ ^[A-Za-z0-9.-]+$ \
         && "$_dom" == *.* && "$_dom" != .* && "$_dom" != *. ]]; then
        ARGO_ENABLED=1; ARGO_MODE="fixed"; ARGO_TOKEN="$_tok"; ARGO_DOMAIN="$_dom"
      else
        echo "[警告] argo.env 里的固定隧道 Token/域名不完整或格式不对，Argo 按关闭处理（可在菜单「Argo 隧道」里重设）" >&2
      fi ;;
  esac
  return 0
}

# 原子落盘：先写临时文件再改名，避免中途中断留下半份状态
argo_save_state() {
  local _tmp="$ARGO_ENV_FILE.tmp"
  {
    printf 'ARGO_ENABLED="%s"\n' "${ARGO_ENABLED:-0}"
    printf 'ARGO_MODE="%s"\n' "${ARGO_MODE:-off}"
    printf 'ARGO_TOKEN="%s"\n' "${ARGO_TOKEN:-}"
    printf 'ARGO_DOMAIN="%s"\n' "${ARGO_DOMAIN:-}"
  } > "$_tmp" && mv -f "$_tmp" "$ARGO_ENV_FILE"
  chmod 600 "$ARGO_ENV_FILE"
}

argo_mode_desc() {
  case "${ARGO_MODE:-off}" in
    temp)  echo "临时隧道${ARGO_DOMAIN:+（$ARGO_DOMAIN）}" ;;
    fixed) echo "固定隧道${ARGO_DOMAIN:+（$ARGO_DOMAIN）}" ;;
    *)     echo "关闭" ;;
  esac
}

# 从 cloudflared 日志里提取当前临时隧道域名。取第二个匹配：第一个是日志里
# api.trycloudflare.com 的提示链接，第二个才是本隧道的域名。解析逻辑集中
# 在一处，cloudflared 改日志版式时只修这里
current_argo_domain() {
  grep -a -o 'https://[^ "]*trycloudflare.com' "$SB_DIR/argo.log" 2>/dev/null | head -n 2 | tail -n 1 | sed 's|https://||' || true
}

# 有 systemd 时把 cloudflared 交给 systemd 托管（崩溃自动拉起 + 开机自启），
# 成功返回 0；无 systemd 时返回 1，调用方回退到 nohup + crontab 老路径
start_argo_systemd() {
  local exec_cmd="$1"
  if [[ -d /run/systemd/system ]] || pidof systemd >/dev/null 2>&1; then
    cat > "/etc/systemd/system/${ARGO_UNIT}.service" <<EOF
[Unit]
Description=cloudflared Argo tunnel (sing-box-coexist)
After=network.target

[Service]
ExecStart=$exec_cmd
Restart=always
RestartSec=10
StandardOutput=append:$SB_DIR/argo.log
StandardError=append:$SB_DIR/argo.log

[Install]
WantedBy=multi-user.target
EOF
    # 清掉老的 crontab @reboot 自启，避免与 systemd 托管双开
    if command -v crontab >/dev/null 2>&1; then
      (crontab -l 2>/dev/null | grep -v "$SB_DIR/cloudflared") | crontab - >/dev/null 2>&1 || true
    fi
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable "$ARGO_UNIT" >/dev/null 2>&1 || true
    systemctl restart "$ARGO_UNIT" >/dev/null 2>&1 || true
    return 0
  fi
  return 1
}

# 确保 cloudflared 已下载：缺失时按架构拉取官方版。成功输出路径，失败返回 1
ensure_cloudflared() {
  local cf="$SB_DIR/cloudflared"
  if [[ ! -x "$cf" ]]; then
    echo "[信息] 下载 cloudflared…" >&2
    # cloudflared 的资产命名与 sing-box 不同：官方没有 armv7 资产，arm 版即给 armv7 用；
    # 且菜单路径下 ARCH 可能未设置，这里按 uname 现算，不依赖 detect_arch
    local cf_arch
    case "$(uname -m)" in
      x86_64) cf_arch="amd64" ;;
      aarch64) cf_arch="arm64" ;;
      armv7l) cf_arch="arm" ;;
      *) cf_arch="${ARCH:-amd64}" ;;
    esac
    if ! curl -fSL --retry 2 --max-time 120 -o "$cf" \
      "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cf_arch}"; then
      echo "[警告] cloudflared 下载失败" >&2
      return 1
    fi
    chmod +x "$cf"
  fi
  printf '%s' "$cf"
}

# 启动 Argo 固定隧道（Token 方式；ingress 在 Cloudflare 侧管理）
start_argo_fixed() {
  local cf
  cf=$(ensure_cloudflared) || { echo "[警告] cloudflared 不可用，固定隧道未启动（不影响其他协议；网络恢复后运行 sbc restart 可重试）"; return 0; }
  if [[ -z "${ARGO_TOKEN:-}" ]]; then
    echo "[错误] 未配置 Argo Token"
    return 1
  fi
  systemctl stop "$ARGO_UNIT" >/dev/null 2>&1 || true   # 先停掉可能在跑的旧托管实例，避免双开
  pkill -f "$SB_DIR/cloudflared.*tunnel" >/dev/null 2>&1 || true
  sleep 1
  echo "[信息] 固定隧道启动中…"
  if start_argo_systemd "$cf tunnel --no-autoupdate run --token $ARGO_TOKEN"; then
    echo "[信息] 固定隧道已由 systemd 托管（崩溃自动拉起）"
  else
    nohup "$cf" tunnel --no-autoupdate run --token "$ARGO_TOKEN" > "$SB_DIR/argo.log" 2>&1 &
    if command -v crontab >/dev/null 2>&1; then
      (crontab -l 2>/dev/null | grep -v "$SB_DIR/cloudflared"
       echo "@reboot sleep 15 && $cf tunnel --no-autoupdate run --token $ARGO_TOKEN > $SB_DIR/argo.log 2>&1 &") | crontab - >/dev/null 2>&1 || true
    fi
  fi
  sleep 5
  echo "[信息] 固定隧道域名：${ARGO_DOMAIN:-（未知）}"
}

# 启动 Argo（按状态分发）：关闭时直接返回、什么都不做——不下
# cloudflared、不写单元、不动 crontab；隧道失败不阻塞主流程
start_argo() {
  argo_load_state
  if [[ "$ARGO_ENABLED" != "1" ]]; then
    return 0
  fi
  if [[ "$ARGO_MODE" == "fixed" ]]; then
    start_argo_fixed
    return 0
  fi
  echo "[信息] 启动 Argo 临时隧道…"
  local cf
  cf=$(ensure_cloudflared) || { echo "[警告] cloudflared 下载失败，跳过 Argo（不影响其他协议）"; ARGO_DOMAIN=""; return 0; }
  systemctl stop "$ARGO_UNIT" >/dev/null 2>&1 || true   # 若之前由 systemd 托管，先停掉避免双开
  pkill -f "$SB_DIR/cloudflared.*tunnel.*--url" >/dev/null 2>&1 || true
  sleep 1
  : > "$SB_DIR/argo.log"   # 清空旧日志，避免抓到上一次隧道的域名
  local argo_managed=0
  if start_argo_systemd "$cf tunnel --url http://localhost:${PORT_VMESS} --edge-ip-version auto --no-autoupdate --protocol http2"; then
    argo_managed=1
    echo "[信息] Argo 临时隧道已由 systemd 托管（崩溃自动拉起）"
  else
    nohup "$cf" tunnel --url "http://localhost:${PORT_VMESS}" \
      --edge-ip-version auto --no-autoupdate --protocol http2 \
      > "$SB_DIR/argo.log" 2>&1 &
  fi
  echo "[信息] 等待 Cloudflare 分配临时域名（最多约 60 秒）…"
  ARGO_DOMAIN=""
  local _i
  for _i in $(seq 1 20); do
    sleep 3
    ARGO_DOMAIN="$(current_argo_domain)"
    [[ -n "$ARGO_DOMAIN" ]] && break
  done
  if [[ -n "${ARGO_DOMAIN:-}" ]]; then
    echo "[信息] Argo 临时域名：$ARGO_DOMAIN（重启后会变化）"
    if [[ "$argo_managed" -eq 0 ]] && command -v crontab >/dev/null 2>&1; then
      # 宽匹配：切回临时隧道时，把固定隧道的开机自启也清掉，避免重启后双隧道齐跑
      (crontab -l 2>/dev/null | grep -v "$SB_DIR/cloudflared"
       echo "@reboot sleep 15 && $cf tunnel --url http://localhost:${PORT_VMESS} --edge-ip-version auto --no-autoupdate --protocol http2 > $SB_DIR/argo.log 2>&1 &") | crontab - >/dev/null 2>&1 || true
    fi
  else
    echo "[警告] 未能获取 Argo 域名，跳过 VMess+Argo（不影响其他协议）"
    echo "[提示] 隧道日志最后几行："
    tail -n 5 "$SB_DIR/argo.log" 2>/dev/null || true
    ARGO_DOMAIN=""
  fi
}

# 关闭 Argo 的运行时残留：停单元、删单元文件、杀进程、清 crontab 自启行。
# 状态文件由调用方先落盘（argo_save_state），本函数只管运行时
stop_argo() {
  systemctl stop "$ARGO_UNIT" >/dev/null 2>&1 || true
  systemctl disable "$ARGO_UNIT" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${ARGO_UNIT}.service"
  systemctl daemon-reload >/dev/null 2>&1 || true
  pkill -f "$SB_DIR/cloudflared.*tunnel" >/dev/null 2>&1 || true
  if command -v crontab >/dev/null 2>&1; then
    (crontab -l 2>/dev/null | grep -v "$SB_DIR/cloudflared") | crontab - >/dev/null 2>&1 || true
  fi
  ARGO_DOMAIN=""
}

# Argo 期望状态对齐检查：状态文件声明的开关/模式/令牌（或临时隧道的
# VMess 端口）与现行 Argo 单元 ExecStart（无 systemd 时为 crontab
# @reboot 行）不一致、或单元/自启行缺失时返回 0（需要重建），一致
# 返回 1。关闭状态下单元文件或自启行还在，同样算分歧（需要清理）。
argo_unit_diverged() {
  local _want _cur=""
  argo_load_state
  if [[ "$ARGO_ENABLED" != "1" ]]; then
    [[ -f "/etc/systemd/system/${ARGO_UNIT}.service" ]] && return 0
    if command -v crontab >/dev/null 2>&1 \
       && crontab -l 2>/dev/null | grep -q "$SB_DIR/cloudflared"; then
      return 0
    fi
    return 1
  fi
  if [[ "$ARGO_MODE" == "fixed" ]]; then
    _want="tunnel --no-autoupdate run --token $ARGO_TOKEN"
  else
    _want="tunnel --url http://localhost:${PORT_VMESS}"
  fi
  if [[ -f "/etc/systemd/system/${ARGO_UNIT}.service" ]]; then
    _cur=$(grep '^ExecStart=' "/etc/systemd/system/${ARGO_UNIT}.service" 2>/dev/null | sed 's/^ExecStart=//' || true)
  elif command -v crontab >/dev/null 2>&1; then
    _cur=$(crontab -l 2>/dev/null | grep '@reboot' | grep "$SB_DIR/cloudflared" || true)
  fi
  [[ -n "$_cur" && "$_cur" == *"$_want"* ]] && return 1
  return 0
}

# 安装时的 Argo 决策（默认关）：优先级——环境变量参数 SBOX_ARGO
# （off|temp|fixed，fixed 还需 SBOX_ARGO_TOKEN + SBOX_ARGO_DOMAIN）>
# 已有状态文件（尊重现状、不重复问）> 交互时一问（20 秒，回车/超时
# = 不开）> 关。结论落 ARGO_NOTE，安装结尾统一播报；本函数只写状态
# 文件，真正启动在 setup_service 之后由 start_argo 按状态执行。
argo_install_setup() {
  ARGO_NOTE=""
  if [[ -n "${SBOX_ARGO:-}" ]]; then
    case "$SBOX_ARGO" in
      temp)
        ARGO_ENABLED=1; ARGO_MODE="temp"; ARGO_TOKEN=""; ARGO_DOMAIN=""
        argo_save_state
        ARGO_NOTE="Argo 隧道：已开启（临时隧道，重启后域名会变；固定隧道可在菜单「Argo 隧道」里设置）"
        ;;
      fixed)
        if [[ "${SBOX_ARGO_TOKEN:-}" =~ ^[A-Za-z0-9+/=_-]+$ && "${SBOX_ARGO_DOMAIN:-}" =~ ^[A-Za-z0-9.-]+$ \
           && "${SBOX_ARGO_DOMAIN:-}" == *.* && "${SBOX_ARGO_DOMAIN:-}" != .* && "${SBOX_ARGO_DOMAIN:-}" != *. ]]; then
          ARGO_ENABLED=1; ARGO_MODE="fixed"; ARGO_TOKEN="$SBOX_ARGO_TOKEN"; ARGO_DOMAIN="$SBOX_ARGO_DOMAIN"
          argo_save_state
          ARGO_NOTE="Argo 隧道：已开启（固定隧道 $ARGO_DOMAIN；请确认 Cloudflare 侧 ingress 指向 http://localhost:${PORT_VMESS}，不一致时 Argo 链返回 502）"
        else
          echo "[警告] SBOX_ARGO=fixed 但 Token/域名参数不完整或格式不对，Argo 不开启"
          ARGO_NOTE="Argo 隧道：未开启（参数不完整；可在菜单「Argo 隧道」里设置）"
        fi
        ;;
      *)
        ARGO_ENABLED=0; ARGO_MODE="off"; ARGO_TOKEN=""; ARGO_DOMAIN=""
        argo_save_state
        ARGO_NOTE="Argo 隧道：未开启（可在菜单「Argo 隧道」里开启）"
        ;;
    esac
    echo "[信息] $ARGO_NOTE"
    return 0
  fi
  if [[ -f "$ARGO_ENV_FILE" ]]; then
    argo_load_state
    if [[ "$ARGO_ENABLED" == "1" ]]; then
      ARGO_NOTE="Argo 隧道：保持已有设置（$(argo_mode_desc)）"
    else
      ARGO_NOTE="Argo 隧道：未开启（可在菜单「Argo 隧道」里开启）"
    fi
    echo "[信息] $ARGO_NOTE"
    return 0
  fi
  if [[ "${ACTION:-}" == "install" && -t 0 && -z "${SBOX_YES:-}" ]]; then
    local _ans=""
    read -t "$CHOICE_TIMEOUT" -rp "Argo 隧道（VMess 经 Cloudflare 隧道的备用链）：回车/${CHOICE_TIMEOUT} 秒不输入 = 不开启；输入 t = 临时隧道；输入 f = 固定隧道（需 Token+域名）： " _ans || true
    case "${_ans,,}" in
      t|temp)
        ARGO_ENABLED=1; ARGO_MODE="temp"; ARGO_TOKEN=""; ARGO_DOMAIN=""
        argo_save_state
        ARGO_NOTE="Argo 隧道：已开启（临时隧道，重启后域名会变；固定隧道可在菜单「Argo 隧道」里设置）"
        echo "[信息] $ARGO_NOTE"
        return 0
        ;;
      f|fixed)
        local _tok="" _dom=""
        read -t "$INPUT_TIMEOUT" -rp "固定隧道 Token（Cloudflare 后台创建隧道时给出）： " _tok || _tok=""
        read -t "$INPUT_TIMEOUT" -rp "固定隧道域名（如 tun.example.com）： " _dom || _dom=""
        _dom=$(printf '%s' "$_dom" | tr -d '[:space:]' | tr 'A-Z' 'a-z')
        if [[ "$_tok" =~ ^[A-Za-z0-9+/=_-]+$ && "$_dom" =~ ^[a-z0-9.-]+$ \
           && "$_dom" == *.* && "$_dom" != .* && "$_dom" != *. ]]; then
          ARGO_ENABLED=1; ARGO_MODE="fixed"; ARGO_TOKEN="$_tok"; ARGO_DOMAIN="$_dom"
          argo_save_state
          ARGO_NOTE="Argo 隧道：已开启（固定隧道 $_dom；请确认 Cloudflare 侧 ingress 指向 http://localhost:${PORT_VMESS}，不一致时 Argo 链返回 502）"
          echo "[信息] $ARGO_NOTE"
          return 0
        fi
        echo "[警告] Token/域名不完整或格式不对，Argo 不开启（装完可在菜单「Argo 隧道」里设置）"
        ;;
    esac
  fi
  ARGO_NOTE="Argo 隧道：未开启（可在菜单「Argo 隧道」里开启）"
  echo "[信息] $ARGO_NOTE"
  return 0
}

# 装机判定为关时的遗留对齐：旧装机（如旧版临时隧道）没有状态文件、
# 判定按默认关，但遗留的 Argo 单元/自启/进程可能还在跑——播报与运行
# 不一致时在此顺手停干净（与 do_restart 的对齐同款），再继续安装；
# 判定为开时什么都不做
argo_align_off_after_install() {
  [[ "${ARGO_ENABLED:-0}" == "1" ]] && return 0
  if argo_unit_diverged || pgrep -f "$SB_DIR/cloudflared.*tunnel" >/dev/null 2>&1; then
    echo "[信息] 检测到旧装机遗留的 Argo 隧道仍在运行，按关闭状态清理对齐"
    stop_argo
  fi
}

# 加载已保存的配置，不存在则报错退出（菜单/动作路径共用）
load_env_or_exit() {
  if [[ ! -f "$ENV_FILE" ]]; then
    echo "[错误] 未找到配置文件 $ENV_FILE，请先运行安装"
    exit 1
  fi
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  argo_load_state
  if [[ "$ARGO_MODE" == "temp" && -z "$ARGO_DOMAIN" ]]; then
    ARGO_DOMAIN="$(current_argo_domain)"
  fi
}

# 重启（菜单项 3 与 restart 动作共用）：本体重启后对齐 Argo 期望状态。
# 配置无分歧时不扰动在跑的隧道——临时隧道一旦重连就会换域名、已分享
# 的链接随之作废；仅当隧道没在运行时才按现行配置把它拉起来。Argo
# 关闭时顺手清掉可能残留的单元/自启（外部手改状态文件后靠它对齐）。
do_restart() {
  [[ -f "$ENV_FILE" ]] && . "$ENV_FILE"
  restart_service
  argo_load_state
  if [[ "$ARGO_ENABLED" != "1" ]]; then
    if argo_unit_diverged; then stop_argo; fi
    return 0
  fi
  if argo_unit_diverged; then
    echo "[信息] 检测到 Argo 配置与运行状态不一致，按 argo.env 重新生成"
    start_argo
  elif [[ -d /run/systemd/system ]] || pidof systemd >/dev/null 2>&1; then
    systemctl is-active --quiet "$ARGO_UNIT" 2>/dev/null || start_argo
  else
    pgrep -f "$SB_DIR/cloudflared.*tunnel" >/dev/null 2>&1 || start_argo
  fi
}

# Argo 隧道管理子菜单（主菜单进入）：开（临时/固定）、关、抓域名都在这里
do_argo_menu() {
  load_env_or_exit
  while true; do
    argo_load_state
    if [[ "$ARGO_MODE" == "temp" && -z "$ARGO_DOMAIN" ]]; then
      ARGO_DOMAIN="$(current_argo_domain)"
    fi
    echo
    echo "---------- Argo 隧道管理 ----------"
    echo "当前状态：$(argo_mode_desc)"
    echo "转发目标：http://localhost:${PORT_VMESS:-（未知）}（本机 VMess 入站；固定隧道的 ingress 在 Cloudflare 侧管理，须与此一致）"
    echo " 1) 开启/重启临时隧道（trycloudflare 域名，重启会变）"
    echo " 2) 设置固定隧道（输入 Token + 域名后开启）"
    echo " 3) 关闭 Argo（停隧道、删自启，不留残留）"
    echo " 4) 重新抓取临时隧道域名并显示链接"
    echo " 0) 返回（回车/20 秒无输入默认返回）"
    local c
    c=$(read_choice "请选择 [0-4]：")
    case "$c" in
      1)
        ARGO_ENABLED=1; ARGO_MODE="temp"; ARGO_TOKEN=""; ARGO_DOMAIN=""
        argo_save_state
        start_argo
        print_links
        ;;
      2)
        local _tok="" _dom=""
        read -rp "输入 Argo Tunnel Token: " _tok || _tok=""
        read -rp "输入固定隧道域名（如 tun.example.com）: " _dom || _dom=""
        _dom=$(printf '%s' "$_dom" | tr -d '[:space:]' | tr 'A-Z' 'a-z')
        if [[ ! "$_tok" =~ ^[A-Za-z0-9+/=_-]+$ ]]; then
          echo "[错误] Token 格式不对（应为 Cloudflare 签发的长字符串，只含字母、数字与 +/=_- 等符号）"
          continue
        fi
        if [[ ! "$_dom" =~ ^[a-z0-9.-]+$ || "$_dom" != *.* || "$_dom" == .* || "$_dom" == *. ]]; then
          echo "[错误] 域名格式不对（示例：tun.example.com）"
          continue
        fi
        ARGO_ENABLED=1; ARGO_MODE="fixed"; ARGO_TOKEN="$_tok"; ARGO_DOMAIN="$_dom"
        argo_save_state
        echo "[提示] 请确认 Cloudflare 侧隧道 ingress 指向 http://localhost:${PORT_VMESS}，不一致时 Argo 链会返回 502"
        start_argo
        print_links
        echo "[完成] 已切换到固定隧道：$_dom"
        ;;
      3)
        ARGO_ENABLED=0; ARGO_MODE="off"; ARGO_TOKEN=""; ARGO_DOMAIN=""
        argo_save_state
        stop_argo
        print_links >/dev/null || true   # 顺手重写链接文件，去掉已关掉的 Argo 条目，不留死链接
        echo "[完成] Argo 已关闭（菜单里随时可重新开启）"
        ;;
      4)
        ARGO_DOMAIN="$(current_argo_domain)"
        if [[ -n "$ARGO_DOMAIN" ]]; then
          echo "[信息] 抓到域名：$ARGO_DOMAIN"
          print_links
        else
          echo "[警告] 日志里还没有域名，隧道可能没在跑或仍在启动中"
          tail -n 5 "$SB_DIR/argo.log" 2>/dev/null || true
        fi
        ;;
      0|"") return 0 ;;
      *) echo "无效选择：$c" ;;
    esac
  done
}

#----------------------------- 10. 链接 ---------------------------------------
get_ip() {
  # 配置里存过手填的公网 IP（auto.env 的 PUBLIC_IP）时优先用它：验解析、
  # 证书 SAN、链接生成都认这一个，不再重复探测/询问（格式与探测结果
  # 一致：IPv4 裸写、IPv6 带方括号）
  if [[ -n "${PUBLIC_IP:-}" ]]; then
    if [[ "$PUBLIC_IP" == *:* ]]; then echo "[$PUBLIC_IP]"; else echo "$PUBLIC_IP"; fi
    return 0
  fi
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
  argo_load_state
  if [[ "$ARGO_MODE" == "temp" && -z "$ARGO_DOMAIN" ]]; then
    ARGO_DOMAIN="$(current_argo_domain)"
  fi
  # 旧版（三协议）env 直接看链接会缺新协议字段：提示先重跑安装补齐，不硬拼坏链接
  if [[ -z "${PORT_VMESS:-}" || -z "${PORT_TUIC:-}" || -z "${PORT_ANYTLS:-}" \
     || -z "${PORT_TROJAN:-}" || -z "${PORT_NAIVE:-}" || -z "${PORT_VTLS:-}" \
     || -z "${TROJAN_PASS:-}" || -z "${TUIC_PASS:-}" || -z "${ANYTLS_PASS:-}" \
     || -z "${NAIVE_USER:-}" || -z "${NAIVE_PASS:-}" ]]; then
    echo "[提示] 当前配置还是旧版格式，请先重跑一次安装（身份与原端口不变，自动补齐新协议）再看链接"
    return 1
  fi
  local ip host ip_bare
  ip="$(get_ip)"
  ip_bare="${ip#[}"; ip_bare="${ip_bare%]}"   # 裸地址：仅 VMess 的 add 字段用（base64-JSON 不是 URI，不带方括号）
  host="$(hostname)"
  local vl_link vm_link hy_link tuic_link an_link ss_user ss_link tj_link nv_link vt_link ag_link
  vl_link="vless://${UUID}@${ip}:${PORT_REALITY}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI_REALITY}&fp=chrome&pbk=${PUBKEY}&sid=${SHORTID}&type=tcp&headerType=none#full-reality-${host}"
  vm_link="vmess://$(printf '{"add":"%s","aid":"0","host":"%s","id":"%s","net":"ws","path":"%s-vm","port":"%s","ps":"vm-ws-%s","tls":"","type":"none","v":"2"}' \
    "$ip_bare" "$SNI_SELF" "$UUID" "$UUID" "$PORT_VMESS" "$host" | b64)"
  hy_link="hysteria2://${HY2_PASS}@${ip}:${PORT_HY2}/?insecure=1&sni=${SNI_HY2}#full-hy2-${host}"
  tuic_link="tuic://${UUID}:${TUIC_PASS}@${ip}:${PORT_TUIC}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=${SNI_SELF}&insecure=1&allowInsecure=1&allow_insecure=1#full-tuic-${host}"
  an_link="anytls://${ANYTLS_PASS}@${ip}:${PORT_ANYTLS}?&sni=${SNI_SELF}&allowInsecure=1&insecure=1#full-anytls-${host}"
  ss_user=$(printf '%s' "${SS_METHOD}:${SS_KEY}" | base64 -w0 2>/dev/null | tr '+/' '-_' | tr -d '=')
  ss_link="ss://${ss_user}@${ip}:${PORT_SS}#full-ss-${host}"
  tj_link="trojan://${TROJAN_PASS}@${ip}:${PORT_TROJAN}?security=tls&sni=${SNI_SELF}&allowInsecure=1&insecure=1#full-trojan-${host}"
  nv_link="naive+https://${NAIVE_USER}:${NAIVE_PASS}@${ip}:${PORT_NAIVE}?sni=${SNI_SELF}&insecure=1&allowInsecure=1#full-naive-${host}"
  # 域名链：地址就用域名本身（用户自己的域名或临时域名都直连源站；
  # 用户装完去面板开了黄云后，同一条链接经 CF 回源照样能用，不用换）
  local _vt_host="${TLS_DOMAIN:-$SNI_SELF}" _vt_addr="${TLS_DOMAIN:-$ip}" _vt_ins="&allowInsecure=1"
  # 真证书生效时链接不用再允许不安全证书
  if [[ "${TLS_CERT_MODE:-self}" == "acme" ]] && is_user_domain; then _vt_ins=""; fi
  vt_link="vless://${UUID}@${_vt_addr}:${PORT_VTLS:-443}?encryption=none&security=tls&sni=${_vt_host}&fp=chrome&type=ws&host=${_vt_host}&path=${UUID}-vt${_vt_ins}#full-vtls-${host}"
  {
    echo "================ sing-box-coexist（全功能版）节点链接 ================"
    echo "生成时间：$(date '+%Y-%m-%d %H:%M:%S')"
    echo
    if [[ -z "$ip" ]]; then
      echo "[警告] 未能获取公网 IP：下方直连链接的服务器地址为空，使用前请把 @: 替换为 @服务器IP:"
      echo "       （VMess 的 add 字段同理），或稍后重跑 sbc links"
      echo
    fi
    echo "VLESS + Reality (TCP/${PORT_REALITY})"
    echo "$vl_link"
    echo
    echo "VMess + WS (TCP/${PORT_VMESS})"
    echo "$vm_link"
    echo
    if [[ "${ARGO_ENABLED:-0}" == "1" ]]; then
      if [[ -n "${ARGO_DOMAIN:-}" ]]; then
        local _argo_note="临时隧道，重启后会变"
        [[ "$ARGO_MODE" == "fixed" ]] && _argo_note="固定隧道"
        ag_link="vmess://$(printf '{"add":"cloudflare-ech.com","aid":"0","host":"%s","id":"%s","net":"ws","path":"%s-vm","port":"443","ps":"vm-argo-%s","tls":"tls","sni":"%s","fp":"chrome","type":"none","v":"2"}' \
          "$ARGO_DOMAIN" "$UUID" "$UUID" "$host" "$ARGO_DOMAIN" | b64)"
        echo "VMess + Argo 隧道（${ARGO_DOMAIN}，${_argo_note}）"
        echo "$ag_link"
        echo
      else
        echo "VMess + Argo 隧道：已开启但域名未取得（隧道未启动或仍在建立，sbc 菜单「Argo 隧道」里可重新抓取）"
        echo
      fi
    fi
    echo "Hysteria2 (UDP/${PORT_HY2})"
    echo "$hy_link"
    echo
    echo "TUIC v5 (UDP/${PORT_TUIC})"
    echo "$tuic_link"
    echo
    echo "AnyTLS (TCP/${PORT_ANYTLS})"
    echo "$an_link"
    echo
    echo "Shadowsocks 2022 (TCP+UDP/${PORT_SS})"
    echo "$ss_link"
    echo
    echo "Trojan (TCP/${PORT_TROJAN})"
    echo "$tj_link"
    echo
    echo "Naive (TCP/${PORT_NAIVE})"
    echo "$nv_link"
    echo
    echo "VLESS + WS + TLS（域名：${TLS_DOMAIN:-未设置}，TCP/${PORT_VTLS:-443}）"
    if is_user_domain; then
      if [[ "${TLS_CERT_MODE:-self}" == "acme" ]]; then
        echo "（自己的域名 + Let's Encrypt 真证书）"
      else
        echo "（自己的域名 + 自签证书）"
      fi
    elif [[ "${TLS_DOMAIN_AUTO:-1}" == "1" ]]; then
      echo "（临时域名 + 自签证书，自签直连）"
    else
      echo "（自签证书）"
    fi
    echo "$vt_link"
    echo
    echo "======================================================="
    echo "提示：链接已保存到 $LINKS_FILE；管理菜单：sbc"
  } | tee "$LINKS_FILE"
  chmod 600 "$LINKS_FILE"
}

#----------------------------- 11. 卸载 ---------------------------------------
do_uninstall() {
  echo "[信息] 卸载 sing-box-coexist…"
  # 解析记录是装机人自己在面板加的，脚本不碰；只提醒一句去向
  if [[ -f "$ENV_FILE" ]]; then
    TLS_DOMAIN=$(grep '^TLS_DOMAIN=' "$ENV_FILE" 2>/dev/null | cut -d'"' -f2 || true)
    if is_user_domain; then
      echo "[信息] 提醒：你在面板里给 ${TLS_DOMAIN} 加的那条解析记录是自己的，脚本没有动它；不用了请去面板自行删除。"
    fi
  fi
  systemctl stop "$UNIT" >/dev/null 2>&1 || true
  systemctl disable "$UNIT" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${UNIT}.service"
  systemctl stop "$ARGO_UNIT" >/dev/null 2>&1 || true
  systemctl disable "$ARGO_UNIT" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${ARGO_UNIT}.service"
  systemctl daemon-reload >/dev/null 2>&1 || true
  pkill -f "$SB_DIR/sing-box run" >/dev/null 2>&1 || true
  pkill -f "$SB_DIR/cloudflared.*tunnel" >/dev/null 2>&1 || true
  if command -v crontab >/dev/null 2>&1; then
    (crontab -l 2>/dev/null | grep -v "sing-box-coexist" | grep -v "$SB_DIR/cloudflared") | crontab - >/dev/null 2>&1 || true
  fi
  rm -f /usr/local/bin/sbc
  # sbox 兼容包装是本脚本写的才删（来历不明的同名文件不碰）
  if grep -q "sing-box-coexist" /usr/local/bin/sbox 2>/dev/null; then
    rm -f /usr/local/bin/sbox
  fi
  rm -rf "$SB_DIR" "$LINKS_FILE"
  rm -f /var/log/sing-box-coexist.log
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
    load_warp_env
    argo_load_state
    echo "======== sing-box-coexist v${SCRIPT_VERSION}（全功能版）========"
    echo " 状态：$st ｜ 核心：v$(cat "$SB_DIR/core.version" 2>/dev/null || echo 未知) ｜ WARP：$(warp_mode_desc) ｜ Argo：$(argo_mode_desc)"
    echo " 1) 查看链接"
    echo " 2) 改域名（自己的域名，手动加记录）"
    echo " 3) 重启服务"
    echo " 4) WARP 出站（开关/模式）"
    echo " 5) Argo 隧道（开关/临时/固定）"
    echo " 6) 更换端口（全部端口重新随机）"
    echo " 7) 重置身份（UUID/密钥/密码全换，旧链接失效）"
    echo " 8) 更新证书（自有域名先试真证书）"
    echo " 9) 更新核心"
    echo " 10) 更新脚本"
    echo " 11) 卸载"
    echo " 0) 退出（回车/20 秒无输入默认退出）"
    local c
    c=$(read_choice "请选择 [0-11]：")
    case "$c" in
      1) print_links ;;
      2)
        . "$ENV_FILE"
        do_change_domain
        ;;
      3) do_restart ;;
      4)
        . "$ENV_FILE"
        do_warp_menu
        ;;
      5) do_argo_menu ;;
      6)
        . "$ENV_FILE"
        local used=" "
        PORT_REALITY=$(rand_port "$used"); used+=" $PORT_REALITY "
        PORT_VMESS=$(rand_port "$used"); used+=" $PORT_VMESS "
        PORT_HY2=$(rand_port "$used"); used+=" $PORT_HY2 "
        PORT_TUIC=$(rand_port "$used"); used+=" $PORT_TUIC "
        PORT_ANYTLS=$(rand_port "$used"); used+=" $PORT_ANYTLS "
        PORT_SS=$(rand_port "$used"); used+=" $PORT_SS "
        PORT_TROJAN=$(rand_port "$used"); used+=" $PORT_TROJAN "
        PORT_NAIVE=$(rand_port "$used"); used+=" $PORT_NAIVE "
        PORT_VTLS=$(pick_vtls_port "$used")
        save_env; write_config; open_firewall; restart_service; start_argo; print_links
        ;;
      7)
        local y
        y=$(read_choice "确认重置身份？旧链接将全部失效 [y/N]：")
        if [[ "$y" == "y" || "$y" == "Y" ]]; then
          . "$ENV_FILE"   # 先载入 TLS 域名等状态，save_env 时不把它们冲掉
          gen_identity; gen_hy2_cert; gen_certs; write_config; restart_service; start_argo; print_links
        else
          echo "已取消"
        fi
        ;;
      8)
        . "$ENV_FILE"
        do_update_cert
        ;;
      9) detect_arch; do_update_core ;;
      10) if do_update_script; then exec "$SB_DIR/sing-box-coexist.sh" menu; fi ;;
      11)
        local y2
        y2=$(read_choice "确认卸载 sing-box-coexist？[y/N]：")
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
      ensure_cron_running
      ensure_time_sync
      install_core
      load_or_gen_identity
      warp_install_setup
      argo_install_setup
      argo_align_off_after_install
      gen_hy2_cert
      gen_certs
      ensure_vtls_cert "${PROMPT_DOMAIN_SET:-0}"
      write_config
      open_firewall
      fix_selinux
      setup_service
      acme_verify_or_fallback || true
      start_argo
      vtls_local_check
      setup_shortcut
      print_links
      echo
      echo "[完成] sing-box-coexist 已就绪：链接见上"
      echo "管理菜单命令：sbc"
      [[ -n "${WARP_NOTE:-}" ]] && echo "$WARP_NOTE"
      [[ -n "${ARGO_NOTE:-}" ]] && echo "$ARGO_NOTE"
      [[ -n "${DOMAIN_ORANGE_NOTE:-}" ]] && echo "$DOMAIN_ORANGE_NOTE"
      if ! is_user_domain; then
        echo "备注：想用自己的域名，运行 sbc 选「改域名」即可，不用重装。"
      fi
      echo "备注：若链接连不上，先去云厂商控制台确认安全组已放行这九个端口——脚本只能开本机防火墙，管不了云厂商的安全组。"
      ;;
    uninstall) do_uninstall ;;
    update-core) detect_arch; do_update_core ;;
    update-script) do_update_script ;;
    links) print_links ;;
    change-argo) load_env_or_exit; do_argo_menu ;;
    restart) do_restart ;;
    warp-reroll)
      [[ -f "$ENV_FILE" ]] || { echo "[错误] 尚未安装，请先运行安装"; exit 1; }
      . "$ENV_FILE"
      warp_reroll
      ;;
    menu) do_menu ;;
    *) echo "用法：$0 [install|uninstall|update-core|update-script|links|restart|change-argo|warp-reroll|menu|version]"; exit 1 ;;
  esac
}

# 直接执行或经 curl 管道执行时跑主流程；被 source 加载时不跑（便于测试）
if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]}" == "$0" ]]; then
  main
fi
