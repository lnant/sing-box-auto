#!/bin/sh
# ============================================================================
# node-auto 自拉式一键安装脚本（POSIX sh，单文件）
#
#
# 1. 至少一个可用的入站端口（平台分配的高位端口即可）。
# 给一个口只起一个实例；给两个口则 TLS、明文各起一个实例。
# 2. 出站能访问 nodejs.org 与 registry.npmjs.org
# （脚本要自己下载 Node 运行时与 ws 依赖，机器上不需要预装 Node）。
#    例外是 FreeBSD：Node 官方不发布 FreeBSD 二进制包，系统里有
#    Node 18 以上（pkg / ports 装的即可）时直接用系统的、不下载；
#    没有系统 Node 时可用 --node-tarball 喂入本地包。
# 3. 不需要 root、不需要 systemd；只需要 POSIX sh、tar，
# 以及 curl / wget / fetch / python3 / perl(LWP) 任意一种下载工具。
# 有 systemd 且以 root 运行时，可选由 systemd 单元保活（见 --keepalive）。
# 4. 说明：测试环境有限，不保证实际环境安装效果。
#
#
# sh node-auto.sh --tls-port 31456 --plain-port 25350 --domain example.com
# 环境变量同义：NA_TLS_PORT / NA_PLAIN_PORT / NA_DOMAIN / NA_IP / NA_UUID / NA_DIR
# --tls-port 与 --plain-port 任选其一即只起一个实例。
# 域名可留空：缺省用本机地址出链接；填了域名会先校验它的解析是否
# 指向本机，验过才用域名出链接、证书也签给它，指不对就回落到裸 IP
# 出链接，不中断安装。重跑可改域名：只重签证书并重出链接，UUID 与
# 端口读回旧值不变。校验的顺序是「能直接获得的，就直接过」：网卡
# 地址、机器自身元数据服务给出的公网地址、--ip 手填或配置里存过的
# 公网地址，任一路命中就用域名，不多问一句；全程只比对本机地址
# 集合，不经任何代理、不问任何第三方站点。
# 交互安装时域名与公网 IP 是前后两道判断，每轮输入都限时 20 秒：
# 第一道是域名——不输入（回车或超时）就跳过、不用域名，不算错；
# 输入了，脚本先把要加的解析记录原样打印出来（记录由装机人自己去
# 面板加，脚本不碰任何解析后台、不要任何令牌），再轮询约 1 分钟
# 等解析生效。验不过会把实际查到的解析打出来、提醒不要开黄云，
# 并计 1 次错；接下来直接回车就是复查同一个域名（不用重输），
# 输入新域名就是换一个再查，超时没输入也计 1 次错；格式不对只
# 提醒重输、不计次。满 3 次错就不用域名、用本机地址出链接把安装
# 走完（域名以后能改：菜单 2 或带 --domain 重跑）。
# 第二道是公网 IP——只有域名解析到了、只是脚本自动确认不了它是不
# 是本机（公网 IP 不落在网卡上、元数据也问不到）时才出现：提示会
# 说清为什么要手填、去哪里看这个 IP，填进来重新比对，命中就用
# 域名。空填、格式不对、与解析对不上、超时都算失败，满 3 次直接
# 报错、退出安装；填对的 IP 会存进配置，重跑不再问。
# 非交互（带齐参数一条命令跑完）两道都不问：参数给的域名照样验，
# 验不过或确认不了就回落裸 IP 出链接装完，并提示用 --ip 指定。
# 回落的裸 IP 也只认公网地址：自动探测认不到公网 IP 时，交互下当场
# 请装机人手填（空／超时／输错都计次，满 3 次退出），非交互直接
# 报错退出、写明加 --ip 重跑——不拿内网地址顶上。
# 探测到的地址若落在 100.64.0.0/10（运营商级 NAT）这类断不准公私
# 的段，脚本不硬判：交互下请装机人输入确认（必须是服务器的公网
# IP，与探测到的完全一致就按其确认是公网接受），非交互报错退出。
# 默认直接安装（以运行脚本的身份装）：非 root 时自动选口会跳过绑不了
# 的特权口。只有你明确指定了特权口、或非 root 指定 systemd 保活这类
# 直接装办不到的事，脚本才会先提示、再经 sudo 以 root 身份继续（不
# 静默提权；sudo 不可用就如实报错或回落 guard）。装完会自检实例是否
# 真在目标口应答，没起来如实报错、不报「安装完成」。
# 重跑幂等：已有安装会读回原 UUID 与端口（不换），只补齐/修复进程。
# 已安装且在终端里不带参数重跑，进快捷菜单（1 看链接 / 2 改域名 /
# 3 重启服务 / 4 卸载 / 0 退出）；带参数或非交互调用不进菜单。
# 端口都缺省时自动选口：先试 Cloudflare 名单口（TLS 443/8443/2053/
# 2083/2087/2096，明文 8080/2052/2082/2086/2095），全不可用才随机
# 高位口；落到随机口的，域名只能开灰云（Cloudflare 只转发名单内端口）。
# 卸载：sh node-auto.sh --uninstall [--dir 目录]，或运行安装目录里的 uninstall.sh
#
# 安装目录结构（默认./node-auto）：
# node/ 脚本自拉的 Node v22 运行时（FreeBSD 用系统 Node 时不生成此目录，
# 实际来源与路径记在 config.env 的 NODE_SOURCE / NODE_BIN）
# app/ app.js + game.html + node_modules(ws)
# tools/ 自签证书生成器（selfsigned，纯 JS）与解析校验小工具
# cert.pem key.pem 自签证书（TLS 实例用）
# config.env UUID / 域名 / 端口 / 证书域名 / 保活方式（重跑读回的依据）
# start.sh guard.sh stop.sh uninstall.sh
# run/ logs/ pid 文件与日志（guard 只记拉起事件，app 不记连接日志）
# ============================================================================
set -u

NODE_FALLBACK_VER=v22.23.5
WS_VERSION=8.18.3

say() { printf '%s\n' "$*";}
err() { printf '%s\n' "$*" >&2;}
die() { err "错误：$*"; exit 1;}
have() { command -v "$1" >/dev/null 2>&1;}

# ---------- 限时输入（域名／公网 IP 两处提问共用） ----------
# 每轮输入限时 NA_PROMPT_TIMEOUT 秒（缺省 20）：装机人走开、或记录还没
# 加好时，安装不会永远卡在一句提问上；超时和空填、填错一样计次。
# 本脚本是 POSIX sh，而 read -t 不是 POSIX 功能（dash 不支持），所以先
# 探测当前 shell 的 read 支不支持 -t：支持就限时，不支持就退化成普通
# read（不会超时，其余的计数、复查口径不变）。
NA_PROMPT_TIMEOUT=${NA_PROMPT_TIMEOUT:-20}
NA_READ_T=0
( read -t 0 _na_probe </dev/null ) 2>/dev/null
[ $? != 2 ] && NA_READ_T=1
na_read_timed() { # $1=限时秒数；读到的内容放在 NA_IN；返回 0=读到 1=没读到(EOF) 2=超时
  NA_IN=''
  if [ "$NA_READ_T" = "1" ]; then
    read -t "$1" -r NA_IN
    _na_rc=$?
    if [ "$_na_rc" = "0" ]; then return 0; fi
    if [ "$_na_rc" -gt 128 ]; then return 2; fi # 超时：返回码大于 128（注意要在 read 之后立刻取，隔了 if 就被冲掉）
    return 1
  fi
  if read -r NA_IN; then return 0; fi
  return 1
}
valid_domain() { # $1=已去空白、转小写的候选域名：粗校验格式（至少带一个点、只用合法字符、点与横杠不落在怪位置）
  case "$1" in
    *.*) ;;
    *) return 1;;
  esac
  case "$1" in
    [!a-z0-9.-]*|.*|*.|*..*|-*|*-|*.-*|*-.*) return 1;;
  esac
  return 0
}

usage() {
cat <<'USAGE'
用法：
sh node-auto.sh --tls-port <端口> [--plain-port <端口>] [--domain <域名或IP>]
sh node-auto.sh --uninstall [--dir <安装目录> ]

参数（括号内为同义环境变量）：
--tls-port TLS 实例端口（NA_TLS_PORT）；缺省自动选口
--plain-port 明文实例端口（NA_PLAIN_PORT）；缺省自动选口
  自动选口：先试 Cloudflare 名单口（TLS 443/8443/2053/2083/2087/2096，
  明文 8080/2052/2082/2086/2095），全不可用才随机高位口（只能开灰云）；
  只给一个端口即只起一个实例，两个都不给则两个都自动选
--domain 对外域名或公网 IP，生成节点链接与证书用（NA_DOMAIN，可留空）
  留空时用本机公网地址出链接；填域名会先校验解析是否指向本机，验过才用
  域名，指不对就回落裸 IP 出链接；回落地址只认公网 IP（内网地址写进
  链接外网连不上），自动认不到公网 IP 时交互会请你手填、非交互会
  报错退出（加 --ip 重跑）；重跑带新域名可切换
  （UUID/端口不变）。交互安装时不用这个参数也能现输入域名：脚本会
  把要加的解析记录打印出来（自己去面板加，不要开黄云），再验约
  1 分钟；验不过时回车可复查、输新域名可换，满 3 次错就不用域名
  继续装完，域名以后能改（菜单 2 或带 --domain 重跑）
--ip 手填本机公网 IP（NA_IP）：公网 IP 不落在网卡上且元数据也问不到
  的机器，自动校验认不出本机公网地址；把域名解析先指向这个公网 IP，
  再用 --ip <公网IP> --domain <域名> 重跑即可配上域名。交互安装时
  不用记这个参数：能自动获得的地址直接过；域名解析到了、只是
  自动确认不了是不是本机时，才多问一步本机公网 IP（每轮限时
  20 秒；空填、格式不对、对不上、超时都算失败，满 3 次直接报错、
  退出安装），填对了效果一样，并会存进配置、以后不用再填。
  只给 --ip 不给 --domain 时，直接用这个 IP 出链接
--uuid 指定 UUID（NA_UUID，缺省自动生成；重跑时读回旧值不换）
--dir 安装目录（NA_DIR，缺省./node-auto）
--keepalive 保活方式（NA_KEEPALIVE）：systemd 或 guard
  缺省自动：有 systemd 且以 root 运行用 systemd，否则用 guard 巡检守护
  默认以运行脚本的身份直接安装、不自动提权；只有明确指定特权口或
  非 root 指定 systemd 这类直接装办不到的事，才会提示后经 sudo 落地
  --node-tarball 本地 Node 包路径（NA_NODE_TARBALL）；机器上没有可用下载工具时，先把官方 Node 包传进来再用它安装；FreeBSD 上系统没有 Node 18 以上时也靠它喂包（FreeBSD 有系统 Node 18 以上则自动用系统的、不下载）
--uninstall 卸载：停掉守护与实例进程（systemd 保活时一并移除单元）并删除安装目录
已安装时在终端里不带参数重跑，进快捷菜单（1 看链接 / 2 改域名 / 3 重启服务 / 4 卸载 / 0 退出）
USAGE
}

# ---------- 下载工具（curl → wget → fetch → python3 → perl LWP） ----------
fetch_file() { # $1=url $2=dest
if have curl; then
curl -fL --retry 2 --connect-timeout 15 -o "$2" "$1" </dev/null
elif have wget; then
wget -O "$2" "$1" </dev/null
elif have fetch; then
fetch -q -o "$2" "$1" </dev/null
elif have python3; then
python3 -c 'import sys,urllib.request; urllib.request.urlretrieve(sys.argv[1], sys.argv[2])' "$1" "$2" </dev/null
elif have perl; then
perl -MLWP::Simple -e 'my $s=getstore($ARGV[0],$ARGV[1]); exit(defined $s && $s < 400? 0: 1)' "$1" "$2" </dev/null
else
return 1
fi
}
fetch_stdout() { # $1=url
if have curl; then
curl -fsS -m 12 "$1" </dev/null 2>/dev/null
elif have wget; then
wget -q -T 12 -O - "$1" </dev/null 2>/dev/null
elif have fetch; then
fetch -q -o - "$1" </dev/null 2>/dev/null
elif have python3; then
python3 -c 'import sys,urllib.request; sys.stdout.write(urllib.request.urlopen(sys.argv[1], timeout=12).read().decode())' "$1" </dev/null 2>/dev/null
elif have perl; then
perl -MLWP::Simple -e 'my $d=get($ARGV[0]); print $d if defined $d' "$1" </dev/null 2>/dev/null
else
return 1
fi
}
have_fetcher() { have curl || have wget || have fetch || have python3 || have perl;}

# ---------- 参数解析 ----------
RAW_ARGC=$#
OPT_TLS_PORT=${NA_TLS_PORT:-}
OPT_PLAIN_PORT=${NA_PLAIN_PORT:-}
OPT_DOMAIN=${NA_DOMAIN:-}
OPT_IP=${NA_IP:-}
OPT_UUID=${NA_UUID:-}
OPT_DIR=${NA_DIR:-}
OPT_NODE_TARBALL=${NA_NODE_TARBALL:-}
OPT_KEEPALIVE=${NA_KEEPALIVE:-}
DO_UNINSTALL=0
while [ $# -gt 0 ]; do
case "$1" in
--tls-port) [ $# -ge 2 ] || die "--tls-port 需要一个参数"; OPT_TLS_PORT=$2; shift 2;;
--plain-port) [ $# -ge 2 ] || die "--plain-port 需要一个参数"; OPT_PLAIN_PORT=$2; shift 2;;
--domain) [ $# -ge 2 ] || die "--domain 需要一个参数"; OPT_DOMAIN=$2; shift 2;;
--ip) [ $# -ge 2 ] || die "--ip 需要一个参数"; OPT_IP=$2; shift 2;;
--uuid) [ $# -ge 2 ] || die "--uuid 需要一个参数"; OPT_UUID=$2; shift 2;;
--dir) [ $# -ge 2 ] || die "--dir 需要一个参数"; OPT_DIR=$2; shift 2;;
--keepalive) [ $# -ge 2 ] || die "--keepalive 需要一个参数"; OPT_KEEPALIVE=$2; shift 2;;
    --node-tarball) [ $# -ge 2 ] || die "--node-tarball 需要一个参数"; OPT_NODE_TARBALL=$2; shift 2 ;;
--uninstall) DO_UNINSTALL=1; shift;;
-h|--help) usage; exit 0;;
*) die "未知参数：$1（--help 看用法）";;
esac
done

