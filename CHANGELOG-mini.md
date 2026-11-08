# 更新日志

## v0.1.1（2026-11-08）
- 修复三协议随机端口连抽可能撞号：抽号互斥（连抽时排除已分配端口，含菜单换端口路径）
- restart_service 补重启后验活，堵住菜单路径服务重启失败却无提示的静默失败
- 裸跑 `sbm`（无参数）改为打开菜单（与七合一 sbox 同式）；经脚本文件/管道运行仍默认安装

## v0.1.0（2026-11-07）
- 首版：轻量三协议安装脚本 sing-box-mini.sh
  - 协议：VLESS + Reality / Hysteria2 / Shadowsocks 2022，零交互安装
  - 定制核心（sing-box v1.14.4，tags：with_quic/with_wireguard/with_utls/with_acme），
    从本仓（统一发布仓 sing-box-auto）core-v* Release 下载并验 sha256；amd64 约 40M / arm64 约 37M
  - systemd 服务带内存刹车（GOMEMLIMIT=48MiB、GOGC=50）
  - 独立目录 /etc/s-box-mini 与服务名，可与全功能版同机共存；快捷命令 sbm
  - 受限容器（OpenVZ/venet）自动适配系统 DNS；纯 IPv6 自动 DNS64 绕行下载
  - 菜单：看链接 / 重启 / 换端口 / 重置身份 / 更新核心 / 卸载
- 核心自动同步流水线（GitHub Actions）：每周查上游新版，自动编译＋冒烟测试，
  生成 Draft Release 待人工转正
