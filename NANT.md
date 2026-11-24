# sing-box-nant

使用自建核心 **NantCore** 的 sing-box 发行。核心为全功能构建，
支持 sing-box 的数十种主流协议；脚本功能按此定位持续补齐。

本版本与同仓的七合一 sing-box-coexist.sh、六合一 sing-box-auto.sh、
精简版 sing-box-vless.sh 是兄弟版本，定位不同、并行维护：

| 版本 | 定位 |
|---|---|
| sing-box-coexist.sh（七合一） | 功能最全：七协议 + 域名链 + WARP（官方核心） |
| sing-box-auto.sh（六合一） | 多协议、多线路备用（官方核心） |
| sing-box-vless.sh（精简版） | 单 VLESS 协议极简（官方核心） |
| **sing-box-nant.sh（本版本）** | **自建核心 NantCore + 全功能路线** |

## 核心

核心是 [NantCore](https://github.com/lnant/nantcore)：基于 sing-box 源码
定制编译，按版本发布在该仓的 Releases 中，脚本安装时自动下载并做
sha256 校验。各项目锁定自己用的核心版本、各自验证；核心版本的大版本
跟随 sing-box 官方大版本。

本脚本首版（nant-v0.1.0）锁定 NantCore v1.0（对应 sing-box v1.14.4）。

## 当前脚本功能

由原 sing-box-mini 改名换核而来，现有功能已在新核心上跑通：

| 协议 | 角色 |
|---|---|
| VLESS + Reality (TCP) | 主力直连，免域名免证书 |
| Hysteria2 (UDP) | 弱网与速度担当 |
| Shadowsocks 2022 | 兜底，全平台客户端 |

全程零交互：UUID、密钥、密码、端口全部自动生成（端口 10000–60000
随机）；重复运行幂等，UUID/密钥/端口不变。独立目录 /etc/s-box-nant、
独立服务名 sing-box-nant、快捷命令 `sbn`，可与其他版本同机共存。
受限容器（OpenVZ 等）自动适配系统 DNS 解析；纯 IPv6 机器自动经
DNS64 绕行下载核心。

后续将按全功能定位把核心支持的更多协议与功能补进脚本。

## 0.2.0 更新（2026-11-24）

入站补齐到九个：VLESS+Reality、Hysteria2、Shadowsocks 2022、
VMess+WS、Trojan、TUIC v5、AnyTLS、VLESS+WS+TLS 域名链、Naive；
另加 WireGuard 端点 / WARP 出站（纯 IPv6 机器默认开 ipv4 模式）。

CF 自动域名已全链实测（纯 IPv6 机器）：提供 Cloudflare API Token 后
自动建子域名、开橙色云代理、经 DNS-01 签发 Let's Encrypt 真证书，
客户端不需要允许不安全证书，真流量实测 204 通过。Token 可以在交互
安装时直接粘贴输入（账号下多个域名时编号选），不必再敲命令行
环境变量；回车跳过则走临时域名自签。

本版三个修复：

- 令牌文件 cf.env 权限：所有写路径收尾都纠回 600，读取时再自愈一次
- 重跑复用已建域名：安装中断后重跑时，先回读确认 cf.env 里记着的
  域名仍在 Cloudflare 里，就直接复用、不新建记录，不再产生删不到的
  孤儿记录
- 静默步骤加提示：调 Cloudflare 接口、注册 WARP 这类长时间无输出的
  步骤，开工前先提示在做什么、大约要等多久、不要关闭终端

## 实测（2026-11-24，Oracle Cloud 凤凰城：1 OCPU / 6 GB / arm64）

| 档位 | 数值 |
|---|---|
| 二进制体积（amd64） | 78,381,180 字节（约 78M） |
| 二进制体积（arm64） | 72,941,692 字节（约 73M） |
| 空载内存（三协议配置加载，RSS） | 约 55M |
| 真流量 | 三协议逐条实测全通（HTTP 204） |

## 许可证

核心由 [sing-box](https://github.com/SagerNet/sing-box) 源码定制编译，
版权所有 © nekohasekai <contact-sagernet@sekai.icu>，依 GNU GPLv3 发布；
许可证全文见 [LICENSE-sing-box.txt](LICENSE-sing-box.txt)，
NantCore 的 Release 附件中亦附带该文件。