# ---------- 安装目录（转绝对路径） ----------
DIR=${OPT_DIR:-./node-auto}
case "$DIR" in
/*):;;
*) DIR=$(pwd)/${DIR#./};;
esac

# ---------- 卸载 ----------
if [ "$DO_UNINSTALL" -eq 1 ]; then
if [ ! -d "$DIR" ]; then
say "未找到安装目录：$DIR（无事可做）"
exit 0
fi
if [ -f "$DIR/uninstall.sh" ]; then
exec sh "$DIR/uninstall.sh"
fi
# 没有 uninstall.sh 的残缺安装：按 pid 文件尽力停进程后删目录
for tag in guard tls plain; do
pf="$DIR/run/$tag.pid"
if [ -f "$pf" ]; then
pid=$(cat "$pf" 2>/dev/null)
[ -n "$pid" ] && kill "$pid" 2>/dev/null
fi
done
sleep 1
rm -rf "$DIR"
say "已卸载：$DIR 已删除"
exit 0
fi

# ---------- 配置读回（重跑不换 UUID/端口） ----------
cfg_get() { # $1=key $2=file
[ -f "$2" ] || return 0
grep "^$1=" "$2" 2>/dev/null | head -n 1 | cut -d= -f2-
}
CFG_UUID=$(cfg_get UUID "$DIR/config.env")
CFG_DOMAIN=$(cfg_get DOMAIN "$DIR/config.env")
CFG_TLS_PORT=$(cfg_get TLS_PORT "$DIR/config.env")
CFG_PLAIN_PORT=$(cfg_get PLAIN_PORT "$DIR/config.env")
CFG_CERT_DOMAIN=$(cfg_get CERT_DOMAIN "$DIR/config.env")
CFG_KEEPALIVE=$(cfg_get KEEPALIVE "$DIR/config.env")
CFG_PUBLIC_IP=$(cfg_get PUBLIC_IP "$DIR/config.env")

UUID=${OPT_UUID:-$CFG_UUID}
TLS_PORT=${OPT_TLS_PORT:-$CFG_TLS_PORT}
PLAIN_PORT=${OPT_PLAIN_PORT:-$CFG_PLAIN_PORT}
# DOMAIN 先只记「请求值」：真正的生效值要等 Node 就绪后做解析校验再定
DOMAIN=${OPT_DOMAIN:-$CFG_DOMAIN}
# 手填的本机公网 IP（--ip）：写进配置读回，重跑不带 --ip 也沿用
PUBLIC_IP=${OPT_IP:-$CFG_PUBLIC_IP}
# 本次显式给了 --ip 又没给 --domain：对外地址就用这个手填 IP（不被读回的旧值顶住）
if [ -n "$OPT_IP" ] && [ -z "$OPT_DOMAIN" ]; then DOMAIN=$OPT_IP; fi
if [ -n "$PUBLIC_IP" ]; then
  case "$PUBLIC_IP" in
    *[!0-9a-fA-F.:]*) die "--ip 不是合法的 IP 地址：$PUBLIC_IP";;
    *.*.*.*|*:*) : ;;
    *) die "--ip 不是合法的 IP 地址：$PUBLIC_IP";;
  esac
fi

bracket_host() { # $1=域名或IP：IPv6 字面量加方括号（链接里的地址部分要用），其余原样
  case "$1" in
    \[*\]) printf '%s' "$1";;
    *:*) printf '[%s]' "$1";;
    *) printf '%s' "$1";;
  esac
}

# ---------- 快捷菜单（已安装＋终端交互＋不带任何参数/环境变量时） ----------
if [ -n "$CFG_UUID" ] && [ -t 0 ] && [ "$RAW_ARGC" -eq 0 ] \
  && [ -z "${NA_TLS_PORT:-}${NA_PLAIN_PORT:-}${NA_DOMAIN:-}${NA_IP:-}${NA_UUID:-}${NA_DIR:-}${NA_KEEPALIVE:-}${NA_NODE_TARBALL:-}" ]; then
  NODE_BIN=$(cfg_get NODE_BIN "$DIR/config.env")
  [ -n "$NODE_BIN" ] || NODE_BIN="$DIR/node/bin/node"
  menu_fetch() { # $1=url：用安装所用的 Node 取页面
    [ -x "$NODE_BIN" ] || return 1
    "$NODE_BIN" -e '
      const u = new URL(process.argv[1]);
      const lib = u.protocol === "https:" ? require("https") : require("http");
      const req = lib.get(u, { rejectUnauthorized: false }, r => {
        let d = "";
        r.on("data", c => d += c);
        r.on("end", () => { process.stdout.write(d); });
      });
      req.setTimeout(3000, () => { req.destroy(new Error("timeout")); });
      req.on("error", () => process.exit(1));
    ' "$1" 2>/dev/null
  }
  menu_build_link() { # $1=port $2=tls|none：与安装汇总同规则拼链接（取不到实时输出时用）
    if [ "$2" = tls ]; then
      printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=chrome&type=ws&host=%s&path=%%2F#Vl-ws-tls-node-auto\n' \
        "$CFG_UUID" "$(bracket_host "$CFG_DOMAIN")" "$1" "$CFG_DOMAIN" "$CFG_DOMAIN"
    else
      printf 'vless://%s@%s:%s?encryption=none&security=none&type=ws&host=%s&path=%%2F#Vl-ws-none-node-auto\n' \
        "$CFG_UUID" "$(bracket_host "$CFG_DOMAIN")" "$1" "$CFG_DOMAIN"
    fi
  }
  menu_links() {
    say "UUID：$CFG_UUID"
    if [ -n "$CFG_TLS_PORT" ]; then
      l=$(menu_fetch "https://127.0.0.1:$CFG_TLS_PORT/$CFG_UUID")
      [ -n "$l" ] || l=$(menu_build_link "$CFG_TLS_PORT" tls)
      say 'TLS 节点链接：'
      say "$l"
    fi
    if [ -n "$CFG_PLAIN_PORT" ]; then
      l=$(menu_fetch "http://127.0.0.1:$CFG_PLAIN_PORT/$CFG_UUID")
      [ -n "$l" ] || l=$(menu_build_link "$CFG_PLAIN_PORT" none)
      say '明文节点链接：'
      say "$l"
    fi
  }
  menu_restart() {
    if [ "$CFG_KEEPALIVE" = systemd ] && have systemctl; then
      [ -n "$CFG_TLS_PORT" ] && systemctl restart node-auto-tls 2>/dev/null
      [ -n "$CFG_PLAIN_PORT" ] && systemctl restart node-auto-plain 2>/dev/null
      say '已重启（systemd 单元）'
      return 0
    fi
    [ -f "$DIR/stop.sh" ] && sh "$DIR/stop.sh"
    [ -f "$DIR/start.sh" ] && sh "$DIR/start.sh"
    gr=0
    if [ -f "$DIR/run/guard.pid" ]; then
      gp=$(cat "$DIR/run/guard.pid" 2>/dev/null)
      if [ -n "$gp" ] && kill -0 "$gp" 2>/dev/null; then gr=1; fi
    fi
    if [ "$gr" -eq 0 ] && [ -f "$DIR/guard.sh" ]; then
      if have setsid; then LAUNCH=setsid; else LAUNCH=nohup; fi
      $LAUNCH sh "$DIR/guard.sh" >> "$DIR/logs/guard.out" 2>&1 </dev/null &
    fi
    say '已重启'
  }
  while true; do
    say ''
    say '==================== node-auto 快捷菜单 ===================='
    say "安装目录：$DIR"
    say '1) 看链接'
    say '2) 改域名（重签证书＋重出链接，UUID/端口不变）'
    say '3) 重启服务'
    say '4) 卸载'
    say '0) 退出'
    printf '请选择：'
    read -r choice || exit 0
    case "$choice" in
      1) menu_links;;
      2)
        say '改域名：先把新域名的解析指向这台机器（记录内容填本机公网地址、不要开黄云），再在下面输入新域名。'
        say '接下来和安装时是同一套校验：验过就换上新域名，验不过会改用本机地址出链接把这次走完（现在的域名就先不用了，之后随时能再改）；要是这台机器的公网 IP 脚本自动确认不了，中间会多问一步本机公网 IP，照提示填就行。'
        printf '输入新域名（留空取消）：'
        read -r nd || nd=''
        nd=$(printf '%s' "$nd" | tr -d '[:space:]' | tr 'A-Z' 'a-z')
        if [ -n "$nd" ]; then
          exec sh "$0" --dir "$DIR" --domain "$nd"
        fi
        ;;
      3) menu_restart;;
      4)
        printf '确认卸载？将停掉服务并删除整个安装目录（y/N）：'
        read -r yn || yn=''
        case "$yn" in
          y|Y) exec sh "$0" --uninstall --dir "$DIR";;
          *) say '已取消';;
        esac
        ;;
      0) exit 0;;
      *) say '无效选择';;
    esac
  done
fi

# ---------- 端口（缺省自动选口：先 Cloudflare 名单口，不可用才随机） ----------
CF_TLS_PORTS='443 8443 2053 2083 2087 2096'
CF_PLAIN_PORTS='8080 2052 2082 2086 2095'
is_port() {
case "$1" in ''|*[!0-9]*) return 1;; esac
[ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}
in_list() { # $1=值 $2=空格分隔名单
for x in $2; do [ "$x" = "$1" ] && return 0; done
return 1
}
port_listening() { # $1=port：已在监听返回 0（查 /proc/net/tcp*，查不到就当空闲）
[ -r /proc/net/tcp ] || return 1
hex=$(printf '%04X' "$1" 2>/dev/null) || return 1
for f in /proc/net/tcp /proc/net/tcp6; do
[ -r "$f" ] || continue
if awk -v h="$hex" 'NR>1 { split($2,a,":"); if (a[2]==h && $4=="0A") { f=1; exit } } END { exit(f?0:1) }' "$f"; then
return 0
fi
done
return 1
}
rand_high_port() {
n=''
if [ -r /dev/urandom ] && have od; then
n=$(od -An -tu2 -N 2 /dev/urandom 2>/dev/null | tr -d ' \n')
fi
case "$n" in ''|*[!0-9]*) n=$$;; esac
printf '%s' $((20000 + n % 40000))
}
# 非 root 的特权口下限：低于 ip_unprivileged_port_start 的端口非 root
# 绑不了，选口时跳过（读不到该值按 1024 保守处理；root 不受限、下限为 0）
PRIV_FLOOR=0
if [ "$(id -u 2>/dev/null)" != "0" ]; then
PRIV_FLOOR=$(cat /proc/sys/net/ipv4/ip_unprivileged_port_start 2>/dev/null)
case "$PRIV_FLOOR" in ''|*[!0-9]*) PRIV_FLOOR=1024;; esac
fi
pick_port() { # $1=名单 $2=要避开的端口（可空）：名单按序试可用（跳过绑不了的特权口），全占用才随机
for p in $1; do
[ "$p" = "$2" ] && continue
[ "$p" -lt "$PRIV_FLOOR" ] && continue
port_listening "$p" || { printf '%s' "$p"; return 0; }
done
i=0
p=''
while [ $i -lt 20 ]; do
p=$(rand_high_port)
if [ "$p" != "$2" ]; then
port_listening "$p" || { printf '%s' "$p"; return 0; }
fi
i=$((i + 1))
done
printf '%s' "$p"
}
port_note() { # $1=标签 $2=port $3=名单：当场说明这个口能不能开黄云
if in_list "$2" "$3"; then
say "  $1 口 $2 在 Cloudflare 名单内：装完后域名可开黄云"
else
say "  $1 口 $2 不在 Cloudflare 名单内：域名只能开灰云（Cloudflare 只转发名单内端口）"
fi
}
PROMPT_PORTS=0
if [ -z "$TLS_PORT" ] && [ -z "$PLAIN_PORT" ] && [ -t 0 ]; then
printf '请输入 TLS 端口（留空跳过；两个都留空则自动选口）: '; read -r TLS_PORT || TLS_PORT=''
printf '请输入明文端口（留空跳过；两个都留空则自动选口）: '; read -r PLAIN_PORT || PLAIN_PORT=''
if [ -n "$TLS_PORT" ] || [ -n "$PLAIN_PORT" ]; then PROMPT_PORTS=1; fi
fi
# 域名输入（交互安装、且没用参数/已存配置给域名时）：先把这一问的
# 来龙去脉说清再收输入——域名是给 TLS 链接与证书用的；输入了的，
# 后面会打印要加的解析记录、再验解析对不对（见「确定生效的对外地址」
# 一段）：验过就用域名，验不过有复查与换域名的机会，满 3 次错就不用
# 域名、默认地址继续往下；解析到了只是确认不了是不是本机时，会再要求
# 输入本机公网 IP。不输入（回车或限时内没输入）就跳过这一问，不算错。
DOMAIN_FROM_PROMPT=0
if [ -z "$DOMAIN" ] && [ -t 0 ]; then
say ''
say '接下来定 TLS 链接用的域名（可以跳过）：'
say '  有自己的域名、想用域名出链接的，在下面输入完整域名。脚本会把要加的解析记录原样打印出来，你照着去域名面板加好（记录由你自己加，脚本不碰解析后台、不要任何令牌），脚本再花约 1 分钟验一遍解析对不对，验过就用域名、证书也签给它。'
say "  没有域名、或还没弄好解析的，直接回车（或 ${NA_PROMPT_TIMEOUT} 秒不输入）跳过：用本机地址出链接，安装照常走完；域名以后随时能加——重跑脚本进菜单选 2 改域名，或带 --domain 重跑，UUID 与端口都不变。"
printf '请输入域名（留空跳过）: '
na_read_timed "$NA_PROMPT_TIMEOUT"
DOMAIN=$(printf '%s' "$NA_IN" | tr -d '[:space:]' | tr 'A-Z' 'a-z')
[ -n "$DOMAIN" ] && DOMAIN_FROM_PROMPT=1
fi
if [ -z "$TLS_PORT" ] && [ -z "$PLAIN_PORT" ]; then
TLS_PORT=$(pick_port "$CF_TLS_PORTS" '')
PLAIN_PORT=$(pick_port "$CF_PLAIN_PORTS" "$TLS_PORT")
say "自动选口：TLS $TLS_PORT / 明文 $PLAIN_PORT"
if [ "$PRIV_FLOOR" -gt 0 ]; then
say "  提示：当前非 root 运行，低于 $PRIV_FLOOR 的端口无权绑定，选口已自动跳过"
fi
port_note TLS "$TLS_PORT" "$CF_TLS_PORTS"
port_note 明文 "$PLAIN_PORT" "$CF_PLAIN_PORTS"
fi
[ -z "$TLS_PORT" ] || is_port "$TLS_PORT" || die "TLS 端口不合法：$TLS_PORT"
[ -z "$PLAIN_PORT" ] || is_port "$PLAIN_PORT" || die "明文端口不合法：$PLAIN_PORT"
# ---------- 提权落（只限使用者明确指定、直接装办不到时；绝不静默提权） ----------
# 默认就是直接安装：自动选口绑不了的口自动跳过，不惊动 root。只有
# 使用者明确指定了特权口、或明确指定 systemd 保活而本人非 root 时，
# 才提示并经 sudo 以 root 身份重跑安装；sudo 不可用时如实报错或回落。
EXP_LOW=0
for p in "$OPT_TLS_PORT" "$OPT_PLAIN_PORT"; do
[ -n "$p" ] && [ "$p" -lt "$PRIV_FLOOR" ] && EXP_LOW=1
done
if [ "$PROMPT_PORTS" = "1" ]; then
for p in "$TLS_PORT" "$PLAIN_PORT"; do
[ -n "$p" ] && [ "$p" -lt "$PRIV_FLOOR" ] && EXP_LOW=1
done
fi
EXP_SYSTEMD=0
[ "$OPT_KEEPALIVE" = "systemd" ] && EXP_SYSTEMD=1
if [ "$(id -u 2>/dev/null)" != "0" ] && { [ "$EXP_LOW" = "1" ] || [ "$EXP_SYSTEMD" = "1" ]; }; then
WHY=''
[ "$EXP_LOW" = "1" ] && WHY="指定了低于 $PRIV_FLOOR 的特权口"
if [ "$EXP_SYSTEMD" = "1" ]; then
[ -n "$WHY" ] && WHY="$WHY 与 "
WHY="${WHY}指定了 systemd 保活"
fi
if [ "${NA_ELEVATED:-}" = "1" ]; then
die "已尝试过 sudo 提权但当前仍不是 root，无法落地：$WHY"
fi
if have sudo && sudo -n true 2>/dev/null; then
say "提示：你$WHY，当前身份（非 root）直接装办不到；改用 sudo 以 root 身份继续安装（安装目录与进程将归 root，本行即提权告知，不静默提权）"
set --
[ -n "$OPT_TLS_PORT" ] && set -- "$@" --tls-port "$OPT_TLS_PORT"
[ -n "$OPT_PLAIN_PORT" ] && set -- "$@" --plain-port "$OPT_PLAIN_PORT"
if [ "$PROMPT_PORTS" = "1" ]; then
[ -n "$TLS_PORT" ] && [ -z "$OPT_TLS_PORT" ] && set -- "$@" --tls-port "$TLS_PORT"
[ -n "$PLAIN_PORT" ] && [ -z "$OPT_PLAIN_PORT" ] && set -- "$@" --plain-port "$PLAIN_PORT"
fi
[ -n "$OPT_DOMAIN" ] && set -- "$@" --domain "$OPT_DOMAIN"
[ -n "$DOMAIN" ] && [ -z "$OPT_DOMAIN" ] && set -- "$@" --domain "$DOMAIN"
[ -n "$PUBLIC_IP" ] && set -- "$@" --ip "$PUBLIC_IP"
[ -n "$OPT_UUID" ] && set -- "$@" --uuid "$OPT_UUID"
[ -n "$OPT_KEEPALIVE" ] && set -- "$@" --keepalive "$OPT_KEEPALIVE"
[ -n "$OPT_NODE_TARBALL" ] && set -- "$@" --node-tarball "$OPT_NODE_TARBALL"
set -- "$@" --dir "$DIR"
exec sudo -n env NA_ELEVATED=1 sh "$0" "$@"
fi
if [ "$EXP_LOW" = "1" ]; then
die "你指定的端口低于本机非特权下限 $PRIV_FLOOR，非 root 绑不了，且 sudo 不可用（不存在或需要密码）；请改用不低于 $PRIV_FLOOR 的端口，或以 root 身份运行"
fi
say "提示：你指定了 systemd 保活，但当前非 root 且 sudo 不可用（不存在或需要密码），办不到；改用 guard 保活继续安装"
fi
if [ -n "$TLS_PORT" ] && [ "$TLS_PORT" = "$PLAIN_PORT" ]; then
die "TLS 端口与明文端口不能相同：$TLS_PORT"
fi

# ---------- 域名（生效值延后确定） ----------
# 等 Node 就绪后，用 tools/resolve.js 把请求域名的 A/AAAA 解析与本机
# 地址集合逐一比对（网卡地址＋机器自身元数据服务给出的公网地址；
# 元数据只问机器自己的 link-local 端点，不经任何代理或第三方站点），
# 指对才用域名；没填或没指对就用回落地址出链接（只认公网地址；
# 认不到公网地址时走后面「对外地址终检」的手填／报错，不拿内网顶上）。
# 校验段在「安装期装 ws」之后、「生成证书」之前。

# ---------- UUID（能用 shell 生成就先生成，否则等 Node 装好再补） ----------
gen_uuid_sh() {
if [ -r /proc/sys/kernel/random/uuid ]; then
cat /proc/sys/kernel/random/uuid
return 0
fi
if [ -r /dev/urandom ] && have od; then
h=$(od -An -tx1 -N 16 /dev/urandom | tr -d ' \n')
[ ${#h} -eq 32 ] || return 1
a=$(printf '%s' "$h" | cut -c1-8)
b=$(printf '%s' "$h" | cut -c9-12)
c=$(printf '%s' "$h" | cut -c14-16)
v=$(printf '%s' "$h" | cut -c17)
d=$(printf '%s' "$h" | cut -c18-20)
e=$(printf '%s' "$h" | cut -c21-32)
# 变体位应为 8/9/a/b：本身已是就保留，否则一律置 8（仅作标识用，足够）
case "$v" in 8|9|a|b) vv=$v;; *) vv=8;; esac
printf '%s-%s-4%s-%s%s-%s\n' "$a" "$b" "$c" "$vv" "$d" "$e"
return 0
fi
return 1
}
if [ -z "$UUID" ]; then
UUID=$(gen_uuid_sh) || UUID=''
fi

# ---------- 工具检查 ----------
have tar || die "缺少 tar，无法解压 Node"
have_fetcher || die "缺少下载工具：需要 curl / wget / fetch / python3 / perl(LWP) 任意一种"

# ---------- 建目录、写出内嵌的 app 文件 ----------
say "安装目录：$DIR"
say "说明：测试环境有限，不保证实际环境安装效果。"
mkdir -p "$DIR/app" "$DIR/tools" "$DIR/run" "$DIR/logs" || die "无法创建安装目录：$DIR"

cat > "$DIR/app/app.js" <<'SB_EOF_APPJS'
const os = require('os');
const http = require('http');
const https = require('https');
const fs = require('fs');
const path = require('path');
const net = require('net');
const { exec, execSync } = require('child_process');
function ensureModule(name) {
    try {
        require.resolve(name);
    } catch (e) {
        console.log(`Module '${name}' not found. Installing...`);
        execSync(`npm install ${name}`, { stdio: 'inherit' });
    }
}
ensureModule('ws');
const { WebSocket, createWebSocketStream } = require('ws');
const NAME = process.env.NAME || os.hostname();
async function getVariableValue(variableName, defaultValue) {
    const envValue = process.env[variableName];
    if (envValue) {
        return envValue; 
    }
    if (defaultValue) {
        return defaultValue; 
    }
  let input = '';
  while (!input) {
    input = await ask(`请输入${variableName}: `);
    if (!input) {
      console.log(`${variableName}不能为空，请重新输入!`);
    }
  }
  return input;
}
function ask(question) {
    const rl = require('readline').createInterface({ input: process.stdin, output: process.stdout });
    return new Promise(resolve => rl.question(question, ans => { rl.close(); resolve(ans.trim()); }));
}
async function main() {
    const UUID = await getVariableValue('UUID', '');

    const PORT = await getVariableValue('PORT', '');

    const DOMAIN = await getVariableValue('DOMAIN', '');

    const LINK_HOST = process.env.LINK_HOST || DOMAIN;
    const LINK_PORT = process.env.LINK_PORT || '443';
    const LINK_SECURITY = process.env.LINK_SECURITY || 'tls';
    const LINK_SNI = process.env.LINK_SNI || LINK_HOST;
    const LINK_WSHOST = process.env.LINK_WSHOST || LINK_HOST;
    function buildLink(addr) {
        const sec = LINK_SECURITY === 'tls' ? `security=tls&sni=${LINK_SNI}&fp=chrome` : 'security=none';
        // 地址是 IPv6 字面量时必须写成 [addr]:port，已带括号的（如优选列表里的）不重复加
        const host = (addr.includes(':') && !addr.startsWith('[')) ? `[${addr}]` : addr;
        return `vless://${UUID}@${host}:${LINK_PORT}?encryption=none&${sec}&type=ws&host=${LINK_WSHOST}&path=%2F#Vl-ws-${LINK_SECURITY}-${NAME}`;
    }
    const CERT_FILE = process.env.CERT_FILE || '';
    const KEY_FILE = process.env.KEY_FILE || '';

    // 静态页面白名单：只有这些路径按 HTML 文件输出，其余一律 404，不做目录遍历。
    const PAGES = new Set(['/about.html', '/poems.html',
        '/poems/shuidiaogetou.html', '/poems/shengshengman.html', '/poems/qingyuan.html',
        '/poems/yinjiu.html', '/poems/denggao.html']);
    // 读文件并输出；文件不存在返回 false，调用方自行决定回落或 404。
    const serveFile = (res, file) => {
        try {
            const body = fs.readFileSync(path.join(__dirname, file));
            res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
            res.end(body);
            return true;
        } catch { return false; }
    };

    const requestHandler = (req, res) => {
        const u = decodeURIComponent(req.url.split('?')[0]);
        if (u === '/') {
            // 新站首页 index.html；旧包（无该文件）仍回落到 game.html，装机流程不受影响
            if (!serveFile(res, 'index.html')) serveFile(res, 'game.html');
        } else if (PAGES.has(u)) {
            if (!serveFile(res, u.slice(1))) {
                res.writeHead(404, { 'Content-Type': 'text/plain' });
                res.end('Not Found\n');
            }
        } else if (u === `/${UUID}`) {
            let vlessURL;
            if (NAME.includes('server') || NAME.includes('hostypanel')) {
                vlessURL = [LINK_HOST, '104.16.0.0', '104.17.0.0', '104.18.0.0', '104.19.0.0', '104.20.0.0', '104.21.0.0', '104.22.0.0', '104.24.0.0', '104.25.0.0', '104.26.0.0', '104.27.0.0', '[2606:4700::]', '[2400:cb00:2049::]'].map(a => buildLink(a)).join('\n');
            } else {
                vlessURL = buildLink(LINK_HOST);
            }
            res.writeHead(200, { 'Content-Type': 'text/plain' });
            res.end(vlessURL + '\n');
        } else {
            res.writeHead(404, { 'Content-Type': 'text/plain' });
            res.end('Not Found\n');
        }
    };

    const httpServer = (CERT_FILE && KEY_FILE)
        ? https.createServer({ cert: fs.readFileSync(CERT_FILE), key: fs.readFileSync(KEY_FILE) }, requestHandler)
        : http.createServer(requestHandler);

    httpServer.listen(PORT, () => {
        console.log(`${CERT_FILE && KEY_FILE ? 'HTTPS' : 'HTTP'} Server is running on port ${PORT}`);
    });

    const wss = new WebSocket.Server({ server: httpServer });
    const uuid = UUID.replace(/-/g, "");
    wss.on('connection', ws => {
        let buf = Buffer.alloc(0);
        let settled = false;
        const fail = () => {
            if (settled) return;
            settled = true;
            try { ws.close(); } catch (e) { }
        };
        const tryParseHeader = () => {
            if (buf.length < 18) return null;
            const version = buf[0];
            for (let k = 0; k < 16; k++) {
                if (buf[1 + k] != parseInt(uuid.substr(k * 2, 2), 16)) return -1;
            }
            let i = 18 + buf[17];
            if (buf.length < i + 4) return null;
            if (buf[i] !== 1) return -1;
            const port = buf.readUInt16BE(i + 1);
            const atyp = buf[i + 3];
            i += 4;
            let host;
            if (atyp === 1) {
                if (buf.length < i + 4) return null;
                host = buf.slice(i, i + 4).join('.');
                i += 4;
            } else if (atyp === 2) {
                if (buf.length < i + 1) return null;
                const len = buf[i];
                if (len === 0 || buf.length < i + 1 + len) return null;
                host = new TextDecoder().decode(buf.slice(i + 1, i + 1 + len));
                i += 1 + len;
            } else if (atyp === 3) {
                if (buf.length < i + 16) return null;
                const parts = [];
                for (let k = 0; k < 16; k += 2) parts.push(buf.readUInt16BE(i + k).toString(16));
                host = parts.join(':');
                i += 16;
            } else {
                return -1;
            }
            if (!host) return -1;
            return { version, host, port, rest: buf.slice(i) };
        };
        const onMessage = msg => {
            try {
                if (settled) return;
                if (!Buffer.isBuffer(msg)) msg = Buffer.from(msg);
                buf = buf.length ? Buffer.concat([buf, msg]) : msg;
                if (buf.length > 4096) return fail();
                const parsed = tryParseHeader();
                if (parsed === null) return;
                if (parsed === -1) return fail();
                settled = true;
                ws.removeListener('message', onMessage);
                ws.send(new Uint8Array([parsed.version, 0]));
                const duplex = createWebSocketStream(ws);
                net.connect({ host: parsed.host, port: parsed.port }, function () {
                    if (parsed.rest.length) this.write(parsed.rest);
                    duplex.on('error', () => { }).pipe(this).on('error', () => { }).pipe(duplex);
                }).on('error', () => { });
            } catch (e) {
                fail();
            }
        };
        ws.on('message', onMessage).on('error', () => { });
    });
}
main();
SB_EOF_APPJS

cat > "$DIR/app/game.html" <<'SB_EOF_GAMEHTML'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>云汀 · 诗词小读</title>
<style>
  * { box-sizing: border-box; }
  html { -webkit-text-size-adjust: 100%; }
  body {
    margin: 0;
    background: #f7f3ea;
    color: #2e2a24;
    font-family: "Noto Serif SC", "Songti SC", "STSong", "SimSun", "宋体", serif;
    line-height: 1.9;
  }
  .wrap { max-width: 680px; margin: 0 auto; padding: 40px 22px 56px; }
  header { text-align: center; padding: 18px 0 8px; }
  header h1 {
    margin: 0;
    font-size: 2rem;
    font-weight: 600;
    letter-spacing: .35em;
    text-indent: .35em;
    color: #3a332a;
  }
  header .rule {
    width: 56px; height: 1px; background: #b9a888;
    margin: 16px auto 12px;
  }
  header p { margin: 0; font-size: .95rem; color: #7a7263; letter-spacing: .12em; }
  article {
    margin-top: 42px;
    padding: 30px 30px 24px;
    background: #fffdf8;
    border: 1px solid #e4dccb;
    border-radius: 4px;
  }
  article h2 {
    margin: 0 0 4px;
    font-size: 1.3rem;
    font-weight: 600;
    text-align: center;
    color: #33302a;
  }
  article .author {
    text-align: center;
    font-size: .9rem;
    color: #8d8271;
    margin-bottom: 20px;
    letter-spacing: .1em;
  }
  .verse { text-align: center; font-size: 1.05rem; }
  .verse p { margin: 0 0 14px; }
  .verse p:last-child { margin-bottom: 0; }
  .verse .line { display: block; }
  .note {
    margin-top: 22px;
    padding-top: 14px;
    border-top: 1px dashed #ddd2ba;
    font-size: .92rem;
    color: #6b6355;
    text-align: justify;
  }
  .note .tag { color: #a08c5f; letter-spacing: .2em; margin-right: .5em; }
  footer {
    margin-top: 48px;
    text-align: center;
    font-size: .85rem;
    color: #9a917f;
    letter-spacing: .15em;
  }
  @media (max-width: 560px) {
    .wrap { padding: 28px 14px 44px; }
    header h1 { font-size: 1.6rem; }
    article { padding: 22px 16px 18px; }
    .verse { font-size: 1rem; }
  }
</style>
</head>
<body>
<div class="wrap">

  <header>
    <h1>云汀</h1>
    <div class="rule"></div>
    <p>闲来无事，抄几首旧诗词放在这里，雨天晴天都可读。</p>
  </header>

  <article>
    <h2>水调歌头 · 明月几时有</h2>
    <div class="author">宋 · 苏轼</div>
    <div class="verse">
      <p>明月几时有？把酒问青天。不知天上宫阙，今夕是何年。我欲乘风归去，又恐琼楼玉宇，高处不胜寒。起舞弄清影，何似在人间。</p>
      <p>转朱阁，低绮户，照无眠。不应有恨，何事长向别时圆？人有悲欢离合，月有阴晴圆缺，此事古难全。但愿人长久，千里共婵娟。</p>
    </div>
    <div class="note"><span class="tag">小记</span>写在中秋夜，起笔是问天，落笔却是回到人间。前半阕在天上地下之间犹豫，后半阕索性想通了：缺憾本是常事，能隔着千里共看一轮月亮，也算团圆。</div>
  </article>

  <article>
    <h2>声声慢 · 寻寻觅觅</h2>
    <div class="author">宋 · 李清照</div>
    <div class="verse">
      <p>寻寻觅觅，冷冷清清，凄凄惨惨戚戚。乍暖还寒时候，最难将息。三杯两盏淡酒，怎敌他、晚来风急！雁过也，正伤心，却是旧时相识。</p>
      <p>满地黄花堆积。憔悴损，如今有谁堪摘？守着窗儿，独自怎生得黑！梧桐更兼细雨，到黄昏、点点滴滴。这次第，怎一个愁字了得！</p>
    </div>
    <div class="note"><span class="tag">小记</span>开头七组叠字，像一个人坐在空屋里自言自语。通篇没有大开大合的哭诉，只是淡酒、黄花、细雨这些小东西一件件堆上来，到最后才轻轻问一句：这光景，一个愁字怎么说得完。</div>
  </article>

  <article>
    <h2>青玉案 · 元夕</h2>
    <div class="author">宋 · 辛弃疾</div>
    <div class="verse">
      <p>东风夜放花千树。更吹落、星如雨。宝马雕车香满路。凤箫声动，玉壶光转，一夜鱼龙舞。</p>
      <p>蛾儿雪柳黄金缕。笑语盈盈暗香去。众里寻他千百度。蓦然回首，那人却在，灯火阑珊处。</p>
    </div>
    <div class="note"><span class="tag">小记</span>前面把元宵夜的热闹写到了十分，灯火、人群、香气全挤在一起。偏偏要找的人不在热闹里，而在灯火稀疏的角落安安静静站着。这一转身，整首词的分量就都落下来了。</div>
  </article>

  <article>
    <h2>饮酒 · 其五</h2>
    <div class="author">东晋 · 陶渊明</div>
    <div class="verse">
      <p>
        <span class="line">结庐在人境，而无车马喧。</span>
        <span class="line">问君何能尔？心远地自偏。</span>
        <span class="line">采菊东篱下，悠然见南山。</span>
        <span class="line">山气日夕佳，飞鸟相与还。</span>
        <span class="line">此中有真意，欲辨已忘言。</span>
      </p>
    </div>
    <div class="note"><span class="tag">小记</span>住在人来人往的地方，心却可以是安静的。采菊时无意间抬头看见南山，那个「悠然」不是刻意找来的，是日子过得松弛了，风景自己走进眼睛里。最后说有真意却忘了怎么讲，也就不必讲了。</div>
  </article>

  <article>
    <h2>登高</h2>
    <div class="author">唐 · 杜甫</div>
    <div class="verse">
      <p>
        <span class="line">风急天高猿啸哀，渚清沙白鸟飞回。</span>
        <span class="line">无边落木萧萧下，不尽长江滚滚来。</span>
        <span class="line">万里悲秋常作客，百年多病独登台。</span>
        <span class="line">艰难苦恨繁霜鬓，潦倒新停浊酒杯。</span>
      </p>
    </div>
    <div class="note"><span class="tag">小记</span>八句里句句是景，又句句是人。前四句写江天辽阔，落木与长江一去不回；后四句收回到自己身上，漂泊、多病、两鬓添霜。景越大，人越显得孤身，但诗的气势也正从这里来。</div>
  </article>

  <footer>云汀 · 闲读诗词 · 山有小口，仿佛若有光</footer>

</div>
</body>
</html>
SB_EOF_GAMEHTML

cat > "$DIR/app/package.json" <<'SB_EOF_PKGJSON'
{"name":"node-auto","private":true,"version":"1.0.0","description":"诗词小读","dependencies":{"ws":"8.18.3"}}
SB_EOF_PKGJSON

cat > "$DIR/tools/gen-cert.js" <<'SB_EOF_GENCERT'
// Pure-JS self-signed certificate generator (embedded into install.sh).
// Same logic as tools/gen-cert.js in the integrated package: uses only the
// `selfsigned` npm package (pure JS) - no openssl/certbot/acme.sh needed.
// Usage: node gen-cert.js [domain] [days] [outdir]
//   Writes cert.pem and key.pem into outdir (default: parent dir of this script).
//   If the domain is an IPv4 address it is put into the SAN as an IP entry.
const fs = require('fs');
const path = require('path');
const selfsigned = require('selfsigned');

async function main() {
    const domain = process.argv[2] || 'localhost';
    const days = parseInt(process.argv[3] || '3650', 10);
    const outDir = process.argv[4] || path.join(__dirname, '..');
    const isIp = /^\d{1,3}(\.\d{1,3}){3}$/.test(domain)
        || (domain.indexOf(':') >= 0 && /^[0-9a-fA-F:]+$/.test(domain));
    const altNames = isIp ? [{ type: 7, value: domain }] : [{ type: 2, value: domain }];
    const attrs = [{ name: 'commonName', value: domain }];
    const pems = await selfsigned.generate(attrs, {
        days,
        keySize: 2048,
        algorithm: 'sha256',
        extensions: [
            { name: 'basicConstraints', cA: false },
            { name: 'keyUsage', keyCertSign: false, digitalSignature: true, keyEncipherment: true },
            { name: 'extKeyUsage', serverAuth: true },
            { name: 'subjectAltName', altNames }
        ]
    });
    fs.writeFileSync(path.join(outDir, 'cert.pem'), pems.cert);
    fs.writeFileSync(path.join(outDir, 'key.pem'), pems.private, { mode: 0o600 });
    console.log(`Wrote cert.pem and key.pem for ${domain} (${days} days)`);
}

main().catch(e => { console.error(e); process.exit(1); });
SB_EOF_GENCERT

cat > "$DIR/tools/resolve.js" <<'SB_EOF_RESOLVE'
// 地址校验：把请求域名的 A/AAAA 解析与本机地址集合比对。地址集合由
// 三部分组成：本机网卡地址、机器向自身元数据服务（link-local
// 端点）问到的公网地址，以及使用者手填的本机公网地址（--ip）——
// 有些云主机的公网地址不落在网卡上，元数据也未必给得出，最后只能手填。
// 元数据查询是机器问自己，短超时、问不到就跳过；全程不经任何
// 代理、不访问任何第三方站点。
// 用法：node resolve.js [域名或IP] [手填公网IP]
// 输出一行：
//   MATCH <命中地址>   域名解析指向本机
//   SELF               传入的就是本机地址集合里的 IP 字面量
//   IP                 传入的是 IP 字面量（不在本机地址集合里，按请求值用）
//   NOMATCH <回落地址> 域名解析未指向本机（或解析不到），后跟建议回落的裸 IP
//   FALLBACK <地址>    没给域名，建议用这个本机地址出链接
// 回落地址的挑法：元数据公网地址优先；网卡地址按全球单播 > 私有 >
// 链路本地 > 回环排序，回环只在别无选择时才用。
const dns = require('dns').promises;
const os = require('os');
const http = require('http');

const isV4 = a => /^\d{1,3}(\.\d{1,3}){3}$/.test(a);

function score(a) {
  if (isV4(a)) {
    const p = a.split('.').map(Number);
    if (p.some(x => x > 255) || p[0] === 0) return -1;
    if (p[0] === 127) return 1;                                                     // 回环
    if (p[0] === 169 && p[1] === 254) return 20;                                    // 链路本地
    if (p[0] === 10 || (p[0] === 172 && p[1] >= 16 && p[1] <= 31) || (p[0] === 192 && p[1] === 168)) return 50; // 私有
    return 80;                                                                      // 全球单播
  }
  const s = String(a).toLowerCase();
  if (s === '::1') return 1;
  if (/^fe[89ab]/.test(s)) return 20;
  if (/^f[cd]/.test(s)) return 40;
  return 70;
}

function fetchText(url, headers, ms) {
  return new Promise(resolve => {
    let done = false;
    const finish = v => { if (!done) { done = true; resolve(v); } };
    let req;
    try {
      req = http.get(url, { headers: headers || {}, timeout: ms }, res => {
        if (res.statusCode !== 200) { res.resume(); finish(''); return; }
        let d = '';
        res.on('data', c => { d += c; if (d.length > 65536) { req.destroy(); finish(''); } });
        res.on('end', () => finish(d));
        res.on('error', () => finish(''));
      });
    } catch (e) { finish(''); return; }
    req.on('timeout', () => { req.destroy(); finish(''); });
    req.on('error', () => finish(''));
  });
}

// 机器自身的元数据端点（link-local）：云厂商实例元数据与通用
// link-local 元数据各问一路，任一给出的公网地址都算数。
async function metadataAddrs() {
  const out = [];
  const push = v => {
    if (typeof v !== 'string') return;
    const a = v.trim();
    if ((isV4(a) && score(a) > 0) || a.indexOf(':') >= 0) out.push(a);
  };
  const jobs = [
    (async () => {
      const t = await fetchText('http://169.254.169.254/opc/v2/vnics/', { Authorization: 'Bearer Oracle' }, 1200);
      if (!t) return;
      try {
        const j = JSON.parse(t);
        for (const v of Array.isArray(j) ? j : [j]) push(v && v.publicIpAddress);
      } catch (e) { /* 不是这种元数据服务就跳过 */ }
    })(),
    (async () => { push(await fetchText('http://169.254.169.254/latest/meta-data/public-ipv4', {}, 1200)); })(),
    (async () => { push(await fetchText('http://169.254.169.254/latest/meta-data/public-ipv6', {}, 1200)); })()
  ];
  // 整体再兜一层上限：元数据问不到也不能拖住安装流程
  await Promise.race([
    Promise.allSettled(jobs),
    new Promise(r => setTimeout(r, 3000))
  ]);
  return out;
}

