#!/bin/bash
###############################################################################
# sing-box-nant 一键安装脚本（NantCore 定制核心版）
#
# 定位：使用自建核心 NantCore 的 sing-box 发行：
#   - 核心为 NantCore（基于 sing-box 定制编译，全功能构建），
#     支持 sing-box 的数十种主流协议，脚本功能按此持续补齐
#   - 当前脚本提供：VLESS + Reality（TCP）/ VMess + WS（TCP）/
#     Hysteria2（UDP）/ TUIC v5（UDP）/ AnyTLS（TCP）/
#     Shadowsocks 2022（TCP+UDP）/ Trojan（TCP）/ Naive（TCP）/
#     VLESS + WS + TLS 域名链（TCP）；另带 WARP 出站（WireGuard 端点：
#     纯 IPv6 机器默认开启 IPv4 经 WARP，有 IPv4 出口默认关闭，失败降级）
#
# 用法：
#   安装：curl -fsSL https://raw.githubusercontent.com/lnant/sing-box-auto/main/sing-box-nant.sh | sudo bash
#   菜单：sudo sbn
#   卸载：sudo sbn 选 7，或 curl … | sudo bash -s -- uninstall
#
# 特性：
#   - 全程零交互：UUID、密钥、密码、端口全部自动生成（端口 10000-60000 随机）
#   - 幂等：重复运行保持 UUID/密钥/端口不变，客户端链接不变
#   - 独立目录 /etc/s-box-nant、独立服务名 sing-box-nant，可与其他版本同机共存
#   - 受限容器（OpenVZ 等）自动适配系统 DNS 解析，正常机器配置不受影响
#   - 纯 IPv6 机器自动经 DNS64 绕行下载核心；核心下载带 sha256 校验
#   - 安装后打印全部九条链接，并保存到 /root/singbox-nant-links.txt
###############################################################################
set -euo pipefail

