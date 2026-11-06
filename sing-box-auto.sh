#!/bin/bash
###############################################################################
# sing-box 全自动一键安装脚本（6 协议版）
#
# 功能：零交互，一次装好以下 6 种协议
#   [1] VLESS + Reality (TCP)
#   [2] VMess + WebSocket (TCP)
#   [3] VMess + Argo 隧道 (Cloudflare 临时隧道，转发到 VMess-WS)
#   [4] Hysteria2 (UDP)
#   [5] TUIC v5 (UDP)
#   [6] AnyTLS (TCP)
#
# 用法：
#   安装：curl -fsSL https://raw.githubusercontent.com/lnant/sing-box-auto/main/sing-box-auto.sh | sudo bash
#   卸载：curl -fsSL https://raw.githubusercontent.com/lnant/sing-box-auto/main/sing-box-auto.sh | sudo bash -s -- uninstall
#   管理菜单：curl -fsSL https://raw.githubusercontent.com/lnant/sing-box-auto/main/sing-box-auto.sh | sudo bash -s -- menu
#   （或下载后 sudo bash sing-box-auto.sh menu）
#   动作参数：menu | change-uuid | change-reality | change-cert | change-argo
#            | change-ports | show-links | restart | uninstall | update-script | update-core | version
#   快捷命令：安装时会自动装好 sbox 命令（/usr/local/bin/sbox），之后直接打
#            sbox 就进管理菜单（非 root 会自动 sudo 提权），sbox <动作> 执行对应操作
#
# 特性：
#   - 全程无交互：UUID、密码、Reality 密钥对全部自动生成
#   - 随机端口：新装时 5 个协议端口在 10000-60000 内随机分配（互不冲突，避开已占用），
#     多台服务器端口各不相同；重跑/升级保留已有端口，菜单 5 可手动改
#   - 防火墙：自动从配置提取监听端口并在 firewalld/ufw/iptables 放行，
#     配置增减协议或换端口时自动跟上
#   - 证书：自动生成 www.bing.com 自签证书（供 Hy2/TUIC/AnyTLS/VMess-WS 使用）
#   - 幂等：重复运行保留已有 UUID/端口/密钥，只重写配置并重启；
#     也能识别互联网上知名同类脚本留下的配置并导入
#   - 安装后打印全部客户端链接，并保存到 /root/singbox-links.txt
#
# 参考互联网上知名的相关 sing-box 一键脚本，交互点已全部自动化，详见本仓库 README.md
###############################################################################
set -euo pipefail

#----------------------------- 0. 参数与常量 ---------------------------------
# 通过 sbox 快捷命令调用且无参数时默认进菜单；其他方式无参数默认执行安装
if [[ "$(basename "$0")" == "sbox" && $# -eq 0 ]]; then
  ACTION="menu"
else
  ACTION="${1:-install}"        # install | uninstall | menu | change-uuid | change-reality | change-cert | change-argo | change-ports | show-links | restart | update-script | update-core | version
fi

SCRIPT_VERSION="1.1.1"          # 脚本版本号（与仓库 tag / Release 对应，见 CHANGELOG.md）

# version 动作只打印版本，不需要 root / 已安装，提前处理
if [[ "$ACTION" == "version" ]]; then
  echo "sing-box-auto v${SCRIPT_VERSION}（全自动 6 协议版）"
  exit 0
fi

SB_DIR="/etc/s-box"
UNIT="sing-box-auto"           # systemd 服务名：用专属名，避免覆盖机器上已有的其他 sing-box 安装
ARGO_UNIT="${UNIT}-argo"       # Argo 隧道的 systemd 服务名（cloudflared 交 systemd 托管，崩溃自动拉起）
ENV_FILE="$SB_DIR/auto.env"    # 持久化：UUID/端口/密钥，重跑时复用
LINKS_FILE="/root/singbox-links.txt"

# 端口分配：新装时随机（10000-60000），重跑/升级保留已有端口（见 load_or_gen_identity）

SNI_REALITY="apple.com"        # Reality 伪装域名（常见默认值）
SNI_SELF="www.bing.com"        # 自签证书 CN

if [[ "$EUID" -ne 0 ]]; then
  # sbox 快捷命令：非 root 时自动提权，opc 下直接打 sbox 就能进菜单
  if [[ "$(basename "$0")" == "sbox" ]]; then
    exec sudo "$0" "$@"
  fi
  echo "[错误] 请以 root 运行，例如：sudo bash $0"
  exit 1
fi

#----------------------------- 1. 系统识别 -----------------------------------
detect_os() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
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
  if [[ "$PKG" == "apk" ]]; then
    echo "[警告] Alpine 未充分验证：运行前请确认已 apk add bash，且 dcron 已启用（rc-update add dcron），否则脚本解释器或开机自启会出问题"
  fi
  echo "[信息] 系统：${OS_ID}，包管理器：${PKG}"
}

detect_arch() {
  case "$(uname -m)" in
    x86_64)  ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    armv7l)  ARCH="armv7" ;;
    *) echo "[错误] 不支持的架构：$(uname -m)"; exit 1 ;;
  esac
  echo "[信息] 架构：${ARCH}"
}

install_deps() {
  # 先检查缺什么：齐了就直接跳过，dnf 在小内存机器上又慢又吃内存
  local need="" pkgs="" c
  command -v curl >/dev/null 2>&1 || need="$need curl"
  command -v jq >/dev/null 2>&1 || need="$need jq"
  command -v openssl >/dev/null 2>&1 || need="$need openssl"
  command -v tar >/dev/null 2>&1 || need="$need tar"
  { command -v ss >/dev/null 2>&1 || command -v ip >/dev/null 2>&1; } || need="$need iproute"
  command -v crontab >/dev/null 2>&1 || need="$need cron"
  if [[ -z "${need// }" ]]; then
    echo "[信息] 依赖已齐全，跳过安装"
    return 0
  fi
  # 包名映射（cron、iproute 在不同发行版名字不一样）
  for c in $need; do
    case "$c" in
      cron)
        case "$PKG" in
          apt) pkgs="$pkgs cron" ;;
          apk) pkgs="$pkgs dcron" ;;
          *) pkgs="$pkgs cronie" ;;
        esac ;;
      iproute)
        case "$PKG" in
          apt|apk) pkgs="$pkgs iproute2" ;;
          *) pkgs="$pkgs iproute" ;;
        esac ;;
      *) pkgs="$pkgs $c" ;;
    esac
  done
  # apt/apk 顺带补 ca-certificates：极简镜像缺它时 curl 拉 https 会证书校验失败（与精简版对齐）
  case "$PKG" in
    apt|apk) pkgs="$pkgs ca-certificates" ;;
  esac
  echo "[信息] 安装缺失依赖：${pkgs} …"
  # 转成数组再传给包管理器，避免未引用展开的分词歧义（SC2086）
  local -a pkgarr
  read -ra pkgarr <<< "$pkgs"
  case "$PKG" in
    apt) apt-get update -y >/dev/null 2>&1 || true
         DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgarr[@]}" >/dev/null 2>&1 || true ;;
    dnf) dnf install -y --setopt=install_weak_deps=False "${pkgarr[@]}" >/dev/null 2>&1 || true ;;
    yum) yum install -y "${pkgarr[@]}" >/dev/null 2>&1 || true ;;
    apk) apk add --no-cache "${pkgarr[@]}" >/dev/null 2>&1 || true ;;
  esac
  command -v curl >/dev/null 2>&1 || { echo "[错误] curl 安装失败"; exit 1; }
  command -v jq >/dev/null 2>&1 || { echo "[错误] jq 安装失败"; exit 1; }
}

check_memory() {
  # 小内存机器预警：dnf 单次可占 350M+，无 swap 时易 OOM 卡死整机（实测 498M 机器被顶爆过）
  local mem_kb swap_kb
  mem_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
  swap_kb=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
  if [ "$mem_kb" -gt 0 ] && [ "$mem_kb" -lt 1048576 ] && [ "$swap_kb" -eq 0 ]; then
    echo "[警告] 内存较小 ($((mem_kb / 1024))M) 且无 swap，装依赖时 dnf 可能 OOM 导致卡死"
    echo "[警告] 建议先加 swap：fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile"
    echo "[警告] 继续安装…"
  fi
}

disable_dnf_makecache() {
  # 小内存机器（<2G）禁用 dnf-makecache 定时器：后台自动跑 dnf 易致 OOM
  # 只影响软件源缓存的自动更新，手动 dnf 不受影响
  case "$PKG" in
    dnf|yum) ;;
    *) return 0 ;;
  esac
  command -v systemctl >/dev/null 2>&1 || return 0
  systemctl list-unit-files 2>/dev/null | grep -q "^dnf-makecache\.timer" || return 0
  local mem_kb
  mem_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
  if [ "$mem_kb" -gt 0 ] && [ "$mem_kb" -lt 2097152 ]; then
    if systemctl is-enabled --quiet dnf-makecache.timer 2>/dev/null; then
      systemctl disable --now dnf-makecache.timer >/dev/null 2>&1 || true
      echo "[信息] 已禁用 dnf-makecache 定时器（小内存机器，后台自动 dnf 易致 OOM）"
    fi
  fi
}

