# sing-box-auto

（[English](README.en.md)）

sing-box 一键安装脚本，**全程零交互**，复制一条命令即可装好。参考互联网上相关 sing-box 一键脚本，去掉了所有交互式提问（端口、证书、内核版本、
防火墙确认等），全部用合理默认值或自动生成的值代替。

## 两个版本（二选一）

| | `sing-box-auto.sh`（Argo 六合一版） | `sing-box-vless.sh`（精简版） |
|---|---|---|
| 用途 | 一次装好全部 6 种协议 | 只装 VLESS + Reality，最省心 |
| 协议 | VLESS+Reality、VMess+WS、VMess+Argo、Hysteria2、TUIC、AnyTLS | VLESS+Reality |
| 适合 | 想多条线路备用 | 只要一个能用的节点 |

## 一键安装

Argo 六合一版：

```bash
curl -fsSL https://raw.githubusercontent.com/lnant/sing-box-auto/main/sing-box-auto.sh | sudo bash
```

精简版（仅 VLESS + Reality）：

```bash
curl -fsSL https://raw.githubusercontent.com/lnant/sing-box-auto/main/sing-box-vless.sh | sudo bash
```

要求：Linux 服务器（Debian / Ubuntu / CentOS / Oracle Linux 等），**root 权限**，
x86_64 / arm64 / armv7 架构。另外：

- **内存**：建议 ≥1 GB；小于 1 GB 请先加 swap（脚本对"内存 <1 GB 且无 swap"会预警，
  小内存机器装依赖时包管理器可能 OOM 卡死整机）。
- **自启依赖**：有 systemd 时服务与 Argo 隧道都由 systemd 托管（崩溃自动拉起）；
  无 systemd 时靠 cron 的 `@reboot` 兜底，脚本会在安装时尝试启用 cron 服务。
  容器（Docker/LXC）里这两者通常都不生效，安装只保证容器运行期间可用。
- **端口**：每个协议用哪个端口见安装输出、`/root/singbox-links.txt` 或管理菜单
  顶部状态区；云厂商还需在控制台安全组里放行同样的端口（见注意事项 2）。

## 版本

当前版本：**v1.1.1**（变更记录见 [CHANGELOG.md](CHANGELOG.md)，发布包见 GitHub Releases）。
已安装的机器上运行 `sbox version` 可查看脚本版本号。

一键安装默认拉取最新版（main 分支）。若想固定在某个已发布版本（例如新版有问题时回退），
把命令里的 `main` 换成版本号 tag 即可：

Argo 六合一版（固定 v1.1.0）：

```bash
curl -fsSL https://raw.githubusercontent.com/lnant/sing-box-auto/v1.1.0/sing-box-auto.sh | sudo bash
```

精简版（固定 v1.1.0）：

```bash
curl -fsSL https://raw.githubusercontent.com/lnant/sing-box-auto/v1.1.0/sing-box-vless.sh | sudo bash
```

## 端口（随机分配）

新装时 5 个协议的端口在 **10000–60000** 范围内随机分配，互不冲突，自动避开已占用的端口。
多台服务器各跑一次，端口各不相同。重复运行脚本不会改变已有端口（幂等）。

| 协议 | 传输 | 说明 |
|---|---|---|
| VLESS + Reality | TCP | 随机端口 |
| VMess + WS | TCP | 随机端口 |
| VMess + Argo | 经 Cloudflare 隧道，无需本机端口 | 临时域名，重启后会变 |
| Hysteria2 | UDP | 随机端口 |
| TUIC v5 | UDP | 随机端口 |
| AnyTLS | TCP | 随机端口，需要较新 sing-box 内核（脚本自动装最新版） |

想固定端口：装完后用管理菜单 4（更换端口）手动指定。

## 安装后

- 终端会直接打印全部客户端链接（`vless://`、`vmess://`、`hysteria2://`、
  `tuic://`、`anytls://`），复制到客户端即可使用。
- 链接同时保存到 **`/root/singbox-links.txt`**，随时 `cat` 查看。
- UUID、Reality 密钥对、端口保存在 `/etc/s-box/auto.env`，配置文件在
  `/etc/s-box/sb.json`，服务名为 `sing-box-auto`（精简版 `sing-box-vless`）。

## 自动化说明

同类脚本常见的交互点及本脚本的处理：

| 常见交互 | 本脚本做法 |
|---|---|
| 是否关闭防火墙（默认是） | 不关闭：只增量放行协议端口（TCP+UDP），不动既有规则 |
| 内核版本选择（默认最新正式版） | 直接装最新正式版（支持 AnyTLS） |
| 证书选择（默认自签） | 自动生成 `www.bing.com` 自签证书，不申请 Acme |
| 端口设置（默认随机） | 新装时 10000–60000 随机分配，互不冲突 |
| UUID / Reality 密钥 | `sing-box generate` 自动生成 |
| 双栈 VPS 选 IPv4/IPv6 输出（默认 IPv4） | 优先 IPv4 |
| Argo 隧道 | 自动尝试 cloudflared **临时隧道**（无需授权）；失败则跳过，不阻塞安装 |

另外精简掉了同类脚本常见的 Warp 分流、订阅、Telegram 推送等附加功能，只保留核心代理能力。

