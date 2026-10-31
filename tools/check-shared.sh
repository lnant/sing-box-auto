#!/usr/bin/env bash
# 两脚本共有函数一致性检查（开发工具，不参与安装）。
#
# 背景：sing-box-auto.sh 与 sing-box-vless.sh 是两个可独立分发的单文件脚本，
# 一批核心函数在两边各有一份拷贝。历史上出现过"改一处漏一处"的分叉
# （防火墙策略、依赖包名映射都中过招）。本脚本把共有函数逐个 diff：
#   - 应一致的函数出现差异 → 报错退出（大概率是漏改）；
#   - 已知-by-design 的差异在 KNOWN_DIFF 里登记原因，只提示不报错；
#   - 新增的共有函数默认按"应一致"对待，逼迫开发者显式登记差异。
#
# 用法：在仓库根目录运行  bash tools/check-shared.sh
set -u
cd "$(dirname "$0")/.." || exit 1

AUTO="sing-box-auto.sh"
VLESS="sing-box-vless.sh"

# 已知差异及原因（函数名|原因）
KNOWN_DIFF=(
  "do_uninstall|全自动版多 Argo 单元/隧道清理"
  "ensure_cron_running|警告文案不同（全自动版含 Argo）"
  "install_deps|包名映射的代码结构不同，行为已对齐（cron/iproute/ca-certificates）"
  "load_or_gen_identity|全自动版管 5 个协议端口，精简版只有 1 个"
  "open_firewall|端口来源不同（全自动版读 sb.json，精简版用 PORT_VLESS）"
  "rand_port|全自动版多一个已分配端口列表参数，需避开 5 协议互撞"
  "save_env|保存字段不同（协议数不同）"
  "write_config|生成的 inbound 数量不同"
  "print_links|输出的协议链接数量不同（全自动版 6 条含 Argo，精简版 1 条）"
)

extract() {  # $1=文件 $2=函数名：打印函数体（^name() { 到 ^}）
  awk -v fn="$2" '
    $0 ~ "^" fn "\\(\\) \\{" { in_fn=1 }
    in_fn { print }
    in_fn && $0 == "}" { exit }
  ' "$1"
}

func_names() {  # $1=文件：打印全部顶层函数名
  grep -oP '^[a-z_0-9]+(?=\(\) \{)' "$1"
}

known_reason() {  # $1=函数名：命中返回原因，否则返回空
  local kv
  for kv in "${KNOWN_DIFF[@]}"; do
    [[ "${kv%%|*}" == "$1" ]] && { echo "${kv#*|}"; return 0; }
  done
  echo ""
}

rc=0
echo "共有函数一致性检查：$AUTO vs $VLESS"
echo "------------------------------------------------------------"
for fn in $(func_names "$AUTO"); do
  grep -qx "$fn" <(func_names "$VLESS") || continue
  a_body=$(extract "$AUTO" "$fn")
  b_body=$(extract "$VLESS" "$fn")
  reason=$(known_reason "$fn")
  if [[ "$a_body" == "$b_body" ]]; then
    if [[ -n "$reason" ]]; then
      echo "[提示] $fn 已一致，可从已知差异清单移除（登记原因：$reason）"
    else
      echo "[一致] $fn"
    fi
  else
    if [[ -n "$reason" ]]; then
      echo "[已知差异] $fn —— $reason"
    else
      echo "[漂移!] $fn 两边不一致且未登记原因——多半是改一处漏一处，请检查"
      rc=1
    fi
  fi
done
echo "------------------------------------------------------------"
if (( rc == 0 )); then
  echo "结果：通过（无未登记漂移）"
else
  echo "结果：不通过，请修复漂移或在 KNOWN_DIFF 登记原因"
fi
exit $rc