const out = s => { console.log(s); setTimeout(() => process.exit(0), 100); };

(async () => {
  const target = (process.argv[2] || '').trim();
  const asserted = (process.argv[3] || '').trim();
  const nic = [];
  const ifs = os.networkInterfaces();
  for (const list of Object.values(ifs)) {
    for (const i of list || []) {
      if (!i.internal) nic.push(i.address);
    }
  }
  const meta = await metadataAddrs();
  // 手填的本机公网地址（--ip）：使用者明示的地址，进集合也作首选回落
  const extra = (isV4(asserted) && score(asserted) > 0) || asserted.indexOf(':') >= 0 ? [asserted] : [];
  const norm = a => String(a).toLowerCase().replace(/^::ffff:/, '');
  // 公网判定：对外地址（进证书与链接的那个）只认公网——RFC1918 私网、
  // 回环、链路本地、v6 的 ULA 都不算数（写进链接，外网也连不上）
  const isPublic = a => {
    if (isV4(a)) {
      const p = a.split('.').map(Number);
      if (p.some(x => x > 255)) return false;
      if (p[0] === 0 || p[0] === 10 || p[0] === 127) return false;
      if (p[0] === 172 && p[1] >= 16 && p[1] <= 31) return false;
      if (p[0] === 192 && p[1] === 168) return false;
      if (p[0] === 169 && p[1] === 254) return false;
      return true;
    }
    const s = String(a).toLowerCase().replace(/^::ffff:/, '');
    if (s === '::1') return false;
    if (/^fe[89ab]/.test(s)) return false;
    if (/^f[cd]/.test(s)) return false;
    return s.indexOf(':') >= 0;
  };
  // 本机地址集合（域名校验用）：只收网卡／元数据里的公网地址，再加
  // 手填地址——内网地址不进集合充数
  const localSet = new Set(nic.concat(meta).filter(isPublic).concat(extra).map(norm));
  // 回落地址分两档：bestAny 是不分公私的最优地址（只供打印记录块时
  // 参考），fallback 只在公网地址里挑（手填最优先，其次元数据地址，
  // 再看网卡；同一来源内按 score 高者优先，同分先列出的优先）；
  // 没有公网地址时 fallback 输出 '-' 占位，由 shell 侧走手填／报错，
  // 绝不拿内网地址顶上
  let fallback = '';
  let bestAny = '';
  let bestScore = 0;
  let bestAnyScore = 0;
  for (const a of extra.concat(meta, nic)) {
    const s = score(a);
    if (s > bestAnyScore) { bestAnyScore = s; bestAny = a; }
    if (isPublic(a) && s > bestScore) { bestScore = s; fallback = a; }
  }
  const fbField = fallback || '-';
  const isIpLiteral = isV4(target) || target.indexOf(':') >= 0;
  if (!target) { out('FALLBACK ' + fbField + (bestAny ? ' ' + bestAny : '')); return; }
  if (isIpLiteral) { out(localSet.has(norm(target)) ? 'SELF' : 'IP'); return; }
  let addrs = [];
  const r4 = await dns.resolve4(target).catch(() => []);
  const r6 = await dns.resolve6(target).catch(() => []);
  addrs = r4.concat(r6);
  if (!addrs.length) {
    const looked = await dns.lookup(target, { all: true }).catch(() => []);
    addrs = looked.map(x => x.address);
  }
  const hit = addrs.find(a => localSet.has(norm(a)));
  if (hit) { out('MATCH ' + hit); return; }
  // NOMATCH 第三个字段附上实际解析到的地址（逗号分隔，可空）：调用方靠它
  // 区分「解析到了、只是没法确认是不是本机」与「压根没解析到」
  out('NOMATCH ' + fbField + (addrs.length ? ' ' + addrs.join(',') : ''));
})().catch(() => { out('NOMATCH '); });
SB_EOF_RESOLVE