# 容器环境提示：兜底自启依赖 cron 的 @reboot，容器里通常没有真正的 reboot 语义、
# 也不跑 cron 守护——提前说明，避免用户误以为重启后还能自动拉起
check_container() {
  if [[ -f /.dockerenv ]] || { command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt --container >/dev/null 2>&1; }; then
    echo "[提示] 检测到容器环境：开机自启（systemd / cron @reboot）在容器中通常不生效，"
    echo "       本次安装只保证容器运行期间可用；容器重建后请重新运行安装命令"
  fi
}

#----------------------------- 2. 端口分配 -----------------------------------
# 端口是否被占用（TCP/UDP 一起查）
port_in_use() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    if ss -tunlp 2>/dev/null | grep -Eo ':[0-9]+' | grep -qw ":$p"; then
      return 0
    fi
  fi
  return 1
}

# 随机分配空闲端口（10000-60000），避开已占用和本次已分配的
rand_port() {
  # 在 10000-60000 内随机取一个空闲端口
  # 参数 $1：已分配端口列表（空格分隔，如 " 12345 23456 "），避免 5 个协议互相冲突
  local allocated="$1" p tries=0
  while (( tries < 100 )); do
    p=$(( (RANDOM * 32768 + RANDOM) % 50001 + 10000 ))
    if [[ "$allocated" != *" $p "* ]] && ! port_in_use "$p"; then
      echo "$p"
      return 0
    fi
    tries=$((tries + 1))
  done
  echo "[错误] 无法分配随机空闲端口" >&2
  return 1   # 只 return 不 exit：本函数多在命令替换（子 shell）里调用，失败语义交给调用方明确处理
}