ACTION="${1:-install}"
# 通过 sbn 快捷命令调用且无参数时默认进菜单；其他方式（脚本文件/管道）无参数默认执行安装
if [[ $# -eq 0 && "$(basename "$0")" == "sbn" ]]; then
  ACTION="menu"
fi
SCRIPT_VERSION="0.2.0"
CORE_VERSION_DEFAULT="1.0"   # NantCore 仓库尚无更新 Release 时的兜底版本
CORE_REPO="lnant/nantcore"   # 核心二进制发布仓（脚本本体仍在本仓）
REPO="lnant/sing-box-auto"

if [[ "$ACTION" == "version" ]]; then
  echo "sing-box-nant v${SCRIPT_VERSION}（NantCore 定制核心版）"
  exit 0
fi

SB_DIR="${NANT_DIR:-/etc/s-box-nant}"
UNIT="sing-box-nant"
ENV_FILE="$SB_DIR/nant.env"
LINKS_FILE="/root/singbox-nant-links.txt"
CF_ENV_FILE="$SB_DIR/cf.env"     # 持久化：Cloudflare API Token 与本脚本建的解析记录（600 权限）
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

#----------------------------- 5. 定制核心 -----------------------------------
core_asset() { echo "nantcore-server-linux-${ARCH}"; }

# 下载指定版本核心并验 sha256，装到 $SB_DIR/sing-box；成功返回 0
download_core() {
  local ver="$1" tmp
  tmp=$(mktemp -d)
  echo "[信息] 下载定制核心 v${ver}（${ARCH}）…"
  curl -fSL --retry 2 -o "$tmp/$(core_asset)" \
    "https://github.com/${CORE_REPO}/releases/download/v${ver}/$(core_asset)" || { rm -rf "$tmp"; return 1; }
  curl -fSL --retry 2 -o "$tmp/SHA256SUMS" \
    "https://github.com/${CORE_REPO}/releases/download/v${ver}/SHA256SUMS" || { rm -rf "$tmp"; return 1; }
  ( cd "$tmp" && grep " $(core_asset)\$" SHA256SUMS | sha256sum -c - >/dev/null 2>&1 ) \
    || { echo "[错误] 核心 sha256 校验不通过，已放弃"; rm -rf "$tmp"; return 1; }
  install -m 755 "$tmp/$(core_asset)" "$SB_DIR/sing-box"
  echo "$ver" > "$SB_DIR/core.version"
  rm -rf "$tmp"
  echo "[信息] 核心 v${ver} 安装完成（sha256 校验通过）"
}

# NantCore 仓库里最新的 Release 版本（不带 v）；取不到返回空
fetch_latest_core() {
  ensure_github || true
  curl -fsSL --max-time 15 "https://api.github.com/repos/${CORE_REPO}/releases?per_page=30" 2>/dev/null \
    | jq -r '.[].tag_name' 2>/dev/null | grep -m1 '^v' | sed 's/^v//' || true
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

#----------------------------- 5.5 Cloudflare 与 TLS 域名 --------------------
# 仅在自动域名需要时用：Token 来源（优先级）环境变量 SBOX_CF_TOKEN >
# $CF_ENV_FILE。没有 Token 时这些函数根本不会被调到（域名走 sslip.io 兜底）。
load_cf_token() {
  CF_API_TOKEN=""
  if [[ -n "${SBOX_CF_TOKEN:-}" ]]; then
    CF_API_TOKEN="$SBOX_CF_TOKEN"
  elif [[ -f "$CF_ENV_FILE" ]]; then
    CF_API_TOKEN=$(grep '^CF_API_TOKEN=' "$CF_ENV_FILE" 2>/dev/null | cut -d'"' -f2 || true)
    # 自愈：不管这份文件是哪个版本建的、权限是不是 600，读到就纠回 600
    chmod 600 "$CF_ENV_FILE" 2>/dev/null || true
  fi
  # 字符集校验：Token 只应含字母/数字/下划线/连字符，含其他字符一律视为
  # 无效并忽略（cf.env 只用 grep 解析、从不 source，这一步是双保险）
  if [[ -n "$CF_API_TOKEN" && ! "$CF_API_TOKEN" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "[警告] Cloudflare API Token 含非法字符，已忽略" >&2
    CF_API_TOKEN=""
  fi
  [[ -n "$CF_API_TOKEN" ]]
}

save_cf_token() {
  # 只更新 Token 这一行，保留 cf.env 里已有的 zone/record/host 记录
  # （旧版是整文件重写，放在重跑路径上会把记录 bookkeeping 抹掉）
  local _tmp
  _tmp=$(mktemp)
  if [[ -f "$CF_ENV_FILE" ]]; then
    grep -v '^CF_API_TOKEN=' "$CF_ENV_FILE" > "$_tmp" 2>/dev/null || true
  else
    : > "$_tmp"
  fi
  printf 'CF_API_TOKEN="%s"\n' "$CF_API_TOKEN" >> "$_tmp"
  mv -f "$_tmp" "$CF_ENV_FILE"
  chmod 600 "$CF_ENV_FILE"
}

# $1=方法 $2=路径 $3=JSON 体（可选）；成功输出响应体，失败返回非 0
cf_api() {
  local _m="$1" _p="$2" _b="${3:-}"
  if [[ -n "$_b" ]]; then
    curl -fsSL --max-time 25 -X "$_m" "https://api.cloudflare.com/client/v4$_p" \
      -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
      --data "$_b" 2>/dev/null
  else
    curl -fsSL --max-time 25 -X "$_m" "https://api.cloudflare.com/client/v4$_p" \
      -H "Authorization: Bearer $CF_API_TOKEN" 2>/dev/null
  fi
}

# 逐级剥掉最左标签，找到 $1 所属的已激活 zone；输出 "zone_id<TAB>zone_name"
cf_zone_for_domain() {
  local cand="$1" _resp _zid
  while [[ "$cand" == *.* ]]; do
    if _resp=$(cf_api GET "/zones?name=$cand&status=active"); then
      _zid=$(printf '%s' "$_resp" | jq -r --arg n "$cand" '[.result[] | select(.name==$n) | .id][0] // empty' 2>/dev/null || true)
      if [[ -n "$_zid" ]]; then
        printf '%s\t%s\n' "$_zid" "$cand"
        return 0
      fi
    fi
    cand="${cand#*.}"
  done
  return 1
}

# 把 $2 的 A 记录指向 $3 并开橙色云代理；输出 record_id
cf_upsert_a_record() {
  local _zid="$1" _fqdn="$2" _ip="$3" _resp _rid _body
  _resp=$(cf_api GET "/zones/$_zid/dns_records?type=A&name=$_fqdn") || return 1
  _rid=$(printf '%s' "$_resp" | jq -r '.result[0].id // empty' 2>/dev/null || true)
  _body=$(printf '{"type":"A","name":"%s","content":"%s","proxied":true,"ttl":1}' "$_fqdn" "$_ip")
  if [[ -n "$_rid" ]]; then
    cf_api PUT "/zones/$_zid/dns_records/$_rid" "$_body" >/dev/null || return 1
  else
    _resp=$(cf_api POST "/zones/$_zid/dns_records" "$_body") || return 1
    _rid=$(printf '%s' "$_resp" | jq -r '.result.id // empty' 2>/dev/null || true)
  fi
  printf '%s' "$_rid"
}

# 把 $2 的 AAAA 记录指向 $3（裸 IPv6，不带方括号）并开橙色云代理；输出 record_id
# 与 cf_upsert_a_record 对称，纯 IPv6 机器走这条路径
cf_upsert_aaaa_record() {
  local _zid="$1" _fqdn="$2" _ip="$3" _resp _rid _body
  _resp=$(cf_api GET "/zones/$_zid/dns_records?type=AAAA&name=$_fqdn") || return 1
  _rid=$(printf '%s' "$_resp" | jq -r '.result[0].id // empty' 2>/dev/null || true)
  _body=$(printf '{"type":"AAAA","name":"%s","content":"%s","proxied":true,"ttl":1}' "$_fqdn" "$_ip")
  if [[ -n "$_rid" ]]; then
    cf_api PUT "/zones/$_zid/dns_records/$_rid" "$_body" >/dev/null || return 1
  else
    _resp=$(cf_api POST "/zones/$_zid/dns_records" "$_body") || return 1
    _rid=$(printf '%s' "$_resp" | jq -r '.result.id // empty' 2>/dev/null || true)
  fi
  printf '%s' "$_rid"
}

# 给域名套上 Cloudflare：解析指向本机（橙色云）+ SSL 模式改完全（严格），
# 并把 zone/record 记进 cf.env，供卸载时清理本脚本建的记录
cf_setup_domain() {
  local _fqdn="$1" _z _zid _ip _bare _rtype _rid
  # 先取令牌（写 cf.env 的 Token 行要用；直接调本函数时也保证有值，
  # 不依赖调用方事先 load 过——set -u 下空变量会直接炸掉）
  load_cf_token || { echo "[错误] 没有可用的 Cloudflare API Token，无法设置解析"; return 1; }
  # 闷头活先打招呼：下面几步调 CF 接口、约 40 秒不出字是正常的，别关终端
  echo "[信息] 正在向 Cloudflare 建解析记录并设 SSL 模式（约 40 秒，期间没有输出是正常的，请别关终端）…"
  _z=$(cf_zone_for_domain "$_fqdn") || { echo "[错误] 在 Cloudflare 找不到 $_fqdn 所属的已激活域名（确认域名已托管到该账号）"; return 1; }
  _zid="${_z%%$'\t'*}"
  _ip="$(get_ip)"
  _bare="${_ip#[}"; _bare="${_bare%]}"   # 归一化：裸地址（CF API 的 content 不接受方括号写法）
  if [[ "$_bare" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    _rid=$(cf_upsert_a_record "$_zid" "$_fqdn" "$_bare") || { echo "[错误] Cloudflare 解析记录写入失败"; return 1; }
    _rtype="A"
  elif [[ "$_bare" == *:* ]]; then
    _rid=$(cf_upsert_aaaa_record "$_zid" "$_fqdn" "$_bare") || { echo "[错误] Cloudflare 解析记录写入失败"; return 1; }
    _rtype="AAAA"
  else
    echo "[错误] 未取得公网 IP（v4/v6 均无），无法设置解析"; return 1
  fi
  cf_api PATCH "/zones/$_zid/settings/ssl" '{"value":"strict"}' >/dev/null 2>&1 \
    || echo "[警告] SSL 模式自动设置失败，请在 Cloudflare 手动改为「完全（严格）」"
  {
    printf 'CF_API_TOKEN="%s"\n' "$CF_API_TOKEN"
    printf 'CF_ZONE_ID="%s"\n' "$_zid"
    printf 'CF_RECORD_ID="%s"\n' "$_rid"
    printf 'CF_RECORD_TYPE="%s"\n' "$_rtype"
    printf 'CF_HOST="%s"\n' "$_fqdn"
  } > "$CF_ENV_FILE"
  chmod 600 "$CF_ENV_FILE"
  TLS_ACME_MODE="cf"
  echo "[信息] 已套 Cloudflare：$_fqdn → $_bare（$_rtype，橙色云代理），SSL 模式=完全（严格）"
}

# 删除本脚本在 Cloudflare 建的解析记录（卸载时调用；没有记录则静默跳过）
cf_delete_managed_record() {
  [[ -f "$CF_ENV_FILE" ]] || return 0
  local _zid _rid
  _zid=$(grep '^CF_ZONE_ID=' "$CF_ENV_FILE" 2>/dev/null | cut -d'"' -f2 || true)
  _rid=$(grep '^CF_RECORD_ID=' "$CF_ENV_FILE" 2>/dev/null | cut -d'"' -f2 || true)
  [[ -n "$_zid" && -n "$_rid" ]] || return 0
  load_cf_token || return 0
  # 删之前先回查：记录还在、且名字确实是本脚本记下的 CF_HOST 才删，
  # 防止本地状态过期时误删别人的记录
  local _host _rname _chk
  _host=$(grep '^CF_HOST=' "$CF_ENV_FILE" 2>/dev/null | cut -d'"' -f2 || true)
  if [[ -n "$_host" ]]; then
    _chk=$(cf_api GET "/zones/$_zid/dns_records/$_rid" 2>/dev/null || true)
    _rname=$(printf '%s' "${_chk:-}" | jq -r '.result.name // empty' 2>/dev/null || true)
    [[ "$_rname" == "$_host" ]] || return 0
  fi
  cf_api DELETE "/zones/$_zid/dns_records/$_rid" >/dev/null 2>&1 || true
}

# 有 CF Token 时的自动域名：在账号域名下开一个随机子域名套上 CF，
# 配合 ACME 真证书使用——不暴露源站 IP，也不依赖任何第三方临时域名服务
ensure_cf_auto_domain() {
  local _resp _zid _zname _label _fqdn _r
  # 重跑复用：cf.env 里已有本脚本建过的自动域名时直接复用它（只改指向、
  # 不新建记录），免得装一半重跑一次就多一条删不到的孤儿记录
  local _reuse="" _rz="" _rzid="" _rchk=""
  _reuse=$(grep '^CF_HOST=' "$CF_ENV_FILE" 2>/dev/null | cut -d'"' -f2 || true)
  if [[ -n "$_reuse" ]]; then
    _rz=$(cf_zone_for_domain "$_reuse" 2>/dev/null || true)
    if [[ -n "$_rz" ]] && { [[ -z "${SBOX_CF_ZONE:-}" ]] || [[ "$_reuse" == *".$SBOX_CF_ZONE" ]]; }; then
      # 回读确认记录本身还在：只剩 zone、记录已被删掉的不复用旧名，
      # 落回下面新建标签的逻辑，免得把别人手动删掉的记录又建回来
      _rzid="${_rz%%$'\t'*}"
      _rchk=$(cf_api GET "/zones/$_rzid/dns_records?name=$_reuse" 2>/dev/null || true)
      if ! printf '%s' "$_rchk" | jq -e --arg n "$_reuse" '[.result[]? | select(.name==$n)] | length > 0' >/dev/null 2>&1; then
        _reuse=""
      fi
    else
      _reuse=""
    fi
  fi
  if [[ -n "$_reuse" ]]; then
    TLS_DOMAIN="$_reuse"
    if ! cf_setup_domain "$_reuse"; then
      TLS_DOMAIN=""
      return 1
    fi
    TLS_DOMAIN_AUTO=1
    TLS_ACME=1
    echo "[信息] TLS 域名复用已有记录（Cloudflare）：$TLS_DOMAIN（真证书 + 橙色云代理）"
    return 0
  fi
  if [[ -n "${SBOX_CF_ZONE:-}" ]]; then
    _resp=$(cf_api GET "/zones?name=$SBOX_CF_ZONE&status=active") || return 1
    _zid=$(printf '%s' "$_resp" | jq -r --arg n "$SBOX_CF_ZONE" '[.result[] | select(.name==$n) | .id][0] // empty' 2>/dev/null || true)
    _zname=$(printf '%s' "$_resp" | jq -r --arg n "$SBOX_CF_ZONE" '[.result[] | select(.name==$n) | .name][0] // empty' 2>/dev/null || true)
  else
    _resp=$(cf_api GET "/zones?status=active&per_page=50") || return 1
    _zid=$(printf '%s' "$_resp" | jq -r '.result[0].id // empty' 2>/dev/null || true)
    _zname=$(printf '%s' "$_resp" | jq -r '.result[0].name // empty' 2>/dev/null || true)
    # 账号里有多个域名时不许默默选错：明确播报建在哪个域名下，并给出指定办法
    local _nz
    _nz=$(printf '%s' "$_resp" | jq -r '.result | length' 2>/dev/null || echo 1)
    if [[ "${_nz:-1}" -gt 1 && -n "$_zname" ]]; then
      echo "[信息] Cloudflare 账号共有 ${_nz} 个域名，自动域名将建在 ${_zname} 下（指定其他域名：SBOX_CF_ZONE=域名）"
    fi
  fi
  [[ -n "$_zid" && -n "$_zname" ]] || return 1
  _r=$(head -c 3 /dev/urandom | od -An -tx1 | tr -d ' \n')
  _label="sbox-${_r:-a1b2c3}"
  _fqdn="$_label.$_zname"
  TLS_DOMAIN="$_fqdn"
  if ! cf_setup_domain "$_fqdn"; then
    TLS_DOMAIN=""
    return 1
  fi
  TLS_DOMAIN_AUTO=1
  TLS_ACME=1
  echo "[信息] TLS 域名自动生成（Cloudflare）：$TLS_DOMAIN（真证书 + 橙色云代理）"
}

# TLS 域名兜底：已设置则保留；未设置时优先用 Cloudflare 自动子域名（需已有
# Token），否则用公网 IP 生成 sslip.io 临时域名（解析直达本机、立即可用；
# IPv4 点换横杠、IPv6 冒号换横杠，两种写法均可解析出对应记录），走自签直连。
ensure_tls_domain() {
  if [[ -n "${TLS_DOMAIN:-}" ]]; then
    TLS_DOMAIN_AUTO="${TLS_DOMAIN_AUTO:-0}"
    TLS_ACME="${TLS_ACME:-0}"
    return 0
  fi
  if load_cf_token; then
    # 环境变量给的 Token 落盘一次（600 权限，只更新 Token 行），之后重跑
    # /卸载不用再给；cf.env 里已有的 Token 不动
    if [[ -n "${SBOX_CF_TOKEN:-}" ]]; then save_cf_token; fi
    if ensure_cf_auto_domain; then
      return 0
    fi
  fi
  local _ip _bare
  _ip="$(get_ip)"
  _bare="${_ip#[}"; _bare="${_bare%]}"   # 归一化：裸地址
  TLS_ACME=0
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

save_env() {
  cat > "$ENV_FILE" <<EOF
UUID="$UUID"
PRIVKEY="$PRIVKEY"
PUBKEY="$PUBKEY"
SHORTID="$SHORTID"
PORT_REALITY="$PORT_REALITY"
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
TLS_ACME="${TLS_ACME:-0}"
TLS_ACME_MODE="${TLS_ACME_MODE:-cf}"
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

load_or_gen_identity() {
  if [[ -f "$ENV_FILE" ]]; then
    . "$ENV_FILE"
    if [[ -n "${UUID:-}" && -n "${PRIVKEY:-}" && -n "${PUBKEY:-}" && -n "${SHORTID:-}" \
       && -n "${PORT_REALITY:-}" && -n "${PORT_HY2:-}" && -n "${PORT_SS:-}" \
       && -n "${HY2_PASS:-}" && -n "${SS_KEY:-}" ]]; then
      echo "[信息] 检测到已有配置，身份与端口保持不变（幂等重跑）"
      # 旧版（三协议）env 升级路径：缺失的新协议凭据/端口逐个补齐，已有值一律
      # 不动（逐个显式分配并校验，不用链式 &&——失败时会留下空值直到写配置才炸）
      local _filled=0 _pv _p
      for _pv in TROJAN_PASS TUIC_PASS ANYTLS_PASS NAIVE_PASS; do
        if [[ -z "${!_pv:-}" ]]; then
          printf -v "$_pv" '%s' "$(openssl rand -hex 16)"
          _filled=1
        fi
      done
      if [[ -z "${NAIVE_USER:-}" ]]; then
        NAIVE_USER=$(openssl rand -hex 6)
        _filled=1
      fi
      local used=" ${PORT_REALITY:-} ${PORT_HY2:-} ${PORT_SS:-} ${PORT_VMESS:-} ${PORT_TROJAN:-} ${PORT_TUIC:-} ${PORT_ANYTLS:-} ${PORT_VTLS:-} ${PORT_NAIVE:-} "
      for _pv in PORT_VMESS PORT_TROJAN PORT_TUIC PORT_ANYTLS PORT_NAIVE; do
        if [[ -z "${!_pv:-}" ]]; then
          _p=$(rand_port "$used") || { echo "[错误] 端口分配失败，无法继续"; exit 1; }
          printf -v "$_pv" '%s' "$_p"
          used+=" $_p "
          _filled=1
        fi
      done
      if [[ -z "${PORT_VTLS:-}" ]]; then
        PORT_VTLS=$(pick_vtls_port "$used") || { echo "[错误] 端口分配失败，无法继续"; exit 1; }
        _filled=1
      fi
      if (( _filled == 1 )); then
        echo "[信息] 已为新增协议补齐凭据与端口（原有身份与端口不变）"
      fi
      ensure_tls_domain
      save_env
      return 0
    fi
    echo "[警告] 已有配置不完整，将重新生成身份信息"
  fi
  gen_identity
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

#----------------------------- 7. 写配置 --------------------------------------
write_config() {
  echo "[信息] 写入 sing-box 配置（九个入站）…"
  # 域名 TLS 入站的 tls 段两种形态：默认自签证书；有 Cloudflare 自动域名时走
  # sing-box 内置 ACME（DNS-01 走 Cloudflare，自动续期，不占 80/443、不装额外软件）
  local _tls_sni="${TLS_DOMAIN:-$SNI_SELF}" vtls_tls
  local _self_tls="\"enabled\": true, \"server_name\": \"$_tls_sni\", \"certificate_path\": \"$SB_DIR/cert.pem\", \"key_path\": \"$SB_DIR/private.key\""
  if [[ "${TLS_ACME:-0}" == "1" && "${TLS_ACME_MODE:-cf}" == "direct" ]]; then
    # 直连真证书：域名已解析到本机时走 ACME 通用验证（HTTP-01 / TLS-ALPN-01）
    vtls_tls="\"enabled\": true, \"server_name\": \"$_tls_sni\", \"certificate_provider\": {\"type\": \"acme\", \"domain\": [\"$_tls_sni\"], \"data_directory\": \"$SB_DIR/acme\", \"email\": \"admin@$_tls_sni\", \"provider\": \"letsencrypt\"}"
  elif [[ "${TLS_ACME:-0}" == "1" ]]; then
    local _tok=""
    if [[ -f "$CF_ENV_FILE" ]]; then
      _tok=$(grep '^CF_API_TOKEN=' "$CF_ENV_FILE" 2>/dev/null | cut -d'"' -f2 || true)
    fi
    if [[ -n "$_tok" ]]; then
      vtls_tls="\"enabled\": true, \"server_name\": \"$_tls_sni\", \"certificate_provider\": {\"type\": \"acme\", \"domain\": [\"$_tls_sni\"], \"data_directory\": \"$SB_DIR/acme\", \"email\": \"admin@$_tls_sni\", \"provider\": \"letsencrypt\", \"disable_http_challenge\": true, \"disable_tls_alpn_challenge\": true, \"dns01_challenge\": {\"provider\": \"cloudflare\", \"api_token\": \"$_tok\"}}"
    else
      # 状态不一致兜底（ACME 开着但 Token 丢失）：宁可降级自签，也不能生成坏配置
      echo "[警告] ACME 已启用但读不到 Cloudflare Token，域名 TLS 链暂用自签证书"
      vtls_tls="$_self_tls"
    fi
  else
    vtls_tls="$_self_tls"
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
  "outbounds": [{"type": "direct", "tag": "direct"}]${_warp_tail}
}
EOF
  chmod 600 "$SB_DIR/sb.json"   # 内含 Reality 私钥与（ACME 模式下）CF Token，按密钥文件对待
  "$SB_DIR/sing-box" check -c "$SB_DIR/sb.json" >/dev/null 2>&1 \
    || { echo "[错误] 配置校验失败"; exit 1; }
  echo "[信息] 配置校验通过"
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
    cat > "/etc/systemd/system/${UNIT}.service" <<EOF
[Unit]
Description=sing-box-nant service
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
      echo "[信息] sing-box-nant 运行中"
    else
      echo "[错误] 服务启动失败，日志如下："
      journalctl -u "$UNIT" --no-pager -n 20 2>/dev/null || true
      exit 1
    fi
  else
    echo "[警告] 未检测到 systemd，改用后台方式启动（带同样的内存刹车参数）"
    pkill -f "$SB_DIR/sing-box run" >/dev/null 2>&1 || true
    GOMEMLIMIT=128MiB GOGC=50 nohup "$SB_DIR/sing-box" run -c "$SB_DIR/sb.json" \
      >/var/log/sing-box-nant.log 2>&1 &
    sleep 2
    pgrep -f "$SB_DIR/sing-box run" >/dev/null || { echo "[错误] 后台启动失败"; exit 1; }
    if command -v crontab >/dev/null 2>&1; then
      (crontab -l 2>/dev/null | grep -v "sing-box-nant" ; echo "@reboot sleep 10 && GOMEMLIMIT=128MiB GOGC=50 $SB_DIR/sing-box run -c $SB_DIR/sb.json >/var/log/sing-box-nant.log 2>&1") | crontab - >/dev/null 2>&1 || true
    fi
    echo "[信息] sing-box-nant 已在后台启动"
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
      >/var/log/sing-box-nant.log 2>&1 &
    echo "[信息] 已重启（后台模式）"
  fi
}

setup_shortcut() {
  # sbn 快捷命令：先下到临时文件校验内容再替换，避免下坏文件覆盖可用版本
  local tmp
  tmp=$(mktemp)
  if curl -fsSL --max-time 30 -o "$tmp" \
      "https://raw.githubusercontent.com/${REPO}/main/sing-box-nant.sh" 2>/dev/null \
     && head -n 1 "$tmp" | grep -q '^#!/bin/bash' && grep -q 'sing-box-nant' "$tmp"; then
    install -m 755 "$tmp" /usr/local/bin/sbn
    echo "[信息] 快捷命令已安装：sbn（root 下运行打开菜单）"
  else
    echo "[警告] 快捷命令下载失败，可稍后重跑安装或手动下载脚本使用"
  fi
  rm -f "$tmp"
  # 若本次是本地文件运行，把脚本副本留在 SB_DIR 便于离线管理
  if [[ -f "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "/usr/local/bin/sbn" ]]; then
    cp -f "${BASH_SOURCE[0]}" "$SB_DIR/sing-box-nant.sh" 2>/dev/null || true
    chmod 755 "$SB_DIR/sing-box-nant.sh" 2>/dev/null || true
  fi
}

#----------------------------- 9.5 ACME 签发验证 ------------------------------
# ACME 首次签发要等 DNS-01 验证，最长约 2 分钟；验证域名链真的能握手，
# 不通过就自动回退自签证书（照七合一），绝不留一条握不上手的链接报喜
acme_verify_or_fallback() {
  [[ "${TLS_ACME:-0}" == "1" ]] || return 0
  echo "[信息] 等待 Let's Encrypt 签发证书（DNS-01 验证，最长约 2 分钟）…"
  local _ok=0 _i _code
  for _i in $(seq 1 40); do
    sleep 3
    # 注意：WS 握手成功（101）后连接保持开启，curl 会以超时退出（28）——
    # 不能把 curl 放进受 pipefail 影响的管道里判断，必须先捕获状态码再比较
    _code=$(curl -s --max-time 5 --resolve "${TLS_DOMAIN}:${PORT_VTLS}:127.0.0.1" \
      "https://${TLS_DOMAIN}:${PORT_VTLS}/${UUID}-vt" \
      -H "Connection: Upgrade" -H "Upgrade: websocket" \
      -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: x3JJHMbDL1EzLkh9GBhXDw==" \
      -o /dev/null -w '%{http_code}' 2>/dev/null || true)
    if [[ "$_code" == "101" ]]; then
      _ok=1
      break
    fi
  done
  if [[ "$_ok" == "1" ]]; then
    echo "[完成] 真证书已签发，域名 TLS 链已通过 WebSocket 握手验证"
    return 0
  fi
  echo "[警告] 证书签发或握手验证未通过（sing-box 日志见服务日志），自动回退自签证书"
  TLS_ACME=0
  save_env
  # 回退自签后 Cloudflare 若仍是「完全（严格）」会因源站证书不受信报 526，同步降为「完全」
  if [[ "${TLS_ACME_MODE:-cf}" != "direct" && -f "$CF_ENV_FILE" ]] && load_cf_token; then
    local _zid_fb
    _zid_fb=$(grep '^CF_ZONE_ID=' "$CF_ENV_FILE" 2>/dev/null | cut -d'"' -f2 || true)
    if [[ -n "$_zid_fb" ]]; then
      cf_api PATCH "/zones/$_zid_fb/settings/ssl" '{"value":"full"}' >/dev/null 2>&1 || true
      echo "[信息] 已同步把 Cloudflare SSL 模式降为「完全」，与自签证书匹配"
    fi
  fi
  rm -f "$SB_DIR/cert.pem" "$SB_DIR/private.key"
  gen_certs
  write_config
  setup_service
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
local _conf="$_dir/wgcf-profile.conf" _addr _ep _cid _hex
WARP_PRIVATE_KEY=$(grep -E '^PrivateKey[[:space:]]*=' "$_conf" | head -n 1 | cut -d= -f2- | tr -d ' \r' || true)
_addr=$(grep -E '^Address[[:space:]]*=' "$_conf" | head -n 1 | cut -d= -f2- | tr -d ' \r' || true)
WARP_V4=$(printf '%s' "$_addr" | tr ',' '\n' | grep -E '^[0-9.]+/' | head -n 1 | cut -d/ -f1 || true)
WARP_V6=$(printf '%s' "$_addr" | tr ',' '\n' | grep ':' | head -n 1 | cut -d/ -f1 || true)
WARP_PEER_KEY=$(grep -E '^PublicKey[[:space:]]*=' "$_conf" | head -n 1 | cut -d= -f2- | tr -d ' \r' || true)
WARP_MTU=$(grep -E '^MTU[[:space:]]*=' "$_conf" | head -n 1 | cut -d= -f2- | tr -d ' \r' || true)
_ep=$(grep -E '^Endpoint[[:space:]]*=' "$_conf" | head -n 1 | cut -d= -f2- | tr -d ' \r' || true)
WARP_ENDPOINT_HOST="${_ep%:*}"
WARP_ENDPOINT_PORT="${_ep##*:}"
# reserved（client_id 三字节）：wgcf 的输出文件里带 client_id 就解出来存下；
# 没有就留空（endpoint 不写 reserved 字段），是否可用以启用后出口实测为准
WARP_RESERVED=""
_cid=$(grep -hoE 'client_id"?[[:space:]]*[:=][[:space:]]*"?[A-Za-z0-9+/=]+' \
"$_dir/wgcf-account.toml" "$_conf" 2>/dev/null | grep -oE '[A-Za-z0-9+/=]+$' | head -n 1 || true)
if [[ -n "$_cid" ]]; then
_hex=$(printf '%s' "$_cid" | base64 -d 2>/dev/null | od -An -tu1 | tr -s ' ' || true)
WARP_RESERVED=$(printf '%s' "$_hex" | awk '{if (NF>=3) printf "%s,%s,%s", $1, $2, $3}')
fi
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

# 展示当前 WARP 出口 IP 与落地国家：未启用时直接返回 1、不输出、也不起
# 探针；启用时起临时 sing-box 经 WARP 拉 trace 再解析（探针配置与
# warp_probe 共用，临时进程与目录用完即清理）。取不到返回 1 不输出，
# 调用方一律以 || true 承接，绝不阻塞菜单与安装流程
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
kill "$_pid" >/dev/null 2>&1 || true
wait "$_pid" 2>/dev/null || true
rm -rf "$_dir"
[[ -n "$_line" ]] || return 1
printf '%s\n' "$_line"
return 0
}

# 回滚 WARP 变更：恢复 nant.env / sb.json / warp.env 三件套备份并重启服务
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
echo "[错误] WARP 已写入配置但出口自检未通过，已自动回滚到之前的状态"
warp_rollback
return 1
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
# _warp_commit 原子生效。调用前须已加载 nant.env（菜单分支负责）
warp_apply() {
local _mode="$1"
load_warp_env
if [[ "$_mode" != "off" ]]; then
if ! warp_profile_complete; then
if ! warp_register; then
echo "[错误] WARP 注册未完成，未做任何修改"
return 1
fi
fi
fi
_warp_commit "$_mode"
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

# WARP 出站子菜单（主菜单进入，调用前已加载 nant.env）
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
echo " 0) 返回（回车/20 秒无输入默认返回）"
local c
c=$(read_choice "请选择 [0-3]：")
case "$c" in
1) warp_apply ipv4 || true;;
2) warp_apply all || true;;
3) warp_apply off || true;;
0|"") return 0;;
*) echo "无效选择：$c";;
esac
done
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
  local vl_link vm_link hy_link tuic_link an_link ss_user ss_link tj_link nv_link vt_link
  vl_link="vless://${UUID}@${ip}:${PORT_REALITY}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI_REALITY}&fp=chrome&pbk=${PUBKEY}&sid=${SHORTID}&type=tcp&headerType=none#nant-reality-${host}"
  vm_link="vmess://$(printf '{"add":"%s","aid":"0","host":"%s","id":"%s","net":"ws","path":"%s-vm","port":"%s","ps":"vm-ws-%s","tls":"","type":"none","v":"2"}' \
    "$ip_bare" "$SNI_SELF" "$UUID" "$UUID" "$PORT_VMESS" "$host" | b64)"
  hy_link="hysteria2://${HY2_PASS}@${ip}:${PORT_HY2}/?insecure=1&sni=${SNI_HY2}#nant-hy2-${host}"
  tuic_link="tuic://${UUID}:${TUIC_PASS}@${ip}:${PORT_TUIC}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=${SNI_SELF}&insecure=1&allowInsecure=1&allow_insecure=1#nant-tuic-${host}"
  an_link="anytls://${ANYTLS_PASS}@${ip}:${PORT_ANYTLS}?&sni=${SNI_SELF}&allowInsecure=1&insecure=1#nant-anytls-${host}"
  ss_user=$(printf '%s' "${SS_METHOD}:${SS_KEY}" | base64 -w0 2>/dev/null | tr '+/' '-_' | tr -d '=')
  ss_link="ss://${ss_user}@${ip}:${PORT_SS}#nant-ss-${host}"
  tj_link="trojan://${TROJAN_PASS}@${ip}:${PORT_TROJAN}?security=tls&sni=${SNI_SELF}&allowInsecure=1&insecure=1#nant-trojan-${host}"
  nv_link="naive+https://${NAIVE_USER}:${NAIVE_PASS}@${ip}:${PORT_NAIVE}?sni=${SNI_SELF}&insecure=1&allowInsecure=1#nant-naive-${host}"
  # 域名链：地址默认用域名本身；域名是本脚本套的 CF（cf.env 记有 CF_HOST）时
  # 改用 CF 通用保底地址 cloudflare-ech.com 作入口（sni/host 仍是本域名、CF 按
  # SNI 回源），源站 IP+端口在客户端到源站这段路上被干扰时经 CF 绕开（照七合一）
  local _vt_host="${TLS_DOMAIN:-$SNI_SELF}" _vt_addr="${TLS_DOMAIN:-$ip}" _vt_ins="&allowInsecure=1"
  [[ "${TLS_ACME:-0}" == "1" ]] && _vt_ins=""
  if [[ -n "${TLS_DOMAIN:-}" && "${TLS_ACME_MODE:-cf}" != "direct" && -f "$CF_ENV_FILE" ]] \
     && grep -q "^CF_HOST=\"${TLS_DOMAIN}\"" "$CF_ENV_FILE" 2>/dev/null; then
    _vt_addr="cloudflare-ech.com"
  fi
  vt_link="vless://${UUID}@${_vt_addr}:${PORT_VTLS:-443}?encryption=none&security=tls&sni=${_vt_host}&fp=chrome&type=ws&host=${_vt_host}&path=${UUID}-vt${_vt_ins}#nant-vtls-${host}"
  {
    echo "================ sing-box-nant 节点链接 ================"
    echo "生成时间：$(date '+%Y-%m-%d %H:%M:%S')"
    echo
    if [[ -z "$ip" ]]; then
      echo "[警告] 未能获取公网 IP：下方直连链接的服务器地址为空，使用前请把 @: 替换为 @服务器IP:"
      echo "       （VMess 的 add 字段同理），或稍后重跑 sbn links"
      echo
    fi
    echo "VLESS + Reality (TCP/${PORT_REALITY})"
    echo "$vl_link"
    echo
    echo "VMess + WS (TCP/${PORT_VMESS})"
    echo "$vm_link"
    echo
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
    if [[ "${TLS_ACME:-0}" == "1" ]]; then
      echo "（真证书 + Cloudflare 代理）"
    elif [[ "${TLS_DOMAIN_AUTO:-1}" == "1" ]]; then
      echo "（临时域名 + 自签证书，自签直连）"
    else
      echo "（自签证书）"
    fi
    echo "$vt_link"
    echo
    echo "======================================================="
    echo "提示：链接已保存到 $LINKS_FILE；管理菜单：sudo sbn"
  } | tee "$LINKS_FILE"
  chmod 600 "$LINKS_FILE"
}

#----------------------------- 11. 卸载 ---------------------------------------
do_uninstall() {
  echo "[信息] 卸载 sing-box-nant…"
  cf_delete_managed_record   # 若脚本在 Cloudflare 建过解析记录（自动域名），一并删掉不留残留
  systemctl stop "$UNIT" >/dev/null 2>&1 || true
  systemctl disable "$UNIT" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${UNIT}.service"
  systemctl daemon-reload >/dev/null 2>&1 || true
  pkill -f "$SB_DIR/sing-box run" >/dev/null 2>&1 || true
  if command -v crontab >/dev/null 2>&1; then
    (crontab -l 2>/dev/null | grep -v "sing-box-nant") | crontab - >/dev/null 2>&1 || true
  fi
  rm -f /usr/local/bin/sbn
  rm -rf "$SB_DIR" "$LINKS_FILE"
  rm -f /var/log/sing-box-nant.log
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
    echo "======== sing-box-nant v${SCRIPT_VERSION} ========"
    echo " 状态：$st ｜ 核心：v$(cat "$SB_DIR/core.version" 2>/dev/null || echo 未知) ｜ WARP：$(warp_mode_desc)"
    echo " 1) 查看链接"
    echo " 2) 重启服务"
    echo " 3) 更换端口（全部端口重新随机）"
    echo " 4) 重置身份（UUID/密钥/密码全换，旧链接失效）"
    echo " 5) WARP 出站（开关/模式）"
    echo " 6) 更新核心"
    echo " 7) 卸载"
    echo " 0) 退出（回车/20 秒无输入默认退出）"
    local c
    c=$(read_choice "请选择 [0-7]：")
    case "$c" in
      1) print_links ;;
      2) restart_service ;;
      3)
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
        save_env; write_config; open_firewall; restart_service; print_links
        ;;
      4)
        local y
        y=$(read_choice "确认重置身份？旧链接将全部失效 [y/N]：")
        if [[ "$y" == "y" || "$y" == "Y" ]]; then
          . "$ENV_FILE"   # 先载入 TLS 域名等状态，save_env 时不把它们冲掉
          gen_identity; gen_hy2_cert; gen_certs; write_config; restart_service; print_links
        else
          echo "已取消"
        fi
        ;;
      5)
        . "$ENV_FILE"
        do_warp_menu
        ;;
      6) detect_arch; do_update_core ;;
      7)
        local y2
        y2=$(read_choice "确认卸载 sing-box-nant？[y/N]：")
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
      warp_install_setup
      gen_hy2_cert
      gen_certs
      write_config
      open_firewall
      fix_selinux
      setup_service
      acme_verify_or_fallback
      setup_shortcut
      print_links
      echo
      echo "[完成] sing-box-nant 已就绪：九条链接见上，管理菜单运行 sudo sbn"
      [[ -n "${WARP_NOTE:-}" ]] && echo "$WARP_NOTE"
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