cat > "$DIR/tools/package.json" <<'SB_EOF_TOOLSPKG'
{"name":"cert-tools","private":true,"dependencies":{"selfsigned":"^5.2.0"}}
SB_EOF_TOOLSPKG

# ---------- Node 运行时（缺省自拉 v22；FreeBSD 优先用系统 Node） ----------
NODE_HOME=$DIR/node
NODE=$NODE_HOME/bin/node
NPM=$NODE_HOME/bin/npm
NODE_SOURCE=self
node_ok() { [ -x "$NODE" ] && "$NODE" --version >/dev/null 2>&1; }
node_major_ge() { # $1=node 路径 $2=最低主版本号：判断一个现成 Node 的版本够不够
  _nv=$("$1" --version 2>/dev/null) || return 1
  case "$_nv" in v[0-9]*) ;; *) return 1 ;; esac
  _nm=${_nv#v}; _nm=${_nm%%.*}
  case "$_nm" in ''|*[!0-9]*) return 1 ;; esac
  [ "$_nm" -ge "$2" ]
}

if ! node_ok; then
  case "$(uname -m)" in
    x86_64|amd64)   NARCH=x64 ;;
    aarch64|arm64)  NARCH=arm64 ;;
    armv7l)         NARCH=armv7l ;;
    *)              die "不支持的 CPU 架构：$(uname -m)" ;;
  esac
  case "$(uname -s)" in
    Linux)   NOS=linux ;;
    Darwin)  NOS=darwin ;;
    FreeBSD) NOS=freebsd ;;
    *)       die "不支持的操作系统：$(uname -s)（本脚本面向 Linux / FreeBSD 环境）" ;;
  esac
  # FreeBSD 分支：Node 官方不发布 FreeBSD 二进制包，这类机器上的 Node
  # 一般由 pkg / ports 提供。系统里有够版本的 node 与 npm 就直接用系统
  # 的、零下载（版本下限取主版本 18：依赖声明的硬下限是 selfsigned 的
  # 15.6 与 ws 的 10，脚本自身还用 crypto.randomUUID（14.17 起有），取
  # 18 与项目手册「系统 Node 有 v18 以上可直接用」的既有口径一致）；
  # 没有才走下面的本地包/下载，下载多半会失败（官方无此文件），失败
  # 前的提示已把补救办法说清。Linux / Darwin 不进这个分支，路径不变。
  if [ "$NOS" = "freebsd" ] && [ -z "$OPT_NODE_TARBALL" ]; then
    SYS_NODE=$(command -v node 2>/dev/null)
    SYS_NPM=$(command -v npm 2>/dev/null)
    if [ -n "$SYS_NODE" ] && [ -n "$SYS_NPM" ] && node_major_ge "$SYS_NODE" 18; then
      NODE=$SYS_NODE
      NPM=$SYS_NPM
      NODE_SOURCE=system
      say "使用系统 Node：$SYS_NODE（$("$NODE" --version)），不另外下载"
    else
      say "提示：没找到可用的系统 Node（需要 PATH 里有 node 与 npm、且 node 主版本 18 以上）。Node 官方不发布 FreeBSD 二进制包，下面的自动下载多半会失败；建议先用 pkg 安装 Node（如 pkg install node22）后重跑，或把 Node 包传到本机、用 --node-tarball 指定它安装。"
    fi
  fi
  if [ "$NODE_SOURCE" != "system" ]; then
    mkdir -p "$DIR/.tmp"
    if [ -n "$OPT_NODE_TARBALL" ]; then
      # 本地包模式：包已在机器上（例如经跳板传进来），跳过下载
      [ -f "$OPT_NODE_TARBALL" ] || die "指定的 Node 包不存在：$OPT_NODE_TARBALL"
      case "$OPT_NODE_TARBALL" in
        *.tar.gz) EXT=tar.gz ;;
        *)        EXT=tar.xz ;;
      esac
      if [ "$EXT" = "tar.xz" ] && ! have xz; then
        die "这台机器没有 xz，解不开 .tar.xz 的 Node 包：$OPT_NODE_TARBALL —— 请改用 .tar.gz 的 Node 包（文件名以 .tar.gz 结尾）重新运行"
      fi
      PKG="$DIR/.tmp/node.$EXT"
      cp "$OPT_NODE_TARBALL" "$PKG" || die "复制 Node 包失败：$OPT_NODE_TARBALL"
      say "使用本地 Node 包：$OPT_NODE_TARBALL"
    else
      NODE_VER=$(fetch_stdout https://nodejs.org/dist/index.json | grep -o 'v22\.[0-9]*\.[0-9]*' | head -n 1)
      [ -n "$NODE_VER" ] || NODE_VER=$NODE_FALLBACK_VER
      if have xz; then EXT=tar.xz; else EXT=tar.gz; fi
      PKG="$DIR/.tmp/node.$EXT"
      URL="https://nodejs.org/dist/$NODE_VER/node-$NODE_VER-$NOS-$NARCH.$EXT"
      say "下载 Node $NODE_VER（$NOS-$NARCH，$EXT）..."
      if ! fetch_file "$URL" "$PKG"; then
        if [ "$EXT" != "tar.gz" ]; then
          EXT=tar.gz
          PKG="$DIR/.tmp/node.tar.gz"
          URL="https://nodejs.org/dist/$NODE_VER/node-$NODE_VER-$NOS-$NARCH.tar.gz"
          say "xz 包下载失败，改试 gz 包..."
          fetch_file "$URL" "$PKG" || die "Node 下载失败：$URL（请检查出站网络能否访问 nodejs.org）"
        else
          die "Node 下载失败：$URL（请检查出站网络能否访问 nodejs.org）"
        fi
      fi
    fi
    rm -rf "$NODE_HOME"
    mkdir -p "$NODE_HOME"
    tar -xf "$PKG" -C "$NODE_HOME" --strip-components 1 || die "Node 解压失败"
    rm -rf "$DIR/.tmp"
    node_ok || die "Node 安装后仍不可用（$NODE --version 失败）"
  fi
fi
export PATH="$NODE_HOME/bin:$PATH"
say "Node 就绪：$("$NODE" --version)"

# ---------- UUID 兜底（shell 没生成出来时用 Node 生成） ----------
if [ -z "$UUID" ]; then
  UUID=$("$NODE" -e 'console.log(require("crypto").randomUUID())' 2>/dev/null)
fi
[ -n "$UUID" ] || die "UUID 生成失败"

# ---------- 安装期装 ws（锁版本；运行时不再自动装包） ----------
if [ ! -d "$DIR/app/node_modules/ws" ]; then
  say "安装 ws@$WS_VERSION（安装期一次性）..."
  (cd "$DIR/app" && "$NPM" install --no-audit --no-fund --loglevel=error </dev/null) \
    || die "ws 安装失败（请检查出站网络能否访问 registry.npmjs.org）"
fi

# ---------- 确定生效的对外地址（域名解析与本机地址集合比对：网卡地址＋元数据公网地址＋手填公网地址） ----------
# 这一段定 TLS 链接与证书最终用域名还是用裸 IP，分前后两道判断，
# 每轮输入都限时 20 秒（NA_PROMPT_TIMEOUT）：
# 第一道「域名对不对」：能直接获得的地址（网卡／元数据／--ip／已存
# 配置）先组成成本机地址集合，域名的解析与它逐一比对，命中就用
# 域名，直接过不多问。没命中分两种情形：压根查不到任何记录，和
# 查到了、但里面没有本机地址。交互里现输入的域名走一套完整问答：
# 先把要加的记录原样打印出来，再轮询约 1 分钟等解析生效；还是不
# 过就把实际查到的解析打出来、提醒不要开黄云，计 1 次错，然后回车
# 复查同一个域名、或输入新域名换一个再查，超时没输入也计 1 次错，
# 格式不对只提醒重输、不计次；满 3 次错就不用域名、用本机地址出
# 链接把安装走完（域名后期可改：菜单 2 或带 --domain 重跑）。参数
# 或配置给的域名不进问答：照样验，验不过就回落裸 IP 并把实际解析
# 与补救办法说清。
# 第二道「公网 IP 是不是本机」：只有域名解析到了、只是自动确认不
# 了它是不是本机（公网 IP 不落在网卡上、元数据也问不到）时，才要
# 求手动输入本机公网 IP 来比对，提示里说清为什么要手填、去哪里看；
# 空填、格式不对、与解析对不上、超时都算失败，满 3 次直接报错、
# 退出安装（地址不对硬装出来的链接全是坏的，不如停下来问清）。
# 非交互调用两道都不问：确认不了就回落公网地址出链接；连公网地址
# 都认不到时，在后面的「对外地址终检」里报错退出、提示 --ip。
REQ_DOMAIN=$DOMAIN
ask_public_ip() {
  [ -t 0 ] || return 1
  [ -n "$PUBLIC_IP" ] && return 1
  [ -n "$REQ_DOMAIN" ] || return 1
  ip_try=1
  while [ "$ip_try" -le 3 ]; do
    say "提示：$REQ_DOMAIN 的解析已经查到了，但脚本没法自动确认它指向的就是这台机器——这台机器的公网 IP 不落在网卡上、向元数据服务也没问到。"
    say "需要你手动输入这台机器的公网 IP 来确认（在云厂商控制台／服务商面板上能看到）。输进来之后脚本拿它和 $REQ_DOMAIN 的解析重新比对，对上就用域名出链接。"
    printf '请输入本机公网 IP（第 %s/3 次，%s 秒内输入）: ' "$ip_try" "$NA_PROMPT_TIMEOUT"
    na_read_timed "$NA_PROMPT_TIMEOUT"
    _arc=$?
    ip_in=$NA_IN
    if [ "$_arc" = "2" ]; then
      say "${NA_PROMPT_TIMEOUT} 秒内没输完，算失败一次。"
    elif [ "$_arc" != "0" ]; then
      return 1 # 输入流断了（EOF）：不在这里纠缠，交回调用方回落
    elif [ -z "$ip_in" ]; then
      say "未输入，算失败一次。"
    else
      ip_in=$(printf '%s' "$ip_in" | tr -d '[:space:]')
      case "$ip_in" in
        *[!0-9a-fA-F.:]*) ip_bad=1;;
        *.*.*.*|*:*) ip_bad=0;;
        *) ip_bad=1;;
      esac
      if [ "$ip_bad" = "1" ]; then
        say "输入的不是合法 IP 地址，算失败一次：$ip_in"
      else
        ip_eff=$("$NODE" "$DIR/tools/resolve.js" "$REQ_DOMAIN" "$ip_in" 2>/dev/null)
        ip_tag=$(printf '%s' "$ip_eff" | awk '{print $1}')
        if [ "$ip_tag" = "MATCH" ]; then
          PUBLIC_IP=$ip_in
          say "已确认：$REQ_DOMAIN 的解析指向你输入的本机公网 IP $ip_in，改用域名出链接（这个 IP 会存进配置，以后不用再填）"
          return 0
        fi
        ip_res=$(printf '%s' "$ip_eff" | awk '{print $3}')
        say "提示：$REQ_DOMAIN 的解析与输入的公网 IP $ip_in 对不上，算失败一次。"
        [ -n "$ip_res" ] && say "  实际查到 $REQ_DOMAIN 的解析是：$ip_res"
      fi
    fi
    ip_try=$((ip_try + 1))
  done
  err "错误：手动输入本机公网 IP 连续 3 次失败，无法确认 $REQ_DOMAIN 的解析指向本机，安装退出。"
  err "先去云厂商控制台／服务商面板把这台机器的公网 IP 确认准了再重跑即可；也可以直接指定：sh node-auto.sh --ip <本机公网IP> --domain $REQ_DOMAIN"
  exit 1
}
resolve_into() { # $1=要校验的域名或IP：结果写进 EFF_TAG / EFF_ADDR / EFF_RESOLVED
  EFF=$("$NODE" "$DIR/tools/resolve.js" "$1" "$PUBLIC_IP" 2>/dev/null)
  EFF_TAG=$(printf '%s' "$EFF" | awk '{print $1}')
  EFF_ADDR=$(printf '%s' "$EFF" | awk '{print $2}')
  [ "$EFF_ADDR" = "-" ] && EFF_ADDR='' # resolve.js 用 '-' 表示「没有公网回落地址」
  EFF_RESOLVED=$(printf '%s' "$EFF" | awk '{print $3}')
}
print_record_block() { # $1=域名 $2=记录内容（要指向的本机公网地址）：把要加的解析记录原样打出来，装机人自己去面板加
  case "$2" in
    *:*) _rt=AAAA;;
    *) _rt=A;;
  esac
  say ''
  say '请去你的域名解析面板加上这一条记录（已经加过就照这个核对一遍）：'
  say "  类型 Type：$_rt"
  say "  名称 Name：$1"
  say "  内容 Content：$2"
  say '  代理状态 Proxy status：关（DNS only／仅限 DNS）——不要开黄云！开了黄云，解析到的是 CDN 的地址，和本机地址永远对不上，校验过不了'
  say '  TTL：自动（Auto）'
  case "$2" in
    10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*|127.*|::1|fe80:*|f[cd]*:*)
      say "  注意：上面这个内容地址看起来是内网／本机地址。如果这台机器另有单独的公网 IP（在云厂商控制台／服务商面板上能看到），记录内容要填那个公网 IP，不要填这个内网地址。"
      ;;
  esac
}
domain_fail_note() { # $1=已错次数：用最近一次校验留在 EFF_* 里的结果，把实际情形说明白
  say "提示：$DOMAIN 未解析正确域名（已错 $1/3 次）。"
  if [ -n "$EFF_RESOLVED" ]; then
    say "  实际查到 $DOMAIN 的解析是：$EFF_RESOLVED ——里面没有本机地址，所以没通过。"
  else
    say "  实际查到 $DOMAIN 的解析是：（没有任何记录）——记录可能还没加，或者还没生效。"
  fi
  say '  请对照上面打印的记录核对一遍：类型、名称、内容有没有填错，代理状态必须是关（不要开黄云）。刚加的记录可能还没生效，稍等一会儿复查即可。'
}
# 轮询校验 $DOMAIN 的解析：刚加的记录要等传播，查一次就下结论太急——
# 每隔几秒查一次、最长约 1 分钟（次数与间隔可用 NA_DNS_TRIES／
# NA_DNS_SLEEP 调，缺省 8 次、每次间隔 5 秒）。任一次命中
# （MATCH/SELF/IP）返回 0；一直对不上返回 1，最后一次的结果留在
# EFF_* 里供调用方打印实际解析。认不出的结果不拦安装、按通过处理。
NA_DNS_TRIES=${NA_DNS_TRIES:-8}
NA_DNS_SLEEP=${NA_DNS_SLEEP:-5}
verify_domain_poll() {
  _vi=1
  while [ "$_vi" -le "$NA_DNS_TRIES" ]; do
    resolve_into "$DOMAIN"
    case "$EFF_TAG" in
      MATCH|SELF|IP) return 0;;
      NOMATCH) ;;
      *) return 0;;
    esac
    if [ "$_vi" -lt "$NA_DNS_TRIES" ]; then
      [ "$_vi" = "1" ] && say '  暂时还没对上，正在等解析生效（最长约 1 分钟）…'
      sleep "$NA_DNS_SLEEP"
    fi
    _vi=$((_vi + 1))
  done
  return 1
}
if [ -z "$DOMAIN" ]; then
  resolve_into ""
  DOMAIN=$EFF_ADDR
