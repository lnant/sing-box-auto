# sing-box-mini

50M 级轻量三协议 sing-box：**装机约 40M、运行 34–47M**，为小内存机器而做。

本版本与同仓的 [sing-box-auto](https://github.com/lnant/sing-box-auto)（六合一）、
[sing-box-coexist](COEXIST.md)（七合一）是兄弟项目，定位不同、并行维护：

| 项目 | 定位 |
|---|---|
| sing-box-vless（auto 仓内精简版） | 单 VLESS 协议极简，官方二进制 |
| **sing-box-mini（本项目）** | **三协议 + 定制编译核心，装机与运行都压进 50M 级** |
| sing-box-auto / coexist | 全功能多协议，资源不设限 |

## 为什么能这么小

官方 sing-box 本体约 78M（全功能打包）。本项目从源码定制编译，只保留必需能力：

- build tags：`with_quic`（Hysteria2）、`with_wireguard`（WARP 出站）、`with_utls`（Reality）、`with_acme`（真证书）
- 砍掉：gVisor/TUN、Tailscale、Clash API、其余协议与传输
- `-trimpath -ldflags "-s -w"`；不做 UPX 等二次压缩

构建方法见 [build.sh](build.sh)（固定 sing-box v1.14.4，可复现）。

## 协议（三件套，最小够用）

| 协议 | 角色 |
|---|---|
| VLESS + Reality (TCP) | 主力直连，免域名免证书 |
| Hysteria2 (UDP) | 弱网与速度担当 |
| Shadowsocks 2022 | 最轻兜底，全平台客户端 |

不含 Argo 隧道（cloudflared 本体 36M+、常驻再加约 38M，50M 目标下无解）；
域名链套 Cloudflare 橙云不依赖它。

## 实测（2026-11-07，Woiden 免费 NAT VPS：1 核 / 1 GB / OpenVZ）

| 档位 | 数值 |
|---|---|
| 二进制体积（amd64） | 41,947,284 字节（约 40M） |
| 二进制体积（arm64） | 39,256,212 字节（约 37M） |
| 空载内存（三协议配置加载） | 约 34M |
| 带流量峰值（三协议实载，20 并发灌流） | ≤ 47M |
| 流量停后 30 秒 | 回落至约 39M |

对照同场实测：官方版 sing-box 单核心空载约 32–38M 但本体 73–78M；
Xray 本体 35M、空载约 33M；3x-ui 面板+核心空载约 116M、落盘 140M+。

## 状态

核心可行性验证与安装脚本 v0.1.0 已完成（2026-11-07，Woiden 实测见上表）。
