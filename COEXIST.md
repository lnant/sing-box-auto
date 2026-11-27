# sing-box-coexist（全功能版 full）

sing-box 一键安装脚本，同仓功能最全的一支，别名 **全功能版 / full**：
以官方 sing-box 核心为底，九个入站全开，再加一条 VLESS+WS+TLS 域名链、
可选的 Argo 隧道链与 WARP 出站，多条链路互为备份，一条被干扰另一条还能用。

核心就是官方 sing-box，支持 sing-box 的数十种主流协议；脚本功能按此
定位持续补齐，跟随官方核心更新，后续可支持更多协议与功能。

## 协议一览

| # | 协议 | 说明 |
|---|---|---|
| 1 | VLESS + Reality (TCP) | 直连，免域名免证书 |
| 2 | VMess + WebSocket (TCP) | 直连；也是 Argo 隧道的落地入站 |
| 3 | Hysteria2 (UDP) | 直连 |
| 4 | TUIC v5 (UDP) | 直连 |
| 5 | AnyTLS (TCP) | 直连 |
| 6 | Shadowsocks 2022 (TCP+UDP) | 直连 |
| 7 | Trojan (TCP) | 直连 |
| 8 | Naive (TCP) | 直连 |
| 9 | VLESS + WebSocket + TLS (TCP) | 域名链，可直连或套 Cloudflare |
| 可选 | VMess + Argo 隧道 | **默认关**：Cloudflare 隧道（临时/固定），不暴露源站 IP、无需公网入站；装机时决定开/关，菜单里随时可开关 |

另带 WARP 出站（WireGuard 端点）：纯 IPv6 / 无 IPv4 出口的机器默认开启
「仅 IPv4 经 WARP」，其余默认关闭，注册与参数全自动、失败自动降级关闭、
不阻塞安装。部分机器 IP 纯净度较低、无法解锁部分流媒体服务，或纯 IPv6
无法访问 IPv4 网站时，WARP 可提供相对干净的双栈出口。

## 一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/lnant/sing-box-auto/main/sing-box-coexist.sh | sudo bash
```

要求：Linux 服务器（Debian / Ubuntu / CentOS / Oracle Linux 等），**root 权限**，
x86_64 / arm64 / armv7 架构，内存建议 ≥1 GB。

## 装机时的几个可选项

其余全自动（UUID、密钥、密码、端口全部自动生成，端口 10000–60000 随机、
互不冲突；域名链端口优先选 Cloudflare 支持的端口）。只有三处会问，
都不回答也能装完：

- **自己的域名（手动加记录，不要令牌）**：脚本不进任何人的解析后台。
  想给域名链用自己的域名，交互安装时按提示输入子域名，脚本把要加的
  解析记录原样打印出来（A/AAAA → 本机公网 IP、灰云），你自己去面板
  加上，脚本轮询验解析（约 1 分钟），指到本机才定下来；定下来后顺手
  用核心内置 ACME 试签 Let's Encrypt 真证书，签成核心自动续期，签不成
  回落自签、安装照常完成。直接回车或超时不输入 = 不用域名、走临时
  域名；判定满 3 次也回落临时域名装完。装后随时可在菜单「改域名」
  里换成自己的域名，同一套流程。装完有域名的可再去面板开黄云。
- **Argo 隧道（可选开关，默认关）**：装机时一问决定（回车/超时 = 不开；
  也可用环境变量 `SBOX_ARGO=off|temp|fixed` 指定，fixed 还需
  `SBOX_ARGO_TOKEN` 与 `SBOX_ARGO_DOMAIN`）。开临时隧道用随机
  trycloudflare 域名（重启会变）；固定隧道用自己的 Token + 域名，
  ingress 在 Cloudflare 侧指向本机 VMess 端口。关时零副作用：不下载
  cloudflared、不写服务单元、配置与链接里都没有 Argo。菜单第 5 项
  随时可开/关/切换模式。
- **公网 IP 手填**：自动检测不到公网 IP 时会提示手填（每轮 20 秒，
  空/超时/填错计一次，满 3 次退出安装），手填值存档、重跑不重复问。

## 从旧版升级

重复运行新版安装即升级，**零漂移**：能读回 coexist-v1.1.4 及更早的
`auto.env` / `sb.json`，UUID 与原有六个端口不变，原有链接继续有效，
新增协议的端口与凭据自动补齐。两点行为变化请留意：

- Argo 默认改为关闭：旧版开着**固定**隧道的保持开；旧版开着**临时**
  隧道的升级后会变关（判定为关时装机结尾会自动把旧版遗留的
  cloudflared 进程与服务单元清净，不留半开状态），需要的话在菜单
  第 5 项重新打开即可。
- 域名链改为手动加记录流：旧版经脚本套 Cloudflare 的域名不再由脚本
  代管解析与证书，改走上面的手动流（菜单「改域名」）。

## 管理

装好后直接运行 `sbc` 进管理菜单（快捷方式自动提权，不用敲 sudo；
旧名 `sbox` 兼容，行为相同），或用动作参数：

```bash
sbc                     # 管理菜单
sbc links               # 重新打印全部链接
sbc change-argo         # Argo 隧道管理（开关/临时/固定）
sbc restart             # 重启服务（Argo 期望状态一并对齐）
sbc warp-reroll         # 更换 WARP IP（重新注册，失败自动回滚）
sbc update-core         # 更新 sing-box 内核（跟随官方最新稳定版）
sbc update-script       # 更新脚本自身（按 coexist-v 前缀取版）
sbc uninstall           # 卸载
sbc version             # 查看版本
```

菜单共 11 项：查看链接 / 改域名 / 重启服务 / WARP 出站 / Argo 隧道 /
更换端口 / 重置身份 / 更新证书 / 更新核心 / 更新脚本 / 卸载。

链接保存在 `/root/singbox-links.txt`，配置与状态在 `/etc/s-box`，
服务名为 `sing-box-auto`（Argo 单元 `sing-box-auto-argo`）。

## 资源占用

sing-box 单进程空载内存约 55 MB 量级；开启 Argo 时另有 cloudflared
进程。服务与隧道由 systemd 托管（崩溃自动拉起），无 systemd 时以
cron `@reboot` 兜底。受限容器（OpenVZ 等）自动适配系统 DNS 解析；
纯 IPv6 机器自动经 DNS64 绕行下载核心。

## 版本

当前版本：**coexist-v1.2.1**（变更记录见 [CHANGELOG-coexist.md](CHANGELOG-coexist.md)，
发布包见 GitHub Releases）。
一键安装默认拉取最新版（main 分支）；把命令里的 `main` 换成版本 tag
（如 `coexist-v1.2.1`）即可固定版本安装。

基于 [sing-box](https://github.com/SagerNet/sing-box)（© nekohasekai，GPLv3），
上游许可证见 [LICENSE-sing-box.txt](LICENSE-sing-box.txt)。