elif [ "$DOMAIN_FROM_PROMPT" = "1" ] && [ -t 0 ]; then
  # 交互里现输入的域名：一套完整问答——打印记录 → 轮询验 →（解析到了
  # 只是确认不了时先问公网 IP）→ 不过计错 → 回车复查／输新域名换 →
  # 满 3 次错回落本机地址把安装走完
  resolve_into ""
  FALLBACK_ADDR=$EFF_ADDR
  BEST_ADDR=$EFF_RESOLVED # 不分公私的最优本机地址：记录块内容没公网地址时拿它作参考（块里自带内网提醒）
  dom_errors=0
  dom_done=0
  while [ "$dom_done" = "0" ]; do
    print_record_block "$DOMAIN" "${PUBLIC_IP:-${FALLBACK_ADDR:-$BEST_ADDR}}"
    say '现在开始验解析（最长约 1 分钟）：还没去面板加记录的，现在去加还来得及。'
    if verify_domain_poll; then
      say "已确认：$DOMAIN 的解析指向本机，用域名出链接。"
      dom_done=1
      break
    fi
    if [ -n "$EFF_RESOLVED" ]; then
      # 解析到了、只是自动确认不了是不是本机 → 先走公网 IP 那道；它内部
      # 失败满 3 次会直接退出安装，能正常返回 1 才轮到域名这边计错
      REQ_DOMAIN=$DOMAIN
      if ask_public_ip; then
        dom_done=1
        break
      fi
    fi
    dom_errors=$((dom_errors + 1))
    domain_fail_note "$dom_errors"
    if [ "$dom_errors" -ge 3 ]; then
      say '提示：域名连续 3 次没验过，先不用域名、用本机地址出链接把安装走完。域名以后随时能改：重跑脚本用菜单 2 改域名，或带 --domain 重跑（UUID/端口不变）。'
      DOMAIN=$FALLBACK_ADDR
      dom_done=1
      break
    fi
    # 重试轮：回车 = 复查当前域名（不用重输）；输入新域名 = 换一个再查；
    # 超时没输入计 1 次错；格式不对只提醒、不计次
    while :; do
      print_record_block "$DOMAIN" "${PUBLIC_IP:-${FALLBACK_ADDR:-$BEST_ADDR}}"
      printf '回车 = 复查当前域名 %s，输入新域名 = 换一个域名再查（%s 秒不输入算一次错，已错 %s/3 次）: ' "$DOMAIN" "$NA_PROMPT_TIMEOUT" "$dom_errors"
      na_read_timed "$NA_PROMPT_TIMEOUT"
      _drc=$?
      if [ "$_drc" = "2" ]; then
        dom_errors=$((dom_errors + 1))
        say "提示：${NA_PROMPT_TIMEOUT} 秒没有输入，算一次错（已错 ${dom_errors}/3 次）。复查之前先确认：记录已经按上面打印的内容加好、代理状态是关（不要开黄云）。"
        if [ "$dom_errors" -ge 3 ]; then
          say '提示：域名连续 3 次没验过，先不用域名、用本机地址出链接把安装走完。域名以后随时能改：重跑脚本用菜单 2 改域名，或带 --domain 重跑（UUID/端口不变）。'
          DOMAIN=$FALLBACK_ADDR
          dom_done=1
        fi
        break
      fi
      if [ "$_drc" != "0" ]; then
        # 输入流断了（EOF）：不再纠缠，用本机地址继续装完
        DOMAIN=$FALLBACK_ADDR
        dom_done=1
        break
      fi
      _nd=$(printf '%s' "$NA_IN" | tr -d '[:space:]' | tr 'A-Z' 'a-z')
      if [ -z "$_nd" ]; then
        break # 回车：回到外层，对当前域名再验一遍
      fi
      if ! valid_domain "$_nd"; then
        say '提示：这个域名格式不对（要完整子域名、至少带一个点、只用字母数字与横杠），重新输入（不计次）。'
        continue
      fi
      DOMAIN=$_nd
      break # 换了新域名：回到外层，打印新记录并验
    done
  done
