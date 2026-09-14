#!/usr/bin/env bash
# ==============================================================================
# lops 菜单渲染库
# 提供编号菜单选择、暂停等交互 UI，供 lops.sh 与各模块菜单使用。
# ==============================================================================

# 用法: menu_choose "标题" "选项1" "选项2" ...
# 输出: 所选序号（从 1 开始）到 stdout；0 表示返回/取消
# 说明: 非交互环境（无 tty）自动返回 0，避免脚本卡死
menu_choose() {
  local title="$1"
  shift
  local opts=("$@")

  if [[ ! -t 0 ]]; then
    # 注意: 警告必须走 stderr，避免污染 stdout 的返回值
    echo -e "${YELLOW}[WARN] 非交互环境，无法显示菜单（请使用子命令模式: lops.sh <module> <action>）${NC}" >&2
    echo 0
    return 0
  fi

  echo -e "${CYAN}${BOLD}== ${title}${NC}"
  local i=1
  for o in "${opts[@]}"; do
    printf "  %2d) %s\n" "$i" "$o"
    i=$((i + 1))
  done
  printf "   0) 返回上级\n"

  local choice
  local max=$(( ${#opts[@]} ))
  while true; do
    read -r -p "请选择 [0-${max}]: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 0 && choice <= max )); then
      echo "$choice"
      return 0
    fi
    echo -e "${RED}无效输入，请输入 0-${max} 之间的数字${NC}"
  done
}

# 暂停等待回车（仅交互环境）
pause_enter() {
  [[ -t 0 ]] || return 0
  local _
  read -r -p "按回车键返回..." _
}