#----------------------------- 3. 防火墙放行 ---------------------------------
# 自适应放行：从已生成的 sing-box 配置里提取所有 inbound 监听端口，
# TCP+UDP 双开。以后脚本增减协议、换端口，这里自动跟上，无需维护端口列表。
# 必须在 write_config 之后调用。云厂商安全组/安全列表需在控制台另行放行。
open_firewall() {
  local ports=""
  if [[ -f "$SB_DIR/sb.json" ]] && command -v jq >/dev/null 2>&1; then
    ports=$(jq -r '.inbounds[].listen_port // empty' "$SB_DIR/sb.json" 2>/dev/null | sort -un | tr '\n' ' ' || true)
  fi
  # 回退：配置文件不存在或 jq 不可用时，用 PORT_* 变量
  if [[ -z "${ports// }" ]]; then
    ports="${PORT_VLESS:-} ${PORT_VMESS:-} ${PORT_HY2:-} ${PORT_TUIC:-} ${PORT_ANYTLS:-}"
  fi
  if [[ -z "${ports// }" ]]; then
    echo "[警告] 未找到需要放行的端口，跳过防火墙设置"
    return 0
  fi
  echo "[信息] 放行防火墙端口：${ports}（TCP+UDP）…"
  local p
  # firewalld：仅当正在运行时加规则，不擅自启停它
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    for p in $ports; do
      firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null 2>&1
      firewall-cmd --permanent --add-port="${p}/udp" >/dev/null 2>&1
    done
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
  # ufw：仅当已启用时加规则
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    for p in $ports; do
      ufw allow "${p}/tcp" >/dev/null 2>&1
      ufw allow "${p}/udp" >/dev/null 2>&1
    done
  fi
  # iptables：显式加 ACCEPT 规则（已存在则跳过，不动其他规则）
  if command -v iptables >/dev/null 2>&1; then
    for p in $ports; do
      iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null \
        || iptables -I INPUT 1 -p tcp --dport "$p" -j ACCEPT 2>/dev/null || true
      iptables -C INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null \
        || iptables -I INPUT 1 -p udp --dport "$p" -j ACCEPT 2>/dev/null || true
    done
    # 持久化（尽力而为）
    command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1 || true
    service iptables save >/dev/null 2>&1 || true
  fi
  # ip6tables：纯 IPv6 机器上 iptables 管不到 v6，需单独放行
  if command -v ip6tables >/dev/null 2>&1; then
    for p in $ports; do
      ip6tables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null \
        || ip6tables -I INPUT 1 -p tcp --dport "$p" -j ACCEPT 2>/dev/null || true
      ip6tables -C INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null \
        || ip6tables -I INPUT 1 -p udp --dport "$p" -j ACCEPT 2>/dev/null || true
    done
    service ip6tables save >/dev/null 2>&1 || true
  fi
  # 回读校验：至少确认一条路径真的放行成功。纯 nftables 等未覆盖的防火墙下，
  # 上面的命令可能全部静默失败——那种情况必须明确警告，不能笼统报"已放行"
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

#----------------------------- 4. 安装 sing-box ------------------------------
# GitHub 可达性预检（装机时在主流程开头先跑，fetch_latest_version 里也会兜底调用）：
# api.github.com / github.com 至今只有 IPv4 地址，纯 IPv6 机器、或 IPv4 出站损坏
# （形同纯 v6）的机器会死在查版本/下内核这一步。判断看行为不看配置：
#   - GitHub 已可达（v4 正常，或线路自带 NAT64）→ 什么都不动，直接装
#   - 不可达但有 IPv6 出站 → 先跑一段引导：把 resolv.conf 换成公共 DNS64
#     （nat64.net，改前备份、换后复探、仍不通自动还原），通了再继续装
# 本段所有提示走 stderr：fetch_latest_version 的 stdout 是版本号，不能污染。
RESOLV_CONF="${RESOLV_CONF:-/etc/resolv.conf}"
DNS64_SERVERS=("2a01:4f8:c2c:123f::1" "2a01:4ff:f0:9876::1" "2a01:4f9:c010:3f02::1")
_GH_OK=""

gh_probe() {  # 拿到任意 HTTP 状态码即算可达（403 是 GitHub 限流，不是连不上）
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
    echo "[警告] 可手动把 sing-box 二进制预置到 $SB_DIR/sing-box、cloudflared 预置到 $SB_DIR/cloudflared 后重跑安装（脚本会跳过下载）。" >&2
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
    echo "[警告] resolv.conf 由 systemd-resolved 托管，无法自动切换 DNS64；请手动把上行 DNS 改为 DNS64 后重试。" >&2
    return 1
  fi
  [[ -w "$RESOLV_CONF" ]] || { echo "[警告] $RESOLV_CONF 不可写，无法自动切换 DNS64。" >&2; return 1; }
  local bak="${RESOLV_CONF}.sbox-bak"
  [[ -f "$bak" ]] || cp -L "$RESOLV_CONF" "$bak" 2>/dev/null || true
  echo "[信息] 引导：切换 DNS 到公共 DNS64（nat64.net），经 NAT64 绕行访问 GitHub…" >&2
  { for s in "${DNS64_SERVERS[@]}"; do echo "nameserver $s"; done; } > "$RESOLV_CONF"
  # NAT64 冷启动慢（真机实测：换完 DNS 立刻探活常超时，稍等就通）：复探给 3 次
  # 机会、间隔递增，别一次判死刑就还原——真机上就是靠第二次调用救回来的
  local try
  for try in 1 2 3; do
    if gh_probe; then
      _GH_OK=1
      echo "[信息] DNS64 已生效，GitHub 可达，继续安装。原 DNS 配置备份在 $bak（不再需要绕行时可还原）。" >&2
      return 0
    fi
    [[ "$try" -lt 3 ]] && sleep $((try * 3))
  done
  [[ -f "$bak" ]] && cp "$bak" "$RESOLV_CONF" 2>/dev/null || true
  echo "[警告] DNS64 绕行未生效，已还原 DNS 配置；请预置二进制（见上）或检查 IPv6 线路后重试。" >&2
  return 1
}

# 取 sing-box 最新正式版版本号（不含 v 前缀）；失败时输出空字符串
fetch_latest_version() {
  local ver=""
  ensure_github || true
  # 优先 GitHub API，失败回退到 releases 页面解析
  ver=$(curl -fsSL --max-time 15 --retry 2 https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null | sed 's/^v//' || true)
  if [[ -z "$ver" ]]; then
    ver=$(curl -fsSL --max-time 15 --retry 2 https://github.com/SagerNet/sing-box/releases/latest 2>/dev/null | grep -oP 'tag/v\K[0-9.]+' | head -n 1 || true)
  fi
  echo "$ver"
}

# 下载并解压指定版本到 $SB_DIR；失败返回非 0（不直接退出，由调用方决定回滚或报错）
download_singbox() {
  local ver="$1"
  local name="sing-box-${ver}-linux-${ARCH}"
  curl -fSL --retry 2 --max-time 120 -o "$SB_DIR/sing-box.tar.gz" \
    "https://github.com/SagerNet/sing-box/releases/download/v${ver}/${name}.tar.gz" || return 1
  tar xzf "$SB_DIR/sing-box.tar.gz" -C "$SB_DIR" || return 1
  mv -f "$SB_DIR/$name/sing-box" "$SB_DIR/sing-box" || return 1
  rm -rf "$SB_DIR/sing-box.tar.gz" "$SB_DIR/${name:?}"
  chmod +x "$SB_DIR/sing-box"
}

install_singbox() {
  mkdir -p "$SB_DIR"
  if [[ -x "$SB_DIR/sing-box" ]]; then
    echo "[信息] sing-box 已安装：$("$SB_DIR/sing-box" version 2>/dev/null | awk '/version/{print $NF}')"
    return 0
  fi
  echo "[信息] 获取 sing-box 最新版本…"
  local ver=""
  ver=$(fetch_latest_version)
  [[ -z "$ver" ]] && { echo "[错误] 获取 sing-box 版本失败，请检查网络"; exit 1; }
  echo "[信息] 最新版本：v$ver，开始下载…"
  download_singbox "$ver" || { echo "[错误] sing-box 下载失败"; exit 1; }
  echo "[信息] sing-box 安装成功：$("$SB_DIR/sing-box" version | awk '/version/{print $NF}')"
}

# 更新 sing-box 内核到最新正式版：先备份旧版；新版过不了现有配置校验时自动回滚
do_update_core() {
  if [[ ! -x "$SB_DIR/sing-box" ]]; then
    echo "[错误] sing-box 尚未安装，无法更新内核"
    return 1
  fi
  local cur="" latest=""
  cur=$("$SB_DIR/sing-box" version 2>/dev/null | awk '/version/{print $NF}')
  echo "[信息] 当前 sing-box 版本：v$cur，获取最新版本…"
  latest=$(fetch_latest_version)
  [[ -z "$latest" ]] && { echo "[错误] 获取 sing-box 最新版本失败，请检查网络"; return 1; }
  if [[ "$cur" == "$latest" ]]; then
    echo "[信息] 已是最新版本 v$cur，无需更新"
    return 0
  fi
  echo "[信息] 发现新版本：v$cur → v$latest，开始更新…"
  cp -f "$SB_DIR/sing-box" "$SB_DIR/sing-box.bak"
  if ! download_singbox "$latest"; then
    mv -f "$SB_DIR/sing-box.bak" "$SB_DIR/sing-box"
    echo "[错误] 新版下载失败，已恢复旧版 v$cur"
    return 1
  fi
  if [[ -f "$SB_DIR/sb.json" ]] && ! "$SB_DIR/sing-box" check -c "$SB_DIR/sb.json" >/dev/null 2>&1; then
    mv -f "$SB_DIR/sing-box.bak" "$SB_DIR/sing-box"
    setup_service
    echo "[错误] 新版 sing-box 与现有配置不兼容，已回滚到 v$cur 并重启服务"
    return 1
  fi
  setup_service
  echo "[完成] sing-box 内核已更新：v$cur → v$latest（旧版备份在 $SB_DIR/sing-box.bak，如需可手动恢复）"
}

#----------------------------- 4.1 快捷命令 ----------------------------------
# 把本脚本安装为 sbox 系统命令：sudo sbox 进菜单，sudo sbox <动作> 直达操作
# 从 GitHub 拉取最新脚本（带防缓存 + 备用源），成功返回 0
fetch_latest_script() {
  local dest="$1"
  local ts url
  ts=$(date +%s)
  # 优先跟随最新 Release（tag），避免 main 上未发布的改动直接打到已安装机器；取不到 tag 再回退 main
  local tag=""
  tag=$(curl -fsSL --max-time 15 https://api.github.com/repos/lnant/sing-box-auto/releases/latest 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null || true)
  local urls=()
  if [[ -n "$tag" ]]; then
    urls+=(
      "https://raw.githubusercontent.com/lnant/sing-box-auto/${tag}/sing-box-auto.sh?t=${ts}"
      "https://cdn.jsdelivr.net/gh/lnant/sing-box-auto@${tag}/sing-box-auto.sh"
    )
  fi
  urls+=(
    "https://raw.githubusercontent.com/lnant/sing-box-auto/main/sing-box-auto.sh?t=${ts}"
    "https://cdn.jsdelivr.net/gh/lnant/sing-box-auto@main/sing-box-auto.sh"
  )
  for url in "${urls[@]}"; do
    if curl -fsSL --max-time 60 --retry 2 "$url" -o "$dest" \
       && grep -q "sing-box 全自动一键安装脚本" "$dest" \
       && bash -n "$dest"; then
      return 0
    fi
    echo "[警告] 从 ${url%%\?*} 获取失败，尝试备用源…"
  done
  return 1
}

setup_shortcut() {
  echo "[信息] 安装 sbox 快捷命令…"
  # 优先把"正在运行的这份脚本自身"装为 sbox：用户跑的是哪个版本，sbox 就是哪个版本，不串版；
  # 管道运行（curl | bash）时拿不到自身文件，再回退到拉取最新正式版（update-script 的职责）
  local self="${BASH_SOURCE[0]:-}"
  if [[ -n "$self" && -f "$self" && "$self" != "/usr/local/bin/sbox" ]] \
     && grep -q "sing-box 全自动一键安装脚本" "$self" 2>/dev/null \
     && cp "$self" /usr/local/bin/sbox 2>/dev/null; then
    chmod +x /usr/local/bin/sbox
    ln -sf /usr/local/bin/sbox /usr/bin/sbox 2>/dev/null || true
    echo "[信息] 快捷命令已安装：直接打 sbox 进管理菜单（自动提权）"
    return 0
  fi
  if fetch_latest_script /usr/local/bin/sbox; then
    chmod +x /usr/local/bin/sbox
    # 部分系统 root 的 PATH（sudo secure_path）不含 /usr/local/bin，加个软链接兜底
    ln -sf /usr/local/bin/sbox /usr/bin/sbox 2>/dev/null || true
    echo "[信息] 快捷命令已安装：直接打 sbox 进管理菜单（自动提权）"
  else
    echo "[警告] sbox 快捷命令安装失败，可手动下载脚本使用"
  fi
}

#----------------------------- 5. 自签证书 -----------------------------------
# 对应同类脚本的证书选项：默认不申请 Acme，直接用自签证书
gen_certs() {
  if [[ -f "$SB_DIR/cert.pem" && -f "$SB_DIR/private.key" ]]; then
    echo "[信息] 自签证书已存在，跳过生成"
    return 0
  fi
  # SAN 带上自签伪装域名与本机公网 IP（IP SAN）：纯 IP 型机器（无域名）
  # 按 IP 直连时，不允许 insecure 的客户端靠它完成 TLS 校验；
  # 拿不到公网 IP 就跳过 IP 项，保持原有行为
  local _san="DNS:$SNI_SELF" _pip
  _pip="$(get_ip)"
  _pip="${_pip#[}"; _pip="${_pip%]}"   # 归一化：裸地址
  if [[ "$_pip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ || "$_pip" == *:* ]]; then
    _san="$_san,IP:$_pip"
  fi
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

#----------------------------- 6. 身份与端口 ----------------------------------
save_env() {
  cat > "$ENV_FILE" <<EOF
UUID="$UUID"
PRIVKEY="$PRIVKEY"
PUBKEY="$PUBKEY"
SHORTID="$SHORTID"
PORT_VLESS="$PORT_VLESS"
PORT_VMESS="$PORT_VMESS"
PORT_HY2="$PORT_HY2"
PORT_TUIC="$PORT_TUIC"
PORT_ANYTLS="$PORT_ANYTLS"
EOF
  chmod 600 "$ENV_FILE"
}

# 三级取值：①本脚本上次运行的 env → ②同类脚本残留配置 → ③全新生成
load_or_gen_identity() {
  if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    # 兼容精简版写下的 env：缺失的协议端口随机分配
    local used=" ${PORT_VLESS:-} ${PORT_VMESS:-} ${PORT_HY2:-} ${PORT_TUIC:-} ${PORT_ANYTLS:-} "
    # 缺哪个补哪个：逐个显式分配并校验结果，不用链式 &&——链式写法在 rand_port 失败时会
    # 留下空端口继续往下跑，直到写配置时才以误导性报错失败
    local _pv _p
    for _pv in PORT_VLESS PORT_VMESS PORT_HY2 PORT_TUIC PORT_ANYTLS; do
      if [[ -z "${!_pv:-}" ]]; then
        _p=$(rand_port "$used") || { echo "[错误] 端口分配失败，无法继续"; exit 1; }
        printf -v "$_pv" '%s' "$_p"
        used+=" $_p "
      fi
    done
    if [[ -n "${UUID:-}" && -n "${PRIVKEY:-}" && -n "${PUBKEY:-}" && -n "${SHORTID:-}" ]]; then
      echo "[信息] 检测到已有配置，UUID/端口/密钥保持不变（幂等重跑）"
      save_env
      return 0
    fi
    echo "[警告] 已有配置不完整，将重新生成身份信息"
  fi
  if [[ -f "$SB_DIR/sb.json" ]]; then
    local old_uuid=""
    old_uuid=$(jq -r '.inbounds[0].users[0].uuid // empty' "$SB_DIR/sb.json" 2>/dev/null || true)
    if [[ -n "$old_uuid" ]]; then
      UUID="$old_uuid"
      PORT_VLESS=$(jq -r '.inbounds[0].listen_port // empty' "$SB_DIR/sb.json" 2>/dev/null || true)
      PORT_VMESS=$(jq -r '.inbounds[1].listen_port // empty' "$SB_DIR/sb.json" 2>/dev/null || true)
      PORT_HY2=$(jq -r '.inbounds[2].listen_port // empty' "$SB_DIR/sb.json" 2>/dev/null || true)
      PORT_TUIC=$(jq -r '.inbounds[3].listen_port // empty' "$SB_DIR/sb.json" 2>/dev/null || true)
      PORT_ANYTLS=$(jq -r '.inbounds[4].listen_port // empty' "$SB_DIR/sb.json" 2>/dev/null || true)
      # 导入值逐个校验：残缺配置（inbound 不足 5 个）会读出空/null/非数字，坏端口直接随机补齐，
      # 避免把坏值写进新配置、最后在 sing-box check 处以误导性报错失败
      local _used=" " _pv _v _p
      for _pv in PORT_VLESS PORT_VMESS PORT_HY2 PORT_TUIC PORT_ANYTLS; do
        _v="${!_pv:-}"
        if [[ "$_v" =~ ^[0-9]+$ ]] && (( _v >= 1 && _v <= 65535 )) && [[ "$_used" != *" $_v "* ]]; then
          _used+=" $_v "
        else
          _p=$(rand_port "$_used") || { echo "[错误] 端口分配失败，无法继续"; exit 1; }
          printf -v "$_pv" '%s' "$_p"
          _used+=" $_p "
        fi
      done
      PRIVKEY=$(jq -r '.inbounds[0].tls.reality.private_key // empty' "$SB_DIR/sb.json" 2>/dev/null || true)
      SHORTID=$(jq -r '.inbounds[0].tls.reality.short_id[0] // empty' "$SB_DIR/sb.json" 2>/dev/null || true)
      PUBKEY="$(cat "$SB_DIR/public.key" 2>/dev/null || true)"
      if [[ -n "$PRIVKEY" && -n "$PUBKEY" && -n "$SHORTID" ]]; then
        echo "[信息] 从同类脚本残留配置导入 UUID/端口/密钥，客户端链接保持不变"
        save_env
        return 0
      fi
    fi
  fi
  echo "[信息] 生成 UUID 与 Reality 密钥对…"
  # uuid 生成：优先用 sing-box generate uuid，失败则用系统 uuid
  if "$SB_DIR/sing-box" generate uuid >/dev/null 2>&1; then
    UUID=$("$SB_DIR/sing-box" generate uuid)
  else
    UUID=$(cat /proc/sys/kernel/random/uuid)
  fi
  local kp
  kp=$("$SB_DIR/sing-box" generate reality-keypair)
  PRIVKEY=$(echo "$kp" | awk '/PrivateKey/{print $2}' | tr -d '"')
  PUBKEY=$(echo "$kp" | awk '/PublicKey/{print $2}' | tr -d '"')
  echo "$PUBKEY" > "$SB_DIR/public.key"
  SHORTID=$("$SB_DIR/sing-box" generate rand --hex 4)
  if [[ -z "$PRIVKEY" || -z "$PUBKEY" || -z "$SHORTID" ]]; then
    echo "[错误] Reality 密钥生成失败"; exit 1
  fi
  local used=" "
  PORT_VLESS=$(rand_port "$used"); used+=" $PORT_VLESS "
  PORT_VMESS=$(rand_port "$used"); used+=" $PORT_VMESS "
  PORT_HY2=$(rand_port "$used"); used+=" $PORT_HY2 "
  PORT_TUIC=$(rand_port "$used"); used+=" $PORT_TUIC "
  PORT_ANYTLS=$(rand_port "$used"); used+=" $PORT_ANYTLS "
  echo "[信息] 端口分配：VLESS=$PORT_VLESS VMess-WS=$PORT_VMESS Hy2=$PORT_HY2 TUIC=$PORT_TUIC AnyTLS=$PORT_ANYTLS"
  save_env
}

#----------------------------- 7. 写 sing-box 配置 ---------------------------
# 受限网络环境自适应（OpenVZ/venet 容器）：
# 背景（2026-11-06 于 OpenVZ 免费机实测）：这类容器默认路由无网关、网卡是 venet，
# sing-box 内置 DNS 要靠枚举网卡/路由选默认接口，而容器禁止枚举（日志原文
# "list routes: address family not supported by protocol"），于是出站解析全灭、
# 全部直连链与 ACME 一起死；同机的系统解析（/etc/resolv.conf）却一切正常。
# 对策：三项指纹同时成立才判「受限」，write_config 给配置顶层加两段——
# dns 走普通 UDP 指向系统解析（注意：sing-box 的 dns type "local" 仍走其自家
# 拨号层、实测无效，必须普通 udp）；route 关闭接口自动探测并写死默认网卡。
# 判假时不写这两段，生成的配置与改前逐字节一致（正常机器零影响）。
# 检测宁可漏报不可误报：用到的命令缺失（systemd-detect-virt / ip）一律判假。

# 默认路由的 dev 名（如 venet0 / eth0）；取不到输出空
restricted_net_dev() {
  command -v ip >/dev/null 2>&1 || return 0
  ip route show default 2>/dev/null | head -n 1 \
    | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}'
}

# 系统解析地址：/etc/resolv.conf 第一个 nameserver；读不到回退回环 stub 口
restricted_net_nameserver() {
  local _ns=""
  if [[ -r /etc/resolv.conf ]]; then
    _ns=$(awk '$1=="nameserver" {print $2; exit}' /etc/resolv.conf 2>/dev/null || true)
  fi
  [[ -n "$_ns" ]] || _ns="127.0.0.53"
  printf '%s\n' "$_ns"
}

# 三项指纹同时成立才返回 0：①OpenVZ ②默认路由 dev 以 venet 开头 ③默认路由无网关
restricted_net_env() {
  # ① OpenVZ：systemd-detect-virt 最直接；它缺失或判不出时退查
  #    /proc/user_beancounters——OpenVZ/Virtuozzo 容器有此文件、普通机器没有
  local _ovz=0
  if command -v systemd-detect-virt >/dev/null 2>&1 \
     && [[ "$(systemd-detect-virt 2>/dev/null || true)" == "openvz" ]]; then
    _ovz=1
  fi
  if [[ -e /proc/user_beancounters ]]; then _ovz=1; fi
  (( _ovz == 1 )) || return 1
  command -v ip >/dev/null 2>&1 || return 1
  # ② 网卡：默认路由 dev 名以 venet 开头（venet0 等）
  local _dev
  _dev=$(restricted_net_dev)
  [[ "$_dev" == venet* ]] || return 1
  # ③ 无网关：受限环境的默认路由形如 "default dev venet0 scope link"（无 via 段）；
  #    IPv6 默认路由同机同形，可作旁证，这里以 IPv4 行为准即可（venet 机器必有此行）
  local _def
  _def=$(ip route show default 2>/dev/null | head -n 1)
  [[ -n "$_def" && "$_def" != *" via "* ]] || return 1
  return 0
}

# 受限时 write_config 追加的 JSON 尾段（顶层 dns + route）；非受限输出空。
# $1 可选：调用方既有的 route 内字段（如 WARP 的 rules/final），非空时并入
# 同一个 route 对象，避免顶层出现两个 "route" 键；default_interface 取不到时
# 只写 auto_detect_interface。
restricted_net_tail() {
  restricted_net_env || return 0
  local _ns _dev _route="\"auto_detect_interface\": false"
  _ns=$(restricted_net_nameserver)
  _dev=$(restricted_net_dev)
  if [[ -n "$_dev" ]]; then _route="$_route, \"default_interface\": \"$_dev\""; fi
  if [[ -n "${1:-}" ]]; then _route="$_route, $1"; fi
  printf ',\n  "dns": {"servers": [{"type": "udp", "server": "%s", "tag": "sys"}], "final": "sys"},\n  "route": {%s}' "$_ns" "$_route"
}

write_config() {
  echo "[信息] 写入 sing-box 配置…"
  # 受限网络环境自适应（见上方 restricted_net_tail 注释）：判假时 _net_tail 为空，
  # 产物与改前逐字节一致
  local _net_tail
  _net_tail=$(restricted_net_tail)
  cat > "$SB_DIR/sb.json" <<EOF
{
  "log": {"level": "info", "timestamp": true},
  "inbounds": [
    {
      "type": "vless", "tag": "vless-reality",
      "listen": "::", "listen_port": $PORT_VLESS,
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
      "type": "vmess", "tag": "vmess-ws",
      "listen": "::", "listen_port": $PORT_VMESS,
      "users": [{"uuid": "$UUID", "alterId": 0}],
      "transport": {
        "type": "ws", "path": "${UUID}-vm",
        "max_early_data": 2048, "early_data_header_name": "Sec-WebSocket-Protocol"
      },
      "tls": {"enabled": false}
    },
    {
      "type": "hysteria2", "tag": "hysteria2",
      "listen": "::", "listen_port": $PORT_HY2,
      "users": [{"password": "$UUID"}],
      "ignore_client_bandwidth": false,
      "tls": {
        "enabled": true, "alpn": ["h3"],
        "certificate_path": "$SB_DIR/cert.pem",
        "key_path": "$SB_DIR/private.key"
      }
    },
    {
      "type": "tuic", "tag": "tuic",
      "listen": "::", "listen_port": $PORT_TUIC,
      "users": [{"uuid": "$UUID", "password": "$UUID"}],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true, "alpn": ["h3"],
        "certificate_path": "$SB_DIR/cert.pem",
        "key_path": "$SB_DIR/private.key"
      }
    },
    {
      "type": "anytls", "tag": "anytls",
      "listen": "::", "listen_port": $PORT_ANYTLS,
      "users": [{"password": "$UUID"}],
      "padding_scheme": [],
      "tls": {
        "enabled": true,
        "certificate_path": "$SB_DIR/cert.pem",
        "key_path": "$SB_DIR/private.key"
      }
    }
  ],
  "outbounds": [{"type": "direct", "tag": "direct"}]${_net_tail}
}
EOF
  "$SB_DIR/sing-box" check -c "$SB_DIR/sb.json" >/dev/null 2>&1 \
    || { echo "[错误] 配置校验失败"; exit 1; }
  echo "[信息] 配置校验通过"
}

#----------------------------- 7.5 cron 守护 -----------------------------------
# Argo 隧道与无 systemd 时的 sing-box 自启都依赖 crontab 的 @reboot 条目，
# 但装好 crontab 命令不等于 cron 守护在运行（RHEL 系装完 cronie 默认不启用），这里统一保证
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

#----------------------------- 时间同步 ---------------------------------------
# Reality 握手对时钟偏移敏感，机器时钟慢慢漂移会让节点莫名其妙连不上；长期运行必须保证 NTP 开着
ensure_time_sync() {
  if command -v timedatectl >/dev/null 2>&1; then
    timedatectl set-ntp true >/dev/null 2>&1 || true
    echo "[信息] 已确保 NTP 时间同步开启"
  fi
}

#----------------------------- 8. 系统服务 ------------------------------------
# SELinux：Enforcing 会拦截 sing-box 的出站连接（avc denied name_connect），切为 permissive
fix_selinux() {
  if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce 2>/dev/null)" == "Enforcing" ]]; then
    echo "[信息] 检测到 SELinux 为 Enforcing，切换为 Permissive（否则代理出站会被拦截）…"
    setenforce 0 2>/dev/null || true
    [[ -f /etc/selinux/config ]] && sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
    echo "[信息] SELinux 已切换为 Permissive（重启后依然有效）"
  fi
}

setup_service() {
  echo "[信息] 配置并启动 sing-box 服务…"
  if [[ -d /run/systemd/system ]] || pidof systemd >/dev/null 2>&1; then
    # 服务名处理：旧版用通名 sing-box.service。若是本脚本装的（ExecStart 指向 $SB_DIR）则迁移到专属名 $UNIT；
    # 若是别人装的 sing-box 则不碰它，只警告，本脚本用专属名与其共存
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
Description=sing-box service
After=network.target nss-lookup.target

[Service]
User=root
WorkingDirectory=/root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=$SB_DIR/sing-box run -c $SB_DIR/sb.json
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$UNIT" >/dev/null 2>&1 || true
    systemctl restart "$UNIT" || true   # 失败先不退出：走到下方 is-active 检查并打印日志诊断
    sleep 2
    if systemctl is-active --quiet "$UNIT"; then
      echo "[信息] sing-box 运行中"
    else
      echo "[错误] sing-box 启动失败，日志如下："
      journalctl -u "$UNIT" --no-pager -n 20 2>/dev/null || true
      exit 1
    fi
  else
    echo "[警告] 未检测到 systemd，改用后台方式启动"
    pkill -f "$SB_DIR/sing-box run" >/dev/null 2>&1 || true
    nohup "$SB_DIR/sing-box" run -c "$SB_DIR/sb.json" >/var/log/sing-box.log 2>&1 &
    sleep 2
    pgrep -f "$SB_DIR/sing-box run" >/dev/null || { echo "[错误] sing-box 启动失败"; exit 1; }
    if command -v crontab >/dev/null 2>&1; then
      (crontab -l 2>/dev/null | grep -v "sing-box run"; echo "@reboot sleep 10 && $SB_DIR/sing-box run -c $SB_DIR/sb.json >/var/log/sing-box.log 2>&1") | crontab - >/dev/null 2>&1 || true
    fi
    # 后台方式的日志直接写文件、无人轮转会随年月涨满磁盘，给它配上 logrotate
    if [[ -d /etc/logrotate.d ]]; then
      cat > /etc/logrotate.d/sing-box-fallback <<'ROT'
/var/log/sing-box.log {
    weekly
    rotate 4
    size 5M
    copytruncate
    missingok
    notifempty
}
ROT
    fi
    echo "[信息] sing-box 已在后台启动"
  fi
}

#----------------------------- 9. Argo 临时隧道 -------------------------------
# cloudflared 临时隧道无需 Cloudflare 账号授权；
# 固定隧道需要手动在 CF 官网创建并填 token，无法自动化，本脚本只做临时隧道。
# 隧道失败不阻塞：拿不到域名就跳过，只是不输出第 3 条链接。
# 有 systemd 时把 cloudflared 交给 systemd 托管（崩溃自动拉起 + 开机自启），成功返回 0；
# 无 systemd 时返回 1，调用方回退到 nohup + crontab 老路径（进程死了只能等重启，是临时方案）

# 从 cloudflared 日志里提取当前临时隧道域名。取第二个匹配：第一个是日志里
# api.trycloudflare.com 的提示链接，第二个才是本隧道的域名。解析逻辑集中在一处，
# cloudflared 改日志版式时只修这里（此前同一段 grep 在 5 处各复制一份）
current_argo_domain() {
  grep -a -o 'https://[^ "]*trycloudflare.com' "$SB_DIR/argo.log" 2>/dev/null | head -n 2 | tail -n 1 | sed 's|https://||' || true
}

start_argo_systemd() {
  local exec_cmd="$1"
  if [[ -d /run/systemd/system ]] || pidof systemd >/dev/null 2>&1; then
    cat > "/etc/systemd/system/${ARGO_UNIT}.service" <<EOF
[Unit]
Description=cloudflared Argo tunnel (sing-box-auto)
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
      (crontab -l 2>/dev/null | grep -v "cloudflared.*tunnel") | crontab - >/dev/null 2>&1 || true
    fi
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable "$ARGO_UNIT" >/dev/null 2>&1 || true
    systemctl restart "$ARGO_UNIT" >/dev/null 2>&1 || true
    return 0
  fi
  return 1
}

start_argo() {
  # 如果配置了固定隧道，优先使用固定隧道
  if [[ -f "$SB_DIR/argo.env" ]]; then
    local _am
    _am=$(grep '^ARGO_MODE=' "$SB_DIR/argo.env" 2>/dev/null | cut -d'"' -f2)
    if [[ "$_am" == "fixed" ]]; then
      # shellcheck disable=SC1090
      . "$SB_DIR/argo.env"
      start_argo_fixed
      return 0
    fi
  fi
  echo "[信息] 启动 Argo 临时隧道…"
  local cf="$SB_DIR/cloudflared"
  if [[ ! -x "$cf" ]]; then
    echo "[信息] 下载 cloudflared…"
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
      echo "[警告] cloudflared 下载失败，跳过 Argo（不影响其他 5 种协议）"
      ARGO_DOMAIN=""
      return 0
    fi
    chmod +x "$cf"
  fi
  systemctl stop "$ARGO_UNIT" >/dev/null 2>&1 || true   # 若之前由 systemd 托管，先停掉避免双开
  pkill -f "cloudflared.*tunnel.*--url" >/dev/null 2>&1 || true
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
      (crontab -l 2>/dev/null | grep -v "cloudflared.*tunnel"
       echo "@reboot sleep 15 && $cf tunnel --url http://localhost:${PORT_VMESS} --edge-ip-version auto --no-autoupdate --protocol http2 > $SB_DIR/argo.log 2>&1 &") | crontab - >/dev/null 2>&1 || true
    fi
  else
    echo "[警告] 未能获取 Argo 域名，跳过 VMess+Argo（不影响其他 5 种协议）"
    echo "[提示] 隧道日志最后几行："
    tail -n 5 "$SB_DIR/argo.log" 2>/dev/null || true
    ARGO_DOMAIN=""
  fi
}

#----------------------------- 10. 输出客户端链接 ----------------------------
get_ip() {
  # 多个公网 IP 查询源依次尝试，返回内容必须是合法 IP 才采用；v4 优先，其次 v6
  # 全部失败时输出空字符串，由 print_links 给出明确警告（不再静默生成坏链接）
  local src ip=""
  for src in "https://icanhazip.com" "https://ip.sb" "https://ifconfig.me/ip" "https://api.ipify.org"; do
    ip=$(curl -fsSL --max-time 8 -4 "$src" 2>/dev/null | tr -d '[:space:]' || true)
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then echo "$ip"; return 0; fi
  done
  for src in "https://icanhazip.com" "https://ip.sb" "https://ifconfig.me/ip"; do
    ip=$(curl -fsSL --max-time 8 -6 "$src" 2>/dev/null | tr -d '[:space:]' || true)
    if [[ "$ip" == *:* && "$ip" =~ ^[0-9a-fA-F:]+$ ]]; then echo "[$ip]"; return 0; fi   # IPv6 加方括号
  done
  echo ""
}

# base64 不换行（兼容 busybox）
b64() { base64 -w 0 2>/dev/null || base64 | tr -d '\n'; }

print_links() {
  local ip host ip_bare
  ip="$(get_ip)"
  ip_bare="${ip#[}"; ip_bare="${ip_bare%]}"   # 裸地址：仅 VMess 的 add 字段用（base64-JSON 不是 URI，不带方括号）
  host="$(hostname)"

  local vl_link vm_link hy2_link tuic_link an_link
  vl_link="vless://${UUID}@${ip}:${PORT_VLESS}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI_REALITY}&fp=chrome&pbk=${PUBKEY}&sid=${SHORTID}&type=tcp&headerType=none#vl-reality-${host}"

  vm_link="vmess://$(printf '{"add":"%s","aid":"0","host":"%s","id":"%s","net":"ws","path":"%s-vm","port":"%s","ps":"vm-ws-%s","tls":"","type":"none","v":"2"}' \
    "$ip_bare" "$SNI_SELF" "$UUID" "$UUID" "$PORT_VMESS" "$host" | b64)"

  hy2_link="hysteria2://${UUID}@${ip}:${PORT_HY2}?security=tls&alpn=h3&insecure=1&allowInsecure=1&sni=${SNI_SELF}#hy2-${host}"

  tuic_link="tuic://${UUID}:${UUID}@${ip}:${PORT_TUIC}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=${SNI_SELF}&insecure=1&allowInsecure=1&allow_insecure=1#tu5-${host}"

  an_link="anytls://${UUID}@${ip}:${PORT_ANYTLS}?&sni=${SNI_SELF}&allowInsecure=1&insecure=1#anytls-${host}"

  {
    echo "================ sing-box 节点链接 ================"
    echo "生成时间：$(date '+%Y-%m-%d %H:%M:%S')"
    echo
    if [[ -z "$ip" ]]; then
      echo "[警告] 未能获取公网 IP（多个查询源均失败）：下方直连链接的服务器地址为空，"
      echo "       使用前请把链接中的 @: 替换为 @服务器IP:（VMess 的 add 字段同理），或稍后重跑 show-links"
      echo
    fi
    echo "[1] VLESS + Reality (TCP/${PORT_VLESS})"
    echo "$vl_link"
    echo
    echo "[2] VMess + WS (TCP/${PORT_VMESS})"
    echo "$vm_link"
    echo
    if [[ -n "${ARGO_DOMAIN:-}" ]]; then
      local argo_link
      argo_link="vmess://$(printf '{"add":"cloudflare-ech.com","aid":"0","host":"%s","id":"%s","net":"ws","path":"%s-vm","port":"443","ps":"vm-argo-%s","tls":"tls","sni":"%s","fp":"chrome","type":"none","v":"2"}' \
        "$ARGO_DOMAIN" "$UUID" "$UUID" "$host" "$ARGO_DOMAIN" | b64)"
      echo "[3] VMess + Argo 隧道（${ARGO_DOMAIN}，重启后会变）"
      echo "$argo_link"
    else
      echo "[3] VMess + Argo：本次未能建立隧道，已跳过"
    fi
    echo
    echo "[4] Hysteria2 (UDP/${PORT_HY2})"
    echo "$hy2_link"
    echo
    echo "[5] TUIC v5 (UDP/${PORT_TUIC})"
    echo "$tuic_link"
    echo
    echo "[6] AnyTLS (TCP/${PORT_ANYTLS})"
    echo "$an_link"
    echo
    echo "==================================================="
    echo "提示：链接已保存到 $LINKS_FILE"
  } | tee "$LINKS_FILE"
  chmod 600 "$LINKS_FILE"
}

#----------------------------- 11. 卸载 --------------------------------------
do_uninstall() {
  echo "[信息] 卸载 sing-box…"
  systemctl stop "$UNIT" >/dev/null 2>&1 || true
  systemctl disable "$UNIT" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${UNIT}.service"
  systemctl stop "$ARGO_UNIT" >/dev/null 2>&1 || true
  systemctl disable "$ARGO_UNIT" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${ARGO_UNIT}.service"
  # 旧版通名服务：确认是本脚本装的（指向 $SB_DIR）才一并清理，别人的 sing-box 不碰
  if [[ -f /etc/systemd/system/sing-box.service ]] && grep -q "$SB_DIR/sing-box" /etc/systemd/system/sing-box.service; then
    systemctl stop sing-box >/dev/null 2>&1 || true
    systemctl disable sing-box >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/sing-box.service
  fi
  systemctl daemon-reload >/dev/null 2>&1 || true
  pkill -f "$SB_DIR/sing-box run" >/dev/null 2>&1 || true
  pkill -f "cloudflared.*tunnel" >/dev/null 2>&1 || true
  if command -v crontab >/dev/null 2>&1; then
    # 注意：固定隧道和临时隧道的 crontab 格式不同，用宽匹配一起清掉
    (crontab -l 2>/dev/null | grep -v "sing-box run" | grep -v "cloudflared.*tunnel") | crontab - >/dev/null 2>&1 || true
  fi
  rm -rf "$SB_DIR" "$LINKS_FILE"
  rm -f /etc/logrotate.d/sing-box-fallback
  rm -f /usr/local/bin/sbox /usr/bin/sbox
  echo "[信息] 卸载完成"
}

#----------------------------- 12. 管理菜单 ------------------------------------
# 加载已保存的配置，不存在则报错退出
load_env_or_exit() {
  if [[ ! -f "$ENV_FILE" ]]; then
    echo "[错误] 未找到配置文件 $ENV_FILE，请先运行安装"
    exit 1
  fi
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  if [[ -f "$SB_DIR/argo.env" ]]; then
    # shellcheck disable=SC1090
    . "$SB_DIR/argo.env"
  fi
  if [[ -z "${ARGO_DOMAIN:-}" && "${ARGO_MODE:-}" != "fixed" ]]; then
    ARGO_DOMAIN="$(current_argo_domain)"
  fi
}

# 3. 更换 UUID（全协议）
do_change_uuid() {
  load_env_or_exit
  echo "[信息] 正在生成新 UUID…"
  if "$SB_DIR/sing-box" generate uuid >/dev/null 2>&1; then
    UUID=$("$SB_DIR/sing-box" generate uuid)
  else
    UUID=$(cat /proc/sys/kernel/random/uuid)
  fi
  echo "[信息] 新 UUID：$UUID"
  save_env
  write_config
  setup_service
  start_argo
  print_links
  echo
  echo "[完成] UUID 已更换，全协议链接已更新"
}

# 5. 更新 Reality 密钥对
do_change_reality() {
  load_env_or_exit
  echo "[信息] 正在生成新 Reality 密钥对…"
  local kp
  kp=$("$SB_DIR/sing-box" generate reality-keypair)
  PRIVKEY=$(echo "$kp" | awk '/PrivateKey/{print $2}' | tr -d '"')
  PUBKEY=$(echo "$kp" | awk '/PublicKey/{print $2}' | tr -d '"')
  echo "$PUBKEY" > "$SB_DIR/public.key"
  SHORTID=$("$SB_DIR/sing-box" generate rand --hex 4)
  if [[ -z "$PRIVKEY" || -z "$PUBKEY" || -z "$SHORTID" ]]; then
    echo "[错误] Reality 密钥生成失败"; exit 1
  fi
  save_env
  write_config
  setup_service
  print_links
  echo
  echo "[完成] Reality 密钥对已更新"
}

# 6. 更新自签证书
do_change_cert() {
  load_env_or_exit
  echo "[信息] 正在重新生成自签证书…"
  rm -f "$SB_DIR/cert.pem" "$SB_DIR/private.key"
  gen_certs
  write_config
  setup_service
  print_links
  echo
  echo "[完成] 自签证书已更新（Hy2/TUIC/AnyTLS/VMess-WS 已切换新证书）"
}

# 启动 Argo 固定隧道
start_argo_fixed() {
  local cf="$SB_DIR/cloudflared"
  if [[ ! -x "$cf" ]]; then
    echo "[错误] cloudflared 未安装，请先运行一次安装"
    return 1
  fi
  if [[ -z "${ARGO_TOKEN:-}" ]]; then
    echo "[错误] 未配置 Argo Token"
    return 1
  fi
  systemctl stop "$ARGO_UNIT" >/dev/null 2>&1 || true   # 先停掉可能在跑的旧托管实例，避免双开
  pkill -f "cloudflared.*tunnel" >/dev/null 2>&1 || true
  sleep 1
  echo "[信息] 固定隧道启动中…"
  if start_argo_systemd "$cf tunnel --no-autoupdate run --token $ARGO_TOKEN"; then
    echo "[信息] 固定隧道已由 systemd 托管（崩溃自动拉起）"
  else
    nohup "$cf" tunnel --no-autoupdate run --token "$ARGO_TOKEN" > "$SB_DIR/argo.log" 2>&1 &
    if command -v crontab >/dev/null 2>&1; then
      (crontab -l 2>/dev/null | grep -v "cloudflared.*tunnel"
       echo "@reboot sleep 15 && $cf tunnel --no-autoupdate run --token $ARGO_TOKEN > $SB_DIR/argo.log 2>&1 &") | crontab - >/dev/null 2>&1 || true
    fi
  fi
  sleep 5
  echo "[信息] 固定隧道域名：${ARGO_DOMAIN:-（未知）}"
}

# Argo 期望状态对齐检查：argo.env 声明的模式/令牌（或临时隧道的 VMess 端口）
# 与现行 Argo 单元 ExecStart（无 systemd 时为 crontab @reboot 行）不一致、
# 或单元/自启行缺失时返回 0（需要重建），一致返回 1。此前 restart 根本不碰
# Argo，外部手改 argo.env 后跑多少次 restart 都不会生效，靠它在重启时发现。
argo_unit_diverged() {
  local _want _cur=""
  if [[ -f "$SB_DIR/argo.env" ]] && grep -q '^ARGO_MODE="fixed"' "$SB_DIR/argo.env"; then
    local _tok
    _tok=$(grep '^ARGO_TOKEN=' "$SB_DIR/argo.env" 2>/dev/null | cut -d'"' -f2 || true)
    _want="tunnel --no-autoupdate run --token $_tok"
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

# 重启（菜单项 2 与 restart 动作共用）：本体重启后对齐 Argo 期望状态。
# 配置无分歧时不扰动在跑的隧道——临时隧道一旦重连就会换域名、已分享的
# 链接随之作废；仅当隧道没在运行时才按现行配置把它拉起来。
do_restart() {
  load_env_or_exit
  setup_service
  if argo_unit_diverged; then
    echo "[信息] 检测到 Argo 配置与运行状态不一致，按 argo.env 重新生成"
    start_argo
  elif [[ -d /run/systemd/system ]] || pidof systemd >/dev/null 2>&1; then
    systemctl is-active --quiet "$ARGO_UNIT" 2>/dev/null || start_argo
  else
    pgrep -f "$SB_DIR/cloudflared.*tunnel" >/dev/null 2>&1 || start_argo
  fi
  echo "[完成] 服务已重启"
}

# 7. Argo 隧道管理子菜单
do_argo_menu() {
  load_env_or_exit
  # 载入 Argo 状态用于显示：固定隧道读 argo.env，临时隧道从日志恢复当前域名
  if [[ -f "$SB_DIR/argo.env" ]]; then
    # shellcheck disable=SC1090
    . "$SB_DIR/argo.env" 2>/dev/null || true
  elif [[ -z "${ARGO_DOMAIN:-}" ]]; then
    ARGO_DOMAIN="$(current_argo_domain)"
  fi
  while true; do
    echo
    echo "---------- Argo 隧道管理 ----------"
    if [[ "${ARGO_MODE:-}" == "fixed" ]]; then
      echo "当前模式：固定隧道（${ARGO_DOMAIN:-未知域名}）"
    else
      echo "当前模式：临时隧道（${ARGO_DOMAIN:-未建立}）"
    fi
    echo "1. 重新抓取隧道域名（隧道在跑但没显示域名时用）"
    echo "2. 重启临时隧道（获取新域名）"
    echo "3. 设置固定隧道（需 Cloudflare Token）"
    echo "4. 切换回临时隧道"
    echo "0. 返回上级"
    read -rp "请选择 [0-4]: " c
    case "$c" in
      2)
        rm -f "$SB_DIR/argo.env"
        unset ARGO_MODE ARGO_TOKEN ARGO_DOMAIN
        start_argo
        print_links
        ;;
      3)
        local token domain
        read -rp "输入 Argo Tunnel Token: " token
        read -rp "输入固定隧道域名: " domain
        if [[ -z "$token" || -z "$domain" ]]; then
          echo "[错误] Token 和域名不能为空"
          continue
        fi
        # 格式白名单校验：argo.env 之后会被 source 加载，含引号/$()/反引号的输入会破坏文件结构甚至被执行
        if [[ ! "$token" =~ ^[A-Za-z0-9+/=_-]+$ ]]; then
          echo "[错误] Token 格式不对（应为 Cloudflare 签发的长字符串，只含字母、数字与 +/=_- 等符号）"
          continue
        fi
        if [[ ! "$domain" =~ ^[A-Za-z0-9.-]+$ || "$domain" != *.* || "$domain" == .* || "$domain" == *. ]]; then
          echo "[错误] 域名格式不对（示例：tun.example.com）"
          continue
        fi
        cat > "$SB_DIR/argo.env" <<EOF
ARGO_MODE="fixed"
ARGO_TOKEN="$token"
ARGO_DOMAIN="$domain"
EOF
        chmod 600 "$SB_DIR/argo.env"
        # shellcheck disable=SC1090
        . "$SB_DIR/argo.env"
        start_argo_fixed
        print_links
        echo
        echo "[完成] 已切换到固定隧道：$domain"
        ;;
      4)
        rm -f "$SB_DIR/argo.env"
        unset ARGO_MODE ARGO_TOKEN ARGO_DOMAIN
        start_argo
        print_links
        ;;
      1)
        ARGO_DOMAIN="$(current_argo_domain)"
        if [[ -n "$ARGO_DOMAIN" ]]; then
          echo "[信息] 抓到域名：$ARGO_DOMAIN"
          print_links
        else
          echo "[警告] 日志里还没有域名，隧道可能仍在启动中，稍后再试"
          tail -n 5 "$SB_DIR/argo.log" 2>/dev/null || true
        fi
        ;;
      0) break ;;
      *) echo "[错误] 无效选择" ;;
    esac
  done
}