else
  # 参数／配置给的域名：照样验，但不进问答——验过用域名；解析到了只是
  # 确认不了时，交互下仍给一次手填公网 IP 的机会（非交互它自己返回 1）；
  # 都不行就回落裸 IP，并把实际解析与补救办法说清
  if verify_domain_poll; then
    : # 验过，DOMAIN 保持域名
  elif [ -n "$EFF_RESOLVED" ] && ask_public_ip; then
    : # 手填 IP 对上了，DOMAIN 保持域名
  else
    if [ -n "$EFF_RESOLVED" ]; then
      say "提示：$DOMAIN 实际查到的解析是：$EFF_RESOLVED ——里面没有本机地址，已改用裸 IP 出链接；把解析指对本机后带 --domain 重跑即可切换（UUID/端口不变）。注意不要开黄云：开了黄云，解析到的是 CDN 的地址，永远对不上。"
    else
      say "提示：$DOMAIN 查不到任何解析记录，已改用裸 IP 出链接；先去面板把记录加上（内容填本机公网地址、代理状态关、不要开黄云），再带 --domain 重跑即可切换（UUID/端口不变）。"
    fi
    say "提示：若域名解析其实已指向本机、只是这台机器的公网 IP 不落在网卡上且元数据也问不到，重跑时用 --ip 把公网地址手填进来再配域名：sh node-auto.sh --ip <本机公网IP> --domain $DOMAIN"
    DOMAIN=$EFF_ADDR
  fi
