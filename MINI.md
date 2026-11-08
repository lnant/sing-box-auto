# sing-box-mini

50M 级轻量三协议 sing-box：**装机约 40M、运行 34–47M**，为小内存机器而做。

本版本与同仓的七合一 [sing-box-coexist.sh](COEXIST.md)、六合一 sing-box-auto.sh、
精简版 sing-box-vless.sh 是兄弟版本，定位不同、并行维护：

| 版本 | 定位 |
|---|---|
| sing-box-coexist.sh（七合一） | 功能最全：七协议 + 域名链 + WARP |
| sing-box-auto.sh（六合一） | 多协议、多线路备用 |
| sing-box-vless.sh（精简版） | 单 VLESS 协议极简，官方二进制 |
| **sing-box-mini.sh（本版本）** | **三协议 + 定制编译核心，装机与运行都压进 50M 级** |

## 为什么能这么小

官方 sing-box 本体约 78M（全功能打包）。本项目从源码定制编译，只保留必需能力：

- build tags 只保留 `with_quic`、`with_wireguard`、`with_utls`、`with_acme` 四个
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

已随统一发布仓发布：脚本 mini-v0.1.1、核心 core-v1.14.4（脚本 2026-11-08
修订：端口抽号互斥防撞号＋sbm 裸跑进菜单；首发 2026-11-07，
Woiden 实测见上表，三协议外网实测全通）。

## 许可证

核心由 [sing-box](https://github.com/SagerNet/sing-box) 源码定制编译，
版权所有 © nekohasekai <contact-sagernet@sekai.icu>，依 GNU GPLv3 发布；
许可证全文见 [LICENSE-sing-box.txt](LICENSE-sing-box.txt)，
核心 Release 附件中亦附带该文件。
