# 更新日志

本项目的版本号同时写在两个脚本的 `SCRIPT_VERSION` 里，并与 GitHub 的 tag / Release 对应。
一键安装默认拉最新版（main 分支）；把安装命令里的 `main` 换成某个 tag（如 `v1.1.0`）即可固定版本安装。

## v1.1.0（2026-10-31）

本仓库重建后重新起版的首个发布，包含现行全部功能：

- 双脚本：Argo 六合一版（sing-box-auto.sh，全程零交互装 6 种协议）与精简版（sing-box-vless.sh，仅 VLESS + Reality）
- 纯 IPv6 / IPv4 出站损坏环境可经 DNS64 / NAT64 引导完成从零安装；切换 DNS64 后的复探最多 3 次、间隔递增（3s/6s），应对 NAT64 冷启动慢
- 脚本内置自更新：向本仓库查询最新 Release 并拉取新版脚本；固定版本安装使用本仓库的 tag 直达链接