# 4. 更换端口
do_change_ports() {
  load_env_or_exit
  echo "当前端口：VLESS=$PORT_VLESS VMess-WS=$PORT_VMESS Hy2=$PORT_HY2 TUIC=$PORT_TUIC AnyTLS=$PORT_ANYTLS"
  echo "输入新端口（直接回车保持不变）："
  local p
  local n_vless="$PORT_VLESS" n_vmess="$PORT_VMESS" n_hy2="$PORT_HY2" n_tuic="$PORT_TUIC" n_anytls="$PORT_ANYTLS"
  read -rp "VLESS [$PORT_VLESS]: " p; [[ -n "$p" ]] && n_vless="$p"
  read -rp "VMess-WS [$PORT_VMESS]: " p; [[ -n "$p" ]] && n_vmess="$p"
  read -rp "Hysteria2 [$PORT_HY2]: " p; [[ -n "$p" ]] && n_hy2="$p"
  read -rp "TUIC [$PORT_TUIC]: " p; [[ -n "$p" ]] && n_tuic="$p"
  read -rp "AnyTLS [$PORT_ANYTLS]: " p; [[ -n "$p" ]] && n_anytls="$p"
  # ---- 写入前校验：全部通过才动 env/配置，坏输入不留半成品 ----
  local names=("VLESS" "VMess-WS" "Hysteria2" "TUIC" "AnyTLS")
  local news=("$n_vless" "$n_vmess" "$n_hy2" "$n_tuic" "$n_anytls")
  local olds=" $PORT_VLESS $PORT_VMESS $PORT_HY2 $PORT_TUIC $PORT_ANYTLS "
  local i j v
  for i in 0 1 2 3 4; do
    v="${news[$i]}"
    if ! [[ "$v" =~ ^[0-9]+$ ]] || (( 10#$v < 1 || 10#$v > 65535 )); then
      echo "[错误] ${names[$i]} 端口不合法：'$v'（须为 1-65535 的数字），未做任何修改"
      return 0
    fi
    news[$i]=$((10#$v))
  done
  for i in 0 1 2 3 4; do
    for j in 0 1 2 3 4; do
      if (( i < j )) && [[ "${news[$i]}" == "${news[$j]}" ]]; then
        echo "[错误] ${names[$i]} 与 ${names[$j]} 端口重复：${news[$i]}，未做任何修改"
        return 0
      fi
    done
  done
  for i in 0 1 2 3 4; do
    v="${news[$i]}"
    # 本服务现有的端口在重启时会被释放，不算占用；其余端口被占则拒绝
    if [[ "$olds" != *" $v "* ]] && port_in_use "$v"; then
      echo "[错误] ${names[$i]} 端口 $v 已被其他程序占用，未做任何修改"
      return 0
    fi
  done
  # ---- 备份现状；写完配置用 sing-box 自检，不过则回滚 ----
  cp -f "$ENV_FILE" "$ENV_FILE.bak" 2>/dev/null || true
  [[ -f "$SB_DIR/sb.json" ]] && cp -f "$SB_DIR/sb.json" "$SB_DIR/sb.json.bak" || true
  PORT_VLESS="${news[0]}"; PORT_VMESS="${news[1]}"; PORT_HY2="${news[2]}"; PORT_TUIC="${news[3]}"; PORT_ANYTLS="${news[4]}"
  save_env
  write_config
  if [[ -x "$SB_DIR/sing-box" ]] && ! "$SB_DIR/sing-box" check -c "$SB_DIR/sb.json" >/dev/null 2>&1; then
    echo "[错误] 新配置未通过 sing-box 自检，已回滚到原端口配置"
    cp -f "$ENV_FILE.bak" "$ENV_FILE" 2>/dev/null || true
    [[ -f "$SB_DIR/sb.json.bak" ]] && cp -f "$SB_DIR/sb.json.bak" "$SB_DIR/sb.json" || true
    rm -f "$ENV_FILE.bak" "$SB_DIR/sb.json.bak"
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    return 0
  fi
  rm -f "$ENV_FILE.bak" "$SB_DIR/sb.json.bak"
  open_firewall
  setup_service
  start_argo
  print_links
  echo
  echo "[完成] 端口已更新"
}

# 9. 更新脚本到最新版（从 GitHub 拉取）
do_update_script() {
  echo "[信息] 正在从 GitHub 拉取最新脚本…"
  local tmpfile
  tmpfile=$(mktemp)
  if fetch_latest_script "$tmpfile"; then
    local newver=""
    newver=$(grep -m1 '^SCRIPT_VERSION=' "$tmpfile" | cut -d'"' -f2 || true)
    cp -f "$tmpfile" /usr/local/bin/sbox
    chmod +x /usr/local/bin/sbox
    rm -f "$tmpfile"
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

# 主管理菜单
# 检查端口是否在监听：$1=tcp|udp  $2=端口
port_listening() {
  case "$1" in
    tcp) command -v ss >/dev/null 2>&1 && ss -tln 2>/dev/null | grep -qE "[:.]$2[[:space:]]" ;;
    udp) command -v ss >/dev/null 2>&1 && ss -uln 2>/dev/null | grep -qE "[:.]$2[[:space:]]" ;;
    *) return 1 ;;
  esac
}

# 菜单端口状态
show_port_status() {
  local _d argo_st="未开启"
  if [[ -f "$SB_DIR/argo.env" ]] && grep -q '^ARGO_MODE="fixed"' "$SB_DIR/argo.env" 2>/dev/null; then
    argo_st="固定隧道：$(grep '^ARGO_DOMAIN=' "$SB_DIR/argo.env" 2>/dev/null | cut -d'"' -f2)"
  else
    _d="$(current_argo_domain)"
    [[ -n "$_d" ]] && argo_st="临时隧道：$_d"
  fi
  echo "Sing-box节点端口状态如下："
  local item name proto port st
  for item in \
    "Vless-reality|tcp|$PORT_VLESS" \
    "Vmess-ws|tcp|$PORT_VMESS" \
    "Hysteria-2|udp|$PORT_HY2" \
    "Tuic-v5|udp|$PORT_TUIC" \
    "Anytls|tcp|$PORT_ANYTLS"; do
    name="${item%%|*}"; proto="${item#*|}"; proto="${proto%%|*}"; port="${item##*|}"
    if port_listening "$proto" "$port"; then st="监听中"; else st="未监听"; fi
    if [[ "$name" == "Vmess-ws" ]]; then
      printf '🚀【 %-13s 】端口:%-5s  状态:%s  Argo:%s\n' "$name" "$port" "$st" "$argo_st"
    else
      printf '🚀【 %-13s 】端口:%-5s  状态:%s\n' "$name" "$port" "$st"
    fi
  done
  if command -v systemctl >/dev/null 2>&1; then
    echo "Sing-box状态：$(systemctl is-active "$UNIT" 2>/dev/null || echo '未知')"
  fi
}

show_menu() {
  if [[ "$EUID" -ne 0 ]]; then
    echo "[错误] 请以 root 运行，例如：sudo bash $0 menu"
    exit 1
  fi
  load_env_or_exit
  while true; do
    echo
    echo "================ sing-box 管理菜单（v${SCRIPT_VERSION}）================"
    show_port_status
    echo
    echo "1. 查看节点链接"
    echo
    echo "2. 重启 sing-box 服务"
    echo "3. Argo 隧道管理"
    echo
    echo "4. 更换 UUID（全协议）"
    echo "5. 更换端口"
    echo "6. 更新 Reality 密钥对"
    echo "7. 更新自签证书"
    echo
    echo "8. 更新 sing-box 内核到最新版"
    echo "9. 更新脚本到最新版"
    echo
    echo "10. 卸载"
    echo "0. 退出"
    echo "==================================================="
    read -rp "请选择 [0-10]: " choice
    case "$choice" in
      1) load_env_or_exit; print_links ;;
      2) do_restart ;;
      4) do_change_uuid ;;
      5) do_change_ports ;;
      6) do_change_reality ;;
      7) do_change_cert ;;
      3) do_argo_menu ;;
      8) detect_arch; if ! do_update_core; then echo "[提示] 内核更新未完成，见上方信息"; fi ;;
      9) if do_update_script; then exec /usr/local/bin/sbox menu; fi ;;
      10) do_uninstall; break ;;
      0) echo "退出"; break ;;
      *) echo "[错误] 无效选择" ;;
    esac
  done
}


#----------------------------- 主流程 ----------------------------------------
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
    disable_dnf_makecache
    install_singbox
    setup_shortcut
    gen_certs
    load_or_gen_identity
    write_config
    open_firewall
    fix_selinux
    setup_service
    start_argo
    print_links
    echo
    echo "[完成] 6 种协议已就绪，链接见上 / $LINKS_FILE"
    ;;
  uninstall)
    do_uninstall
    ;;
  menu)
    show_menu
    ;;
  change-uuid)
    do_change_uuid
    ;;
  change-reality)
    do_change_reality
    ;;
  change-cert)
    do_change_cert
    ;;
  change-argo)
    do_argo_menu
    ;;
  change-ports)
    do_change_ports
    ;;
  show-links)
    load_env_or_exit; print_links
    ;;
  restart)
    do_restart
    ;;
  update-script)
    do_update_script
    ;;
  update-core)
    load_env_or_exit; detect_arch; do_update_core
    ;;
  *)
    echo "用法：$0 [install|uninstall|menu|change-uuid|change-reality|change-cert|change-argo|change-ports|show-links|restart|update-script|update-core|version]"
    exit 1
    ;;
esac
