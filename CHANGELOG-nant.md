# sing-box-nant 变更记录

## nant-v0.1.0（2026-11-24）

首版。由原 sing-box-mini 改名而来，并更换核心：

- 核心改用自建的 NantCore（发布于 lnant/nantcore 仓），首版锁定
  NantCore v1.0（对应 sing-box v1.14.4），下载带 sha256 校验
- 定位调整：不再走轻量三协议路线，改为全功能路线，脚本功能后续
  按核心能力持续补齐
- 现有功能（三协议、零交互安装、幂等、菜单、更新核心、卸载）
  已在新核心上实测跑通
- 安装目录、服务名、快捷命令相应改为 /etc/s-box-nant、
  sing-box-nant、sbn；链接保存到 /root/singbox-nant-links.txt
- 内存软上限（GOMEMLIMIT）随全功能核心放宽到 128MiB（暂定，
  待功能全开实测后定）
