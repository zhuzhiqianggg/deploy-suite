#!/usr/bin/env bash
# ==============================================================================
# lops 模块: info — 服务器信息报表
# ==============================================================================

mod_info_desc() {
  echo "信息报表（系统/CPU/内存/磁盘/网卡/GPU 硬件清单）"
}

mod_info_actions() {
  cat <<'EOF'
all|完整硬件与系统报表（系统/CPU/内存/磁盘/网卡/GPU）
os|仅操作系统版本与内核信息
net|网络信息（IP/路由/DNS/公网出口）
gpu|GPU 详情（nvidia-smi）
EOF
}

mod_info_help() {
  cat <<EOF
lops info — 服务器信息报表
==============================================================================
只读采集服务器硬件与系统信息，输出对齐的中文报表。
全部动作无需 root、不修改任何配置，可放心在任何机器执行。

用法:
  ./lops.sh info <action>

动作说明:
  all     完整报表，分节输出:
            系统信息 — 发行版/内核/主机名/运行时长/虚拟化平台
            CPU      — 型号/物理核/逻辑核/当前负载
            内存     — 总量/已用/使用率（按阈值着色）
            磁盘     — lsblk 块设备概览 + df 文件系统使用
            网卡     — ip -br addr 各网卡地址
            GPU      — nvidia-smi 型号/显存/驱动（未安装则提示）
  os      仅操作系统与内核: /etc/os-release 关键字段、内核版本、
          是否容器环境。
  net     网络信息: 各网卡 IP、默认路由、DNS 配置、
          公网出口 IP（curl 3 秒超时，失败自动跳过）。
  gpu     GPU 详情: nvidia-smi 完整输出；未安装时给出安装命令。

示例:
  ./lops.sh info all          # 新接手机器，先跑一份完整报表
  ./lops.sh info os           # 快速确认系统版本
  ./lops.sh info net          # 排查网络/确认出口 IP
  ./lops.sh info gpu          # GPU 服务器检查显卡状态

前置条件:
  - 全部只读，无需 root
  - GPU 采集依赖 nvidia-smi（缺失时输出安装提示，不影响其他部分）

注意事项:
  - net 的公网出口 IP 需要外网连通，内网环境自动跳过。
  - all 报表可作为服务器交付/巡检的快照存档。
EOF
}

# ---------- 动作实现 ----------

info__os() {
  section "操作系统信息"
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    print_kv "发行版" "${PRETTY_NAME:-unknown}"
    print_kv "ID / 版本" "${ID:-unknown} / ${VERSION_ID:-unknown}"
  else
    print_kv "发行版" "未知（无 /etc/os-release）"
  fi
  print_kv "内核版本" "$(uname -r)"
  print_kv "主机名" "$(hostname)"
  print_kv "系统位数" "$(uname -m)"
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    print_kv "虚拟化平台" "$(systemd-detect-virt 2>/dev/null || echo unknown)"
  fi
}

info__cpu() {
  section "CPU 信息"
  local model cores threads load
  model="$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs)"
  [[ -z "$model" ]] && model="$(lscpu | grep 'Model name' | cut -d: -f2 | xargs)"
  cores="$(grep -c ^processor /proc/cpuinfo)"
  threads="${cores}"
  if command -v lscpu >/dev/null 2>&1; then
    local sockets phys
    sockets="$(lscpu | awk -F: '/^Socket\(s\)/{gsub(/ /,"",$2); print $2}')"
    phys="$(lscpu | awk -F: '/^Core\(s\) per socket/{gsub(/ /,"",$2); print $2}')"
    [[ -n "$sockets" && -n "$phys" ]] && print_kv "物理核" "$((sockets * phys))"
  fi
  print_kv "型号" "$model"
  print_kv "逻辑核" "$threads"
  read -r load _ < /proc/loadavg
  print_kv "当前负载(1m)" "$load"
}

info__mem() {
  section "内存信息"
  local total used avail
  total="$(free -m | awk '/^Mem:/{print $2}')"
  used="$(free -m | awk '/^Mem:/{print $3}')"
  avail="$(free -m | awk '/^Mem:/{print $7}')"
  if [[ -n "$total" && "$total" -gt 0 ]]; then
    local pct=$(( used * 100 / total ))
    print_kv "总内存" "$(( total / 1024 )) GB ($total MB)"
    print_kv "已用" "$used MB"
    print_kv "可用" "$avail MB"
    printf "  %-24s " "使用率:"
    pct_color "$pct"
  fi
  free -h | grep -E '^(Mem|Swap)'
}

info__disk() {
  section "块设备概览（lsblk）"
  lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL 2>/dev/null || lsblk
  echo ""
  section "文件系统使用（df -hT）"
  df -hT -x tmpfs -x devtmpfs -x overlay
}

info__net() {
  section "网卡地址（ip -br addr）"
  ip -br addr
  echo ""
  section "默认路由"
  ip route | grep -E '^default' || warn "无默认路由"
  echo ""
  section "DNS 配置"
  grep nameserver /etc/resolv.conf 2>/dev/null || warn "resolv.conf 无 nameserver"
  echo ""
  section "公网出口 IP"
  local pub
  pub="$(curl -s --max-time 3 ifconfig.me 2>/dev/null || true)"
  if [[ -n "$pub" ]]; then
    print_kv "公网出口" "$pub"
  else
    mark_warn "无法获取公网出口 IP（内网或无外网，已跳过）"
  fi
}

info__gpu() {
  section "GPU 信息"
  if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=index,name,memory.total,driver_version,utilization.gpu --format=csv
  else
    mark_warn "未检测到 nvidia-smi"
    echo "  安装: apt install nvidia-utils 或 yum install nvidia-utils"
  fi
}

info__all() {
  banner "lops info — 服务器信息报表"
  info__os
  info__cpu
  info__mem
  info__disk
  info__net
  info__gpu
  echo ""
  mark_ok "报表采集完成"
}

# ---------- 动作分发 ----------
mod_info_run() {
  local action="${1:-}"
  [[ -z "$action" ]] && { mod_info_help; return 1; }
  shift || true

  case "$action" in
    all) info__all ;;
    os)  info__os ;;
    net) info__net ;;
    gpu) info__gpu ;;
    *)
      err "未知动作: info ${action}"
      mod_info_help
      return 1
      ;;
  esac
}
