#!/usr/bin/env bash
# ==============================================================================
# lops 模块: doctor — 环境自检
# ==============================================================================
# 功能:
#   - check  只读自检: OS/权限/日志目录/日志轮转 + 各模块依赖命令可用性
#            缺失项按当前发行版汇总出一条安装命令，复制即用
#   不安装、不修改任何东西，随时可安全执行。
# ==============================================================================

mod_doctor_desc() {
  echo "环境自检（依赖命令/日志/轮转配置一键检查）"
}

mod_doctor_actions() {
  cat <<'EOF'
check|只读自检: 运行环境/日志/各模块依赖命令，缺失项给出安装命令
EOF
}

mod_doctor_help() {
  cat <<'EOF'
lops doctor — 环境自检
==============================================================================
执行 lops 各模块前先跑一遍自检，避免执行到一半才发现缺依赖命令。
纯只读检查，不安装、不修改任何配置，任何用户可执行。

用法:
  ./lops.sh doctor check

检查内容:
  1. 运行环境    OS 发行版、当前用户、lops 版本、日志目录可写性
  2. 日志轮转    /etc/logrotate.d/lops 是否已配置（lops init logrotate 生成）
  3. 模块依赖    按模块逐个检查外部命令是否可用:
     - 基础:    tar curl
     - disk:    fio（性能测试） smartctl（SMART 健康）
     - ssh:     ssh sshd ssh-copy-id expect
     - network: iperf3 mtr ss
     - monitor: iostat pidstat smartctl
     - docker:  docker（未装属正常，仅提示）
     - info:    nvidia-smi（仅 GPU 机器需要，仅提示）

输出说明:
  - ✓ 命令可用  ✘ 命令缺失（附所属模块）
  - 结尾按当前发行版汇总一条安装命令，复制执行即可补齐
  - docker / nvidia-smi 为可选项，缺失只提示不计入缺失统计

示例:
  ./lops.sh doctor check        # 自检
  ./lops.sh doctor              # 同上（check 为默认动作）

前置条件:
  - 无（只读操作，不需要 root；root 下日志目录检查结果更准确）

注意事项:
  - 自检只报告，不代替安装；缺失命令请用汇总的安装命令补齐后复检
  - fio/iperf3 等测试类工具按需安装，不用磁盘/网络测试可不装
EOF
}

# ---------- 内部辅助 ----------

# _doctor_cmd_ok <命令> → 可用返回 0
_doctor_cmd_ok() { command -v "$1" >/dev/null 2>&1; }

# 检查并登记缺失依赖: _doctor_check <模块> <命令> <deb包> <rhel包>
_doctor_check() {
  local mod="$1" cmd="$2" deb_pkg="$3" rhel_pkg="$4"
  if _doctor_cmd_ok "$cmd"; then
    printf "  ✓ %-14s %s\n" "$cmd" "[$mod]"
  else
    printf "  ✘ %-14s %s — 缺失\n" "$cmd" "[$mod]"
    local pkg="$rhel_pkg"
    is_debian_family && pkg="$deb_pkg"
    _DOCTOR_MISSING_PKGS["$pkg"]=1
    _DOCTOR_MISSING_N=$((_DOCTOR_MISSING_N + 1))
  fi
}

# 仅提示不计数（可选依赖）: _doctor_hint <模块> <命令> <说明>
_doctor_hint() {
  local mod="$1" cmd="$2" note="$3"
  if _doctor_cmd_ok "$cmd"; then
    printf "  ✓ %-14s %s\n" "$cmd" "[$mod]"
  else
    printf "  - %-14s %s — ${note}\n" "$cmd" "[$mod]"
  fi
}

# ---------- 动作实现 ----------

doctor__check() {
  detect_os
  banner "lops doctor — 环境自检"

  section "1/4 运行环境"
  print_kv "lops 版本" "v${LOPS_VERSION}"
  if (( EUID == 0 )); then
    mark_ok "当前为 root，全部动作可用"
  else
    mark_warn "当前为普通用户 $(id -un)，写系统配置的动作需 sudo 执行"
  fi

  section "2/4 日志目录与轮转"
  if [[ -d "${LOPS_LOG_DIR}" && -w "${LOPS_LOG_DIR}" ]]; then
    print_kv "日志目录" "${LOPS_LOG_DIR}（可写）"
    print_kv "当前日志大小" "$(du -h "${LOPS_LOG_DIR}/lops.log" 2>/dev/null | awk '{print $1}' || echo '尚未产生')"
  else
    mark_warn "日志目录 ${LOPS_LOG_DIR} 不可写（非 root 属正常，日志将跳过落盘）"
  fi
  if [[ -f /etc/logrotate.d/lops ]]; then
    mark_ok "日志轮转已配置（/etc/logrotate.d/lops）"
  else
    mark_warn "日志轮转未配置，lops.log 会无限增长（root 执行 lops.sh init logrotate 生成）"
  fi

  section "3/4 模块依赖命令"
  # 声明在函数外无法跨调用保留，这里在入口处初始化
  printf "  %s\n" "—— 基础（backup/通用）——"
  _doctor_check backup tar tar tar
  _doctor_check network curl curl curl

  printf "  %s\n" "—— disk ——"
  _doctor_check disk fio fio fio
  _doctor_check disk smartctl smartmontools smartmontools

  printf "  %s\n" "—— ssh ——"
  _doctor_check ssh ssh openssh-client openssh-clients
  _doctor_check ssh sshd openssh-server openssh-server
  _doctor_check ssh ssh-copy-id openssh-client openssh-clients
  _doctor_check ssh expect expect expect

  printf "  %s\n" "—— network ——"
  _doctor_check network iperf3 iperf3 iperf3
  _doctor_check network mtr mtr-tiny mtr
  _doctor_check network ss iproute2 iproute

  printf "  %s\n" "—— monitor ——"
  _doctor_check monitor iostat sysstat sysstat
  _doctor_check monitor pidstat sysstat sysstat

  printf "  %s\n" "—— 可选（缺失仅提示）——"
  _doctor_hint docker docker "未安装 Docker，需要时执行 lops.sh docker install"
  _doctor_hint info nvidia-smi "无 GPU 或驱动未装，仅 GPU 机器需要"

  section "4/4 汇总"
  if (( _DOCTOR_MISSING_N == 0 )); then
    mark_ok "必需依赖全部就绪"
  else
    local -a pkgs=()
    local p
    for p in "${!_DOCTOR_MISSING_PKGS[@]}"; do pkgs+=("$p"); done
    warn "缺失 ${_DOCTOR_MISSING_N} 个必需依赖，按当前发行版执行以下命令补齐:"
    if is_debian_family; then
      echo "  sudo apt-get install -y ${pkgs[*]}"
    else
      echo "  sudo yum install -y ${pkgs[*]}"
    fi
    echo "  安装后重新执行: ./lops.sh doctor check 复检"
  fi
}

# ---------- 动作分发 ----------

mod_doctor_run() {
  local action="${1:-check}"
  if [[ "$action" == "check" ]]; then
    shift
  fi
  # 缺失依赖登记表（关联数组自动去重）
  declare -gA _DOCTOR_MISSING_PKGS=()
  _DOCTOR_MISSING_N=0

  case "$action" in
    check) doctor__check ;;
    *)
      err "未知动作: doctor ${action}"
      mod_doctor_help
      return 1
      ;;
  esac
}