## 管理菜单与快捷命令

Argo 六合一版安装时会自动装好 `sbox` 快捷命令，之后管理不需要再下载脚本：

```bash
sbox            # 进入管理菜单（opc 下打会自动 sudo 提权）
sbox <动作>     # 直接执行：change-uuid | change-reality | change-cert
                #   | change-argo | change-ports | show-links | restart | uninstall
                #   | update-script | update-core | version
                # 直接运行脚本文件时动作相同，另有 install（默认）与 menu
```

管理菜单（`sbox`）顺序：查看节点链接、重启服务、更换 UUID（全协议）、
更换端口、更新 Reality 密钥对、更新自签证书、Argo 隧道管理、
更新 sing-box 内核到最新版、更新脚本到最新版、卸载。其中更新内核
（菜单 8 / `sbox update-core`）更新前自动备份旧内核，新版与现有配置不兼容时
自动回滚；精简版用 `sing-box-vless.sh update-core`。

systemd 服务名为 `sing-box-auto`（精简版为 `sing-box-vless`），不会覆盖机器上
已有的其他 sing-box 安装；从旧版本升级时，本脚本自己的旧 `sing-box` 服务会自动迁移改名。

## 卸载

```bash
curl -fsSL https://raw.githubusercontent.com/lnant/sing-box-auto/main/sing-box-auto.sh | sudo bash -s -- uninstall
```

（精简版把 URL 换成 `sing-box-vless.sh` 即可。）

卸载会删除：sing-box 本体与全部配置（`/etc/s-box`）、链接文件、systemd 服务
（含 Argo 托管服务与本脚本自己的旧版服务）、`sbox` 命令、crontab 自启项。

卸载**不会**恢复或处理以下安装时留下的系统状态（如介意请手动处理）：
已添加的防火墙放行规则（留在 iptables/firewalld 里无害，想清可手动删除）、
SELinux 的 Permissive 设置、被禁用的 `dnf-makecache` 定时器、无 systemd
兜底路径写在 `/var/log/sing-box.log` 的日志文件。

## 常见问题

按顺序排查，多数"连不上"卡在前两步：

1. **所有链接都连不上**：先查云厂商控制台的安全组/安全列表是否放行了对应端口
   （脚本只能处理系统防火墙，云层放行要手动，端口见链接文件或菜单顶部状态）。
2. **确认服务在监听**：`ss -tulnp | grep sing-box` 应能看到各协议端口；
   看不到说明服务没起来，进下一步看日志。
3. **看服务日志**：`journalctl -u sing-box-auto -n 50`（精简版换成
   `sing-box-vless`），配置错误、端口被占都会写在这里。
4. **只有 Hysteria2 / TUIC 不通、TCP 协议正常**：多半是服务商或云防火墙拦了
   UDP——换一个 UDP 端口试（菜单 4），或确认安全组里放行的是 UDP 而非仅 TCP。
5. **Reality 协议突然连不上**：Reality 对时钟敏感，先 `timedatectl` 确认
   服务器时间同步正常（脚本安装时已开启 NTP）；Oracle Linux 等 RHEL 系再用
   `getenforce` 确认 SELinux 不是 Enforcing（安装时已置为 Permissive，
   系统大版本升级可能改回）。

## 注意事项

1. **两个版本二选一**，不要在同一台机器上混装——后装的会覆盖 `/etc/s-box/sb.json`。
   共用 `/etc/s-box/auto.env`，切换版本时 UUID 和 VLESS 端口保持不变，旧链接继续有效。
2. **Oracle Cloud / 其他云厂商**：脚本只放行系统防火墙，云控制台的安全组/安全列表
   里也需要放行对应端口，否则外网连不上。
3. 重复运行脚本是**幂等**的：保留 UUID、端口、密钥，只重写配置并重启服务。
   之前跑过互联网上知名同类脚本的机器，首次运行会自动导入原有 UUID/端口/密钥。
4. Argo 是**临时隧道**，域名每次启动都可能变化，且重启服务器后需等待约 15 秒
   重建；对稳定性要求高请以 VLESS + Reality 为主力。
5. 自签证书的协议（Hysteria2/TUIC/AnyTLS/VMess-WS）链接里带的是
   `insecure=1`，即客户端**跳过证书校验**（证书为自签，无法走 CA 链验证）；
   节点的实际凭据是 UUID 本身，链接不要外传。介意跳过校验的话，
   可用带证书校验的客户端手动填写证书指纹。
6. **纯 IPv6 服务器**可用：sing-box 监听 `::` 双栈，防火墙自动放行 ip6tables，
   客户端链接里的 IPv6 地址会自动加方括号。注意客户端那边也得有 IPv6 网络才能连上。
   安装时脚本会先探测 GitHub 可达性：GitHub 只有 IPv4 地址，纯 IPv6（或 IPv4 出站
   损坏）的机器会先自动跑一段引导——把 DNS 换成公共 DNS64（nat64.net）经 NAT64
   绕行下载（改前备份到 /etc/resolv.conf.sbox-bak、失败自动还原），通了再继续装；
   无 IPv6 出站时也可把二进制预置到 /etc/s-box/ 下，脚本会跳过下载。