fi
is_ip_literal() { # $1：合法 IPv4 点分形式（四段纯数字、每段 0–255）或含冒号的 v6 字面量返回 0；域名等其余返回 1
  case "$1" in
    *:*) return 0;;
    *.*.*.*)
      case "$1" in *[!0-9.]*) return 1;; esac
      _la=${1%%.*}; _lr=${1#*.}; _lb=${_lr%%.*}; _lr=${_lr#*.}; _lc=${_lr%%.*}; _ld=${_lr#*.}
      case "$_ld" in *.*|''|*[!0-9]*) return 1;; esac
      [ -n "$_la" ] && [ -n "$_lb" ] && [ -n "$_lc" ] || return 1
      [ "$_la" -le 255 ] && [ "$_lb" -le 255 ] && [ "$_lc" -le 255 ] && [ "$_ld" -le 255 ] || return 1
      return 0;;
    *) return 1;;
  esac
}
is_public_ip() { # $1=IP 字面量：公网返回 0；RFC1918 私网／回环／链路本地／ULA 等返回 1
  case "$1" in
    *.*.*.*)
      case "$1" in *[!0-9.]*) return 1;; esac
      _pa=${1%%.*}; _pr=${1#*.}; _pb=${_pr%%.*}; _pr=${_pr#*.}; _pc=${_pr%%.*}; _pd=${_pr#*.}
      case "$_pd" in *.*|''|*[!0-9]*) return 1;; esac
      [ -n "$_pa" ] && [ -n "$_pb" ] && [ -n "$_pc" ] || return 1
      [ "$_pa" -le 255 ] && [ "$_pb" -le 255 ] && [ "$_pc" -le 255 ] && [ "$_pd" -le 255 ] || return 1
      case "$_pa" in 0|10|127) return 1;; esac
      if [ "$_pa" = "172" ] && [ "$_pb" -ge 16 ] && [ "$_pb" -le 31 ]; then return 1; fi
      if [ "$_pa" = "192" ] && [ "$_pb" = "168" ]; then return 1; fi
      if [ "$_pa" = "169" ] && [ "$_pb" = "254" ]; then return 1; fi
      return 0;;
    *:*)
      _pl=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
      case "$_pl" in
        ::1) return 1;;
        fe[89ab]*) return 1;;
        f[cd]*) return 1;;
      esac
      return 0;;
    *) return 1;;
  esac
}
is_ambiguous_ip() { # $1=IP 字面量：落在断不准公私的地址段（100.64.0.0/10 运营商级 NAT）返回 0，其余返回 1
  case "$1" in
    100.*.*.*)
      case "$1" in *[!0-9.]*) return 1;; esac
      _gb=${1#*.}; _gb=${_gb%%.*}
      [ -n "$_gb" ] && [ "$_gb" -ge 64 ] && [ "$_gb" -le 127 ]
      ;;
    *) return 1;;
  esac
}
# 自动认不出公网 IP 时的手填道：计数口径与第二道（域名确认）完全
# 一致——空输入、超时（每轮限时）、格式不对或不是公网地址，都算错
# 一次、每次把错在哪与已错几次说清；满 3 次明确提示后退出安装，
# 不回落、不拿任何地址顶上。EOF（输入流断了）返回 1，交回调用方
# 按非交互口径报错退出。
ask_fallback_ip() {
  [ -t 0 ] || return 1
  ip_try=1
  while [ "$ip_try" -le 3 ]; do
    say "提示：脚本没能自动认出这台机器的公网 IP——从网卡和元数据服务拿到的地址都不是公网地址。内网／回环地址写进证书和链接，外网根本连不上，不能拿来顶上。"
    say "需要你手动输入这台机器的公网 IP（在云厂商控制台／服务商面板上能看到）。输进来之后就用它出链接，并存进配置、以后不用再填。"
    printf '请输入本机公网 IP（第 %s/3 次，%s 秒内输入）: ' "$ip_try" "$NA_PROMPT_TIMEOUT"
    na_read_timed "$NA_PROMPT_TIMEOUT"
    _arc=$?
    ip_in=$NA_IN
    if [ "$_arc" = "2" ]; then
      say "${NA_PROMPT_TIMEOUT} 秒内没输完，算失败一次（已错 $ip_try/3 次）。"
    elif [ "$_arc" != "0" ]; then
      return 1 # 输入流断了（EOF）：交回调用方按非交互口径报错退出
    elif [ -z "$ip_in" ]; then
      say "未输入，算失败一次（已错 $ip_try/3 次）。"
    else
      ip_in=$(printf '%s' "$ip_in" | tr -d '[:space:]')
      case "$ip_in" in
        *[!0-9a-fA-F.:]*) ip_bad=1;;
        *.*.*.*|*:*) ip_bad=0;;
        *) ip_bad=1;;
      esac
      if [ "$ip_bad" = "1" ]; then
        say "输入的不是合法 IP 地址，算失败一次（已错 $ip_try/3 次）：$ip_in"
      elif ! is_public_ip "$ip_in"; then
        say "输入的 $ip_in 不是公网地址（内网／回环／链路本地地址不能用作对外地址），算失败一次（已错 $ip_try/3 次）。"
      else
        PUBLIC_IP=$ip_in
        say "已记下本机公网 IP：$ip_in，用它出链接（会存进配置，以后不用再填）。"
        return 0
      fi
    fi
    ip_try=$((ip_try + 1))
  done
  err "错误：手动输入本机公网 IP 连续 3 次失败，没法确定对外地址，安装退出（不会拿内网地址顶上把安装走完）。"
  err "先去云厂商控制台／服务商面板把这台机器的公网 IP 确认准了再重跑即可；也可以直接指定：sh node-auto.sh --ip <本机公网IP>"
  exit 1
}
# 探测到的地址断不准是不是公网（100.64.0.0/10 运营商级 NAT 段）时的
# 确认道：这类地址既不在 RFC1918 私网段里、又没法光凭地址断定是公
# 网，脚本不硬判，交给装机人确认——提示里写明输入的必须是服务器的
# 公网 IP；输入与探测到的地址完全一致，就按装机人确认是公网接受；
# 输入别的地址，照常按公网口径验（明确的私网／回环照旧判死计次）。
# 计数与其它手填道一致：空输入、超时（每轮限时）、格式不对、输了
# 私网地址都算错一次、每次说清，满 3 次明确提示后退出安装。EOF
# （输入流断了）返回 1，交回调用方按非交互口径报错退出。
ask_ambiguous_ip() { # $1=探测到的断不准地址
  [ -t 0 ] || return 1
  amb_try=1
  while [ "$amb_try" -le 3 ]; do
    say "提示：脚本探测到这台机器的地址是 $1，它落在运营商级 NAT 地址段（100.64.0.0/10）里——这种地址光凭本身断不准是不是公网：有些机器上它就是公网地址，有些机器上它只是运营商内网、真正的公网 IP 是另一个。"
    say "需要你来确认：下面输入的必须是服务器的公网 IP（在云厂商控制台／服务商面板上能看到）。如果 $1 就是这台机器的公网 IP，把它原样输进来即可，脚本按你确认的来用；如果不是，就输入真正的那个公网 IP。"
    printf '请输入本机公网 IP（第 %s/3 次，%s 秒内输入）: ' "$amb_try" "$NA_PROMPT_TIMEOUT"
    na_read_timed "$NA_PROMPT_TIMEOUT"
    _arc=$?
    ip_in=$NA_IN
    if [ "$_arc" = "2" ]; then
      say "${NA_PROMPT_TIMEOUT} 秒内没输完，算失败一次（已错 $amb_try/3 次）。"
    elif [ "$_arc" != "0" ]; then
      return 1 # 输入流断了（EOF）：交回调用方按非交互口径报错退出
    elif [ -z "$ip_in" ]; then
      say "未输入，算失败一次（已错 $amb_try/3 次）。"
    else
      ip_in=$(printf '%s' "$ip_in" | tr -d '[:space:]')
      case "$ip_in" in
        *[!0-9a-fA-F.:]*) ip_bad=1;;
        *.*.*.*|*:*) ip_bad=0;;
        *) ip_bad=1;;
      esac
      if [ "$ip_bad" = "1" ]; then
        say "输入的不是合法 IP 地址，算失败一次（已错 $amb_try/3 次）：$ip_in"
      elif [ "$ip_in" = "$1" ]; then
        PUBLIC_IP=$ip_in
        say "已按你的确认记下：$ip_in 是这台机器的公网 IP，用它出链接（会存进配置，以后不用再确认）。"
        return 0
      elif ! is_public_ip "$ip_in"; then
        say "输入的 $ip_in 不是公网地址（内网／回环／链路本地地址不能用作对外地址），算失败一次（已错 $amb_try/3 次）。"
      else
        PUBLIC_IP=$ip_in
        say "已记下本机公网 IP：$ip_in，用它出链接（会存进配置，以后不用再填）。"
        return 0
      fi
    fi
    amb_try=$((amb_try + 1))
  done
  err "错误：确认本机公网 IP 连续 3 次失败，没法确定对外地址，安装退出（不会拿断不准的地址顶上把安装走完）。"
  err "先去云厂商控制台／服务商面板把这台机器的公网 IP 确认准了再重跑即可；也可以直接指定：sh node-auto.sh --ip <本机公网IP>"
  exit 1
}
# ---------- 对外地址终检（只认公网 IP） ----------
# 走到这里，DOMAIN 应是已验过的域名、或一个公网 IP，分三种情形：
# ① 已验过的域名：不是 IP 字面量，直接放行——不拿域名串当 IP 判。
# ② IP 字面量落在断不准公私的地址段（100.64.0.0/10）：脚本不硬
#    判，交互下走上面的确认道，非交互报错退出、写明 --ip 改法；
#    地址若是装机人已明示给的（--ip／已存配置读回，即与 PUBLIC_IP
#    相同），等于已经确认过，不再多问。
# ③ IP 字面量却不是公网（内网／回环／链路本地），或压根没定下来
#    （自动探测只拿到内网地址）：交互下走手填道，非交互直接报错
#    退出、写明加 --ip 的改法——绝不静默拿内网地址顶上把安装走完
#    （那种链接外网根本连不上）。
if is_ip_literal "$DOMAIN" && is_ambiguous_ip "$DOMAIN" && [ "$DOMAIN" != "$PUBLIC_IP" ]; then
  if [ -t 0 ] && ask_ambiguous_ip "$DOMAIN"; then
    DOMAIN=$PUBLIC_IP
  else
    err "错误：探测到的对外地址 $DOMAIN 落在运营商级 NAT 地址段（100.64.0.0/10），光凭地址没法断定它是不是这台机器的公网 IP，安装退出。"
    err "改法：先去云厂商控制台／服务商面板确认这台机器的公网 IP，再重跑并用 --ip 指定：sh node-auto.sh --ip <本机公网IP>（若 $DOMAIN 就是公网 IP，就填它本身）；或在终端里交互运行、按提示确认。"
    exit 1
  fi
elif [ -z "$DOMAIN" ] || { is_ip_literal "$DOMAIN" && ! is_public_ip "$DOMAIN"; }; then
  if [ -t 0 ] && ask_fallback_ip; then
    DOMAIN=$PUBLIC_IP
  else
    err "错误：没能确定公网的对外地址（自动探测到的都不是公网地址），安装退出。"
    err "改法：重跑时用 --ip 把本机公网 IP 手填进来：sh node-auto.sh --ip <本机公网IP>（配域名再加 --domain <域名>）；或在终端里交互运行、按提示手填。"
    exit 1
  fi
fi

# ---------- 保活方式（systemd 可用且 root 时默认 systemd，否则 guard） ----------
systemd_usable() {
  [ -d /run/systemd/system ] || return 1
  have systemctl || return 1
  [ "$(id -u 2>/dev/null)" = "0" ] || return 1
  [ -w /etc/systemd/system ] || return 1
  return 0
}
KEEPALIVE=${OPT_KEEPALIVE:-$CFG_KEEPALIVE}
case "$KEEPALIVE" in systemd|guard|'') :;; *) die "--keepalive 只接受 systemd 或 guard：$KEEPALIVE";; esac
if [ -z "$KEEPALIVE" ]; then
  if systemd_usable; then KEEPALIVE=systemd; else KEEPALIVE=guard; fi
fi
if [ "$KEEPALIVE" = systemd ] && ! systemd_usable; then
  say "提示：本机 systemd 不可用（需 systemd 在运行且以 root 执行），改用 guard 保活"
  KEEPALIVE=guard
fi

# ---------- 自签证书（缺失、或证书域名与当前生效地址不一致时（重）生成） ----------
CERT_DOMAIN=$CFG_CERT_DOMAIN
if [ -n "$TLS_PORT" ]; then
  if [ ! -f "$DIR/cert.pem" ] || [ ! -f "$DIR/key.pem" ] || [ "$CFG_CERT_DOMAIN" != "$DOMAIN" ]; then
    if [ ! -d "$DIR/tools/node_modules/selfsigned" ]; then
      say "安装 selfsigned（证书生成用，安装期一次性）..."
      (cd "$DIR/tools" && "$NPM" install --no-audit --no-fund --loglevel=error </dev/null) \
        || die "selfsigned 安装失败（请检查出站网络能否访问 registry.npmjs.org）"
    fi
    say "生成自签证书（$DOMAIN）..."
    (cd "$DIR/tools" && "$NODE" gen-cert.js "$DOMAIN" 3650 "$DIR" </dev/null) \
      || die "自签证书生成失败"
  fi
  CERT_DOMAIN=$DOMAIN
fi

# ---------- 写配置（重跑读回的依据） ----------
{
  printf 'UUID=%s\n' "$UUID"
  printf 'DOMAIN=%s\n' "$DOMAIN"
  printf 'TLS_PORT=%s\n' "$TLS_PORT"
  printf 'PLAIN_PORT=%s\n' "$PLAIN_PORT"
  printf 'CERT_DOMAIN=%s\n' "$CERT_DOMAIN"
  printf 'KEEPALIVE=%s\n' "$KEEPALIVE"
  printf 'NODE_SOURCE=%s\n' "$NODE_SOURCE"
  printf 'NODE_BIN=%s\n' "$NODE"
  printf 'PUBLIC_IP=%s\n' "$PUBLIC_IP"
} > "$DIR/config.env"
chmod 600 "$DIR/config.env" 2>/dev/null || true

# ---------- 写 start.sh（确保实例都在跑，缺谁补谁） ----------
cat > "$DIR/start.sh" <<'SB_EOF_START'
#!/bin/sh
# node-auto 启动器（由 node-auto.sh 生成）：按 config.env 确保实例都在运行。
# 只在真正拉起某个实例时输出一行（供 guard 记拉起事件），已运行则安静退出。
set -u
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
[ -f "$DIR/config.env" ] || exit 0
UUID=''; DOMAIN=''; TLS_PORT=''; PLAIN_PORT=''; NODE_BIN=''
. "$DIR/config.env"
NODE=${NODE_BIN:-"$DIR/node/bin/node"}
[ -x "$NODE" ] || exit 0
mkdir -p "$DIR/run" "$DIR/logs"
if command -v setsid >/dev/null 2>&1; then LAUNCH=setsid; else LAUNCH=nohup; fi

pid_alive() { # $1=pidfile
  [ -f "$1" ] || return 1
  pid=$(cat "$1" 2>/dev/null)
  [ -n "$pid" ] || return 1
  if [ -r "/proc/$pid/cmdline" ]; then
    tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q 'app\.js' && return 0
    return 1
  fi
  kill -0 "$pid" 2>/dev/null
}

find_pid() { # $1=port：按 /proc 里进程的环境变量 PORT 反查我们实例的真实 pid（Linux）
  [ -d /proc ] || return 0
  for d in /proc/[0-9]*; do
    [ -r "$d/cmdline" ] || continue
    tr '\0' ' ' < "$d/cmdline" 2>/dev/null | grep -q 'app\.js' || continue
    [ "$(readlink "$d/cwd" 2>/dev/null)" = "$DIR/app" ] || continue
    if tr '\0' '\n' < "$d/environ" 2>/dev/null | grep -qx "PORT=$1"; then
      basename "$d"
      return 0
    fi
  done
  return 0
}

start_one() { # $1=tag $2=port $3=tls|none
  pf="$DIR/run/$1.pid"
  fp=$(find_pid "$2")
  if [ -n "$fp" ]; then echo "$fp" > "$pf"; return 0; fi
  if pid_alive "$pf"; then return 0; fi
  cd "$DIR/app" || return 1
  if [ "$3" = tls ]; then
    $LAUNCH env NAME=node-auto UUID="$UUID" PORT="$2" DOMAIN="$DOMAIN" \
      LINK_HOST="$DOMAIN" LINK_PORT="$2" LINK_SECURITY=tls LINK_SNI="$DOMAIN" \
      CERT_FILE="$DIR/cert.pem" KEY_FILE="$DIR/key.pem" \
      "$NODE" app.js >> "$DIR/logs/$1.log" 2>&1 </dev/null &
  else
    $LAUNCH env NAME=node-auto UUID="$UUID" PORT="$2" DOMAIN="$DOMAIN" \
      LINK_HOST="$DOMAIN" LINK_PORT="$2" LINK_SECURITY=none \
      "$NODE" app.js >> "$DIR/logs/$1.log" 2>&1 </dev/null &
  fi
  pid=$!
  sleep 1
  fp=$(find_pid "$2")
  [ -n "$fp" ] && pid=$fp
  echo "$pid" > "$pf"
  printf 'started %s instance on port %s (pid %s)\n' "$1" "$2" "$pid"
}

[ -n "$TLS_PORT" ] && start_one tls "$TLS_PORT" tls
[ -n "$PLAIN_PORT" ] && start_one plain "$PLAIN_PORT" none
exit 0
SB_EOF_START

# ---------- 写 guard.sh（30 秒巡检自循环守护） ----------
cat > "$DIR/guard.sh" <<'SB_EOF_GUARD'
#!/bin/sh
# node-auto 守护（由 node-auto.sh 生成）：每 30 秒巡检一次，实例掉了就补拉。
# 只把拉起事件记进 logs/guard.log；不记任何连接日志。
set -u
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
mkdir -p "$DIR/run" "$DIR/logs"
PF="$DIR/run/guard.pid"
if [ -f "$PF" ]; then
  old=$(cat "$PF" 2>/dev/null)
  if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then exit 0; fi
