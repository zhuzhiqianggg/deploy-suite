#!/usr/bin/env bash
# ==============================================================================
# lops — Linux 运维工具箱 (Linux Ops Toolkit)
#
# 一句话: 集成 Linux 基础运维能力的统一入口，一个命令完成一个运维操作。
#
# 用法:
#   ./lops.sh                        交互式主菜单（编号选择，一键执行）
#   ./lops.sh <module>               进入模块交互菜单
#   ./lops.sh <module> <action> [参数] 子命令直达，适合自动化/脚本调用
#   ./lops.sh help                   查看总帮助（模块清单 + 示例）
#   ./lops.sh <module> help          查看模块详细帮助（动作/参数/示例/注意事项）
#
# 示例:
#   ./lops.sh                        # 交互式菜单
#   ./lops.sh init all               # 一键初始化整台服务器
#   ./lops.sh disk mount /dev/sdb /data ext4   # 格式化并挂载数据盘
#   ./lops.sh user add zhangsan dev  # 创建用户并加入 dev 组
#   ./lops.sh monitor check          # 一键健康巡检
#   ./lops.sh network client 10.0.0.1 5201     # iperf3 带宽测试
#
# 运行环境: Ubuntu/Debian、CentOS/RHEL/Rocky/AlmaLinux；部分动作需要 root。
# 日志位置: /var/log/lops/lops.log
# ==============================================================================
set -Eeuo pipefail

LOPS_VERSION="1.0.0"
LOPS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "${LOPS_ROOT}/lib/common.sh"
# shellcheck disable=SC1091
source "${LOPS_ROOT}/lib/ui.sh"

# ------------------------------------------------------------------------------
# 模块自动发现: 扫描 modules/*.sh，全部 source 进来。
# 每个模块必须实现 4 个接口函数:
#   mod_<name>_desc     输出一句话描述（主菜单/总帮助用）
#   mod_<name>_help     输出模块详细帮助
#   mod_<name>_actions  输出动作清单，每行格式: <action>|<说明>
#   mod_<name>_run      动作分发入口: mod_<name>_run <action> [args...]
# 新增模块 = 新增一个 modules/xx.sh 文件，无需修改本入口。
# ------------------------------------------------------------------------------
declare -a LOPS_MODS=()

for _f in "${LOPS_ROOT}"/modules/*.sh; do
  [[ -f "$_f" ]] || continue
  _name="$(basename "$_f" .sh)"
  # shellcheck disable=SC1090
  source "$_f"
  LOPS_MODS+=("$_name")
done
unset _f _name

mod_exists() {
  local m
  for m in "${LOPS_MODS[@]}"; do
    [[ "$m" == "$1" ]] && return 0
  done
  return 1
}

# ==============================================================================
# 帮助
# ==============================================================================
overall_help() {
  cat <<EOF
lops — Linux 运维工具箱 v${LOPS_VERSION}
==============================================================================
集成 Linux 基础运维能力的统一工具，交互菜单与子命令双模式。

用法:
  ./lops.sh                          交互式主菜单
  ./lops.sh <module>                 模块交互菜单
  ./lops.sh <module> <action> [参数]  子命令直达
  ./lops.sh <module> help            模块详细帮助

可用模块:
EOF
  local m desc
  for m in "${LOPS_MODS[@]}"; do
    desc="$(mod_"${m}"_desc)"
    printf "  %-10s %s\n" "$m" "$desc"
  done
  cat <<'EOF'

常用示例:
  ./lops.sh                          # 主菜单，按编号一键执行
  ./lops.sh init all                 # 新服务器一键初始化
  ./lops.sh disk ls                  # 查看磁盘与挂载概览
  ./lops.sh monitor check            # 一键健康巡检（CPU/内存/磁盘/服务）
  ./lops.sh info all                 # 服务器硬件信息报表
  ./lops.sh backup dir /data         # 备份目录
  ./lops.sh help                     # 本帮助

说明:
  - 危险操作（格式化磁盘、删除用户等）会要求二次确认，输入 y 才会执行
  - 需要写系统配置的动作会自动校验 root 权限，无需 sudo 前缀
  - 所有操作记录日志: /var/log/lops/lops.log
EOF
}

# ==============================================================================
# 菜单
# ==============================================================================
main_menu() {
  while true; do
    echo ""
    banner "lops v${LOPS_VERSION} — Linux 运维工具箱"
    local opts=() m
    for m in "${LOPS_MODS[@]}"; do
      opts+=("${m} — $(mod_"${m}"_desc)")
    done
    opts+=("help — 查看总帮助")
    local choice
    choice="$(menu_choose "请选择功能模块" "${opts[@]}")"
    if (( choice == 0 )); then
      echo "再见。"
      return 0
    fi
    if (( choice == ${#LOPS_MODS[@]} + 1 )); then
      overall_help
      pause_enter
      continue
    fi
    module_menu "${LOPS_MODS[$((choice - 1))]}"
  done
}

module_menu() {
  local mod="$1"
  mod_exists "$mod" || die "未知模块: $mod"

  while true; do
    echo ""
    banner "lops ${mod} — $(mod_"${mod}"_desc)"
    # 解析动作清单
    local lines=() action desc opts=()
    while IFS='|' read -r action desc; do
      [[ -z "$action" ]] && continue
      lines+=("${action}|${desc}")
      opts+=("${action} — ${desc}")
    done < <(mod_"${mod}"_actions)
    opts+=("help — 模块详细帮助")

    local choice
    choice="$(menu_choose "请选择动作" "${opts[@]}")"
    if (( choice == 0 )); then
      return 0
    fi
    if (( choice == ${#lines[@]} + 1 )); then
      mod_"${mod}"_help
      pause_enter
      continue
    fi
    local picked="${lines[$((choice - 1))]}"
    local run_action="${picked%%|*}"
    echo ""
    section "执行: lops ${mod} ${run_action}"
    if mod_"${mod}"_run "$run_action"; then
      echo ""
      echo -e "${GREEN}✔ 动作完成: ${mod} ${run_action}${NC}"
    else
      echo ""
      echo -e "${RED}✘ 动作失败: ${mod} ${run_action}（详见上方日志）${NC}"
    fi
    pause_enter
  done
}

# ==============================================================================
# 分发
# ==============================================================================
usage_short() {
  cat <<EOF
lops v${LOPS_VERSION} — Linux 运维工具箱

用法:
  ./lops.sh                          交互式主菜单
  ./lops.sh <module> [action] [参数]  子命令模式
  ./lops.sh help                     总帮助
  ./lops.sh <module> help            模块详细帮助
EOF
}

main() {
  if (( $# == 0 )); then
    main_menu
    return 0
  fi

  local module="$1"
  case "$module" in
    help|-h|--help)
      overall_help
      return 0
      ;;
    version|-v|--version)
      echo "lops v${LOPS_VERSION}"
      return 0
      ;;
  esac

  mod_exists "$module" || { usage_short >&2; die "未知模块: ${module}（执行 ./lops.sh help 查看模块清单）"; }

  if (( $# == 1 )); then
    module_menu "$module"
    return 0
  fi

  local action="$2"
  if [[ "$action" == "help" || "$action" == "-h" || "$action" == "--help" ]]; then
    mod_"${module}"_help
    return 0
  fi

  shift 1
  mod_"${module}"_run "$@"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