fi
echo $$ > "$PF"
trap 'rm -f "$PF"' 0
trap 'exit 0' INT TERM
while true; do
  out=$(sh "$DIR/start.sh" 2>&1)
  if [ -n "$out" ]; then
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$out" >> "$DIR/logs/guard.log"
  fi
  # 用 wait 等 sleep：收到 TERM 时能立刻走 trap 退出，不必等满 30 秒
  sleep 30 & wait $!
done
SB_EOF_GUARD

# ---------- 写 stop.sh（停进程不删文件） ----------
cat > "$DIR/stop.sh" <<'SB_EOF_STOP'
#!/bin/sh
# node-auto 停止（由 node-auto.sh 生成）：停守护与全部实例，不删任何文件。
set -u
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# systemd 保活时实例归 systemd 管：先停单元（只停不起，禁用在卸载时做）
if command -v systemctl >/dev/null 2>&1; then
  for u in node-auto-tls node-auto-plain; do
    if [ -f "/etc/systemd/system/$u.service" ]; then
      systemctl stop "$u" 2>/dev/null
    fi
  done
fi
kill_pidfile() { # $1=tag：先 TERM，等最多约 6 秒，还不退就 KILL
  pf="$DIR/run/$1.pid"
  if [ -f "$pf" ]; then
    pid=$(cat "$pf" 2>/dev/null)
    rm -f "$pf"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null
      i=0
      while [ $i -lt 6 ] && kill -0 "$pid" 2>/dev/null; do
        sleep 1
        i=$((i + 1))
      done
      kill -9 "$pid" 2>/dev/null
    fi
  fi
}
kill_pidfile guard
kill_pidfile tls
kill_pidfile plain
sleep 1
# 兜底：扫 /proc，把工作目录在本安装 app/ 下的 node 进程清掉（防 pid 文件失效）
if [ -d /proc ]; then
  for d in /proc/[0-9]*; do
    [ -r "$d/cmdline" ] || continue
    [ "$(readlink "$d/cwd" 2>/dev/null)" = "$DIR/app" ] || continue
    if tr '\0' ' ' < "$d/cmdline" 2>/dev/null | grep -q 'app\.js'; then
      kill "$(basename "$d")" 2>/dev/null
    fi
  done
fi
exit 0
SB_EOF_STOP

# ---------- 写 uninstall.sh（停进程 + 删整个目录） ----------
cat > "$DIR/uninstall.sh" <<'SB_EOF_UNINSTALL'
#!/bin/sh
# node-auto 卸载（由 node-auto.sh 生成）：停掉守护与实例，删除整个安装目录。
set -u
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ "${1:-}" != "--confirmed" ]; then
  # 先把自己复制到临时目录再执行，避免删目录时连正在运行的脚本一起删掉
  tmp="${TMPDIR:-/tmp}/node-auto-uninstall.$$.sh"
  cp "$0" "$tmp" || exit 1
  exec sh "$tmp" --confirmed "$DIR"
fi
TARGET=$2
[ -f "$TARGET/stop.sh" ] && sh "$TARGET/stop.sh" 2>/dev/null
# systemd 保活时一并禁用并移除单元，避免残留单元指向已删除的目录
if command -v systemctl >/dev/null 2>&1; then
  for u in node-auto-tls node-auto-plain; do
    if [ -f "/etc/systemd/system/$u.service" ]; then
      systemctl disable --now "$u" 2>/dev/null
      rm -f "/etc/systemd/system/$u.service"
    fi
  done
  systemctl daemon-reload 2>/dev/null
fi
sleep 1
rm -rf "$TARGET"
echo "已卸载：$TARGET 已删除"
rm -f "$0"
SB_EOF_UNINSTALL

chmod +x "$DIR/start.sh" "$DIR/guard.sh" "$DIR/stop.sh" "$DIR/uninstall.sh" 2>/dev/null || true

# ---------- 拉起（按保活方式分流） ----------
write_unit() { # $1=tag $2=port $3=tls|none：生成一个实例的 systemd 单元
  uf="/etc/systemd/system/node-auto-$1.service"
  {
    printf '[Unit]\n'
    printf 'Description=node-auto (%s instance)\n' "$1"
    printf 'After=network-online.target\n'
    printf 'Wants=network-online.target\n'
    printf '\n[Service]\n'
    printf 'Type=simple\n'
    printf 'WorkingDirectory=%s/app\n' "$DIR"
    printf 'Environment=NAME=node-auto\n'
    printf 'Environment=UUID=%s\n' "$UUID"
    printf 'Environment=PORT=%s\n' "$2"
    printf 'Environment=DOMAIN=%s\n' "$DOMAIN"
    printf 'Environment=LINK_HOST=%s\n' "$DOMAIN"
    printf 'Environment=LINK_PORT=%s\n' "$2"
    if [ "$3" = tls ]; then
      printf 'Environment=LINK_SECURITY=tls\n'
      printf 'Environment=LINK_SNI=%s\n' "$DOMAIN"
      printf 'Environment=CERT_FILE=%s/cert.pem\n' "$DIR"
      printf 'Environment=KEY_FILE=%s/key.pem\n' "$DIR"
    else
      printf 'Environment=LINK_SECURITY=none\n'
    fi
    printf 'ExecStart=%s/node/bin/node app.js\n' "$DIR"
    printf 'Restart=always\n'
    printf 'RestartSec=3\n'
    printf '\n[Install]\n'
    printf 'WantedBy=multi-user.target\n'
  } > "$uf" || die "写 systemd 单元失败：$uf"
}

if [ "$KEEPALIVE" = systemd ]; then
  # 先停可能在跑的 guard/旧实例（stop.sh 兼管两种保活的停止），再装单元
  [ -f "$DIR/stop.sh" ] && sh "$DIR/stop.sh" 2>/dev/null
  if [ -n "$TLS_PORT" ]; then write_unit tls "$TLS_PORT" tls; fi
  if [ -n "$PLAIN_PORT" ]; then write_unit plain "$PLAIN_PORT" none; fi
  # 本次没启用的实例若留着旧单元，清掉，避免它占着已不用的端口
  if [ -z "$TLS_PORT" ] && [ -f /etc/systemd/system/node-auto-tls.service ]; then
    systemctl disable --now node-auto-tls 2>/dev/null; rm -f /etc/systemd/system/node-auto-tls.service
  fi
  if [ -z "$PLAIN_PORT" ] && [ -f /etc/systemd/system/node-auto-plain.service ]; then
    systemctl disable --now node-auto-plain 2>/dev/null; rm -f /etc/systemd/system/node-auto-plain.service
  fi
  systemctl daemon-reload || die "systemctl daemon-reload 失败"
  if [ -n "$TLS_PORT" ]; then
    systemctl enable node-auto-tls >/dev/null 2>&1 || true
    systemctl restart node-auto-tls || die "TLS 单元启动失败（systemctl status node-auto-tls 查看）"
  fi
  if [ -n "$PLAIN_PORT" ]; then
    systemctl enable node-auto-plain >/dev/null 2>&1 || true
    systemctl restart node-auto-plain || die "明文单元启动失败（systemctl status node-auto-plain 查看）"
  fi
else
  # guard 保活：若上次是 systemd 保活，先禁用旧单元，避免与 guard 实例抢端口
  if [ "$CFG_KEEPALIVE" = systemd ] && have systemctl; then
    for u in node-auto-tls node-auto-plain; do
      if [ -f "/etc/systemd/system/$u.service" ]; then
        systemctl disable --now "$u" 2>/dev/null
        rm -f "/etc/systemd/system/$u.service"
      fi
    done
    systemctl daemon-reload 2>/dev/null || true
  fi
  # 域名变了要让实例带新环境重启：先整体停一次，再由 start.sh 拉起
  if [ -n "$CFG_DOMAIN" ] && [ "$CFG_DOMAIN" != "$DOMAIN" ]; then
    [ -f "$DIR/stop.sh" ] && sh "$DIR/stop.sh" 2>/dev/null
  fi
  sh "$DIR/start.sh" || true
  GUARD_RUNNING=0
  if [ -f "$DIR/run/guard.pid" ]; then
    gp=$(cat "$DIR/run/guard.pid" 2>/dev/null)
    if [ -n "$gp" ] && kill -0 "$gp" 2>/dev/null; then GUARD_RUNNING=1; fi
  fi
  if [ "$GUARD_RUNNING" -eq 0 ]; then
    if have setsid; then LAUNCH=setsid; else LAUNCH=nohup; fi
    $LAUNCH sh "$DIR/guard.sh" >> "$DIR/logs/guard.out" 2>&1 </dev/null &
  fi
fi

# ---------- 取节点链接（从 app 的 /<UUID> 输出取，取不到再按同规则拼） ----------
node_fetch() { # $1=url：用自带 Node 取页面（不依赖 curl/wget 是否存在）
  "$NODE" -e '
    const u = new URL(process.argv[1]);
    const lib = u.protocol === "https:" ? require("https") : require("http");
    const req = lib.get(u, { rejectUnauthorized: false }, r => {
      let d = "";
      r.on("data", c => d += c);
      r.on("end", () => { process.stdout.write(d); });
    });
    req.setTimeout(3000, () => { req.destroy(new Error("timeout")); });
    req.on("error", () => process.exit(1));
  ' "$1" 2>/dev/null
}
wait_link() { # $1=scheme $2=port：等实例在目标口应答且返回的是本实例的链接（装后自检兼取链接）
  i=0
  while [ $i -lt 20 ]; do
    out=$(node_fetch "$1://127.0.0.1:$2/$UUID") && case "$out" in *vless://*) printf '%s' "$out"; return 0;; esac
    i=$((i + 1))
    sleep 1
  done
  return 1
}
build_link() { # $1=port $2=tls|none：与 app.js buildLink 同规则（NAME 固定 node-auto）
  if [ "$2" = tls ]; then
    printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=chrome&type=ws&host=%s&path=%%2F#Vl-ws-tls-node-auto\n' \
      "$UUID" "$(bracket_host "$DOMAIN")" "$1" "$DOMAIN" "$DOMAIN"
  else
    printf 'vless://%s@%s:%s?encryption=none&security=none&type=ws&host=%s&path=%%2F#Vl-ws-none-node-auto\n' \
      "$UUID" "$(bracket_host "$DOMAIN")" "$1" "$DOMAIN"
  fi
}

TLS_LINK=''; PLAIN_LINK=''
TLS_OK=0; PLAIN_OK=0
if [ -n "$TLS_PORT" ]; then
  if TLS_LINK=$(wait_link https "$TLS_PORT"); then TLS_OK=1; else TLS_LINK=$(build_link "$TLS_PORT" tls); fi
fi
if [ -n "$PLAIN_PORT" ]; then
  if PLAIN_LINK=$(wait_link http "$PLAIN_PORT"); then PLAIN_OK=1; else PLAIN_LINK=$(build_link "$PLAIN_PORT" none); fi
fi

# ---------- 装后自检（实例必须真在目标口应答，否则不许报「安装完成」） ----------
FAILED=''
if [ -n "$TLS_PORT" ] && [ "$TLS_OK" -eq 0 ]; then
  if [ "$KEEPALIVE" = systemd ]; then FAILED="$FAILED TLS 口 $TLS_PORT（journalctl -u node-auto-tls 看日志）"; else FAILED="$FAILED TLS 口 $TLS_PORT（日志 $DIR/logs/tls.log）"; fi
fi
if [ -n "$PLAIN_PORT" ] && [ "$PLAIN_OK" -eq 0 ]; then
  if [ "$KEEPALIVE" = systemd ]; then FAILED="$FAILED 明文口 $PLAIN_PORT（journalctl -u node-auto-plain 看日志）"; else FAILED="$FAILED 明文口 $PLAIN_PORT（日志 $DIR/logs/plain.log）"; fi
fi
if [ -n "$FAILED" ]; then
  err "安装未完成：以下实例没能在目标端口上应答：$FAILED"
  err "常见原因：非 root 绑特权口被拒（EACCES）、端口被别的程序占用。处理后重跑本脚本即可（UUID/端口读回不变；换端口用 --tls-port / --plain-port 指定）。"
  exit 1
fi

# ---------- 汇总 ----------
say ''
say '==================== node-auto 安装完成 ===================='
say "安装目录：$DIR"
say "UUID：$UUID"
say "域名：$DOMAIN"
[ -n "$TLS_PORT" ] && say "TLS 实例：$DOMAIN:$TLS_PORT（自签证书，客户端需允许不安全证书/跳过验证）"
[ -n "$PLAIN_PORT" ] && say "明文实例：$DOMAIN:$PLAIN_PORT（根路径为诗词页）"
say '------------------------------------------------------------'
[ -n "$TLS_LINK" ] && { say 'TLS 节点链接：'; say "$TLS_LINK"; }
[ -n "$PLAIN_LINK" ] && { say '明文节点链接：'; say "$PLAIN_LINK"; }
say '------------------------------------------------------------'
say "伪装页：http://$(bracket_host "$DOMAIN"):${PLAIN_PORT:-$TLS_PORT}/ （TLS 口需用 https）"
if [ "$KEEPALIVE" = systemd ]; then
  say "保活：systemd 单元 node-auto-tls / node-auto-plain（Restart=always）"
else
  say "守护：guard.sh 每 30 秒巡检，掉线自动补拉（logs/guard.log 只记拉起事件）"
fi
if [ -n "$TLS_PORT" ]; then
  if in_list "$TLS_PORT" "$CF_TLS_PORTS"; then
    say "黄云提醒：TLS 口在 Cloudflare 名单内，开黄云时把 SSL 模式设为 Full（源站是自签证书）"
  else
    say "灰云提醒：TLS 口不在 Cloudflare 名单内，域名只能开灰云"
  fi
fi
if [ -n "$PLAIN_PORT" ] && ! in_list "$PLAIN_PORT" "$CF_PLAIN_PORTS"; then
  say "灰云提醒：明文口不在 Cloudflare 名单内，域名只能开灰云"
fi
say "停止：sh $DIR/stop.sh"
say "卸载：sh $DIR/uninstall.sh（停进程并删除整个安装目录）"
say '============================================================'
