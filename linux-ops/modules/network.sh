#!/usr/bin/env bash
# ==============================================================================
# lops 模块: network — 网络测试
# ==============================================================================
# 功能:
#   - server  启动 iperf3 服务端（nohup 常驻，多实例端口递增）
#   - client  iperf3 客户端带宽测试（上行 + 下行，输出带宽摘要）
#   - mtr     MTR 路由质量测试（报告模式，提示丢包异常跳点）
#   - speed   HTTP 下载测速（curl 限时下载大文件，输出 MB/s 与 Mbps）
#   - ports   本机监听端口与连接概览（ss -s + ss -tulpn，只读）
# 依赖: iperf3 / mtr 未安装时自动通过系统源安装；speed 需要 curl。
# ==============================================================================

# 可配置项（执行前可通过环境变量覆盖，见 mod_network_help）
LOPS_NET_IPERF_PORT="${LOPS_NET_IPERF_PORT:-5201}"        # server/client 默认端口
LOPS_NET_IPERF_INSTANCES="${LOPS_NET_IPERF_INSTANCES:-1}" # server 默认实例数
LOPS_NET_IPERF_TIME="${LOPS_NET_IPERF_TIME:-10}"          # client 默认测试时长（秒）
LOPS_NET_MTR_COUNT="${LOPS_NET_MTR_COUNT:-100}"           # mtr 默认探测包数
LOPS_NET_SPEED_URL="${LOPS_NET_SPEED_URL:-https://mirrors.aliyun.com/centos-stream/9-stream/BaseOS/x86_64/iso/CentOS-Stream-9-latest-x86_64-dvd1.iso}"
LOPS_NET_SPEED_TIME="${LOPS_NET_SPEED_TIME:-10}"          # speed 默认下载时长（秒）

mod_network_desc() {
  echo "网络测试（iperf3 带宽/MTR 路由/下载测速/端口概览）"
}

mod_network_actions() {
  cat <<'EOF'
server|启动 iperf3 服务端（默认端口 5201，nohup 常驻，日志落 /var/log/lops）
client|iperf3 客户端带宽测试（上行 + 下行，输出带宽摘要）
mtr|MTR 路由质量测试（-rwbc 100 报告模式，提示丢包异常跳点）
speed|快速下载测速（curl 大文件限时下载，输出 MB/s 与 Mbps）
ports|本机监听端口与连接概览（ss -s + ss -tulpn，只读）
EOF
}

mod_network_help() {
  cat <<'EOF'
lops network — 网络测试
==============================================================================
集成 iperf3 带宽测试、MTR 路由质量分析与 HTTP 下载测速，
覆盖内网互连压测、公网链路排查、出网带宽验证等场景。
iperf3 / mtr 缺失时自动安装，所有动作不硬编码任何 IP/地址。

用法:
  ./lops.sh network <action> [参数]

动作说明:
  server [起始端口] [实例数]
      启动 iperf3 服务端（TCP 带宽测试对端）。默认起始端口 5201、
      默认 1 个实例；多实例端口连续递增（如 5201 + 4 实例 = 5201~5204）。
      以 nohup 方式后台常驻，日志写入 /var/log/lops/iperf3-<端口>.log，
      PID 记录于 /var/log/lops/iperf3-<端口>.pid；
      端口已被监听时提示并跳过（不重复启动）。
  client <host> [port] [时长秒]
      iperf3 客户端带宽测试。默认端口 5201、默认时长 10 秒。
      依次测试上行（本机 → host）与下行（host → 本机，-R 反向模式），
      每个方向输出逐秒明细，最后汇总带宽摘要（传输量 + 速率）。
  mtr <host>
      MTR 路由质量测试（mtr -rwbc 100 报告模式，100 个探测包，
      约需 100 秒）。输出逐跳丢包率/延迟统计表，并对 Loss% > 0 的
      跳点单独提示，附解读说明（区分 ICMP 限速与真实丢包）。
  speed
      快速网速测试: curl 从国内镜像源（默认阿里云）下载大文件，
      限时 10 秒断开，输出下载量、下载速度（MB/s）与等效带宽（Mbps）。
  ports
      本机网络概览: ss -s 连接统计摘要 + ss -tulpn 监听端口明细。
      只读操作，不修改任何配置。

可配置环境变量（执行前 export 覆盖默认值）:
  LOPS_NET_IPERF_PORT=5201         # server/client 默认端口
  LOPS_NET_IPERF_INSTANCES=1       # server 默认实例数
  LOPS_NET_IPERF_TIME=10           # client 默认测试时长（秒）
  LOPS_NET_MTR_COUNT=100           # mtr 探测包数量
  LOPS_NET_SPEED_URL=<url>         # speed 测速地址（默认阿里云 CentOS 大文件）
  LOPS_NET_SPEED_TIME=10           # speed 下载时长（秒）

示例:
  sudo ./lops.sh network server                        # 5201 端口启动单实例
  sudo ./lops.sh network server 5201 4                 # 5201~5204 共 4 个实例
  ./lops.sh network client 10.0.0.31                   # 对 10.0.0.31 双向测试 10 秒
  ./lops.sh network client 10.0.0.31 5202 30           # 指定端口、测试 30 秒
  ./lops.sh network mtr www.example.com                # 路由质量测试
  LOPS_NET_MTR_COUNT=50 ./lops.sh network mtr 223.5.5.5  # 50 包快速探测
  ./lops.sh network speed                              # 下载测速
  ./lops.sh network ports                              # 查看监听端口概览

前置条件:
  - server 需要 root（创建 /var/log/lops 日志目录、常驻后台进程）
  - client / mtr / speed / ports 普通用户可执行；
    mtr 需建立 ICMP 原始套接字，部分发行版（如 CentOS）要求 root，
    失败时按提示加 sudo 重试即可
  - client 需要对端已运行 iperf3 服务端（对端执行 lops network server）
  - speed 需要可访问 mirrors.aliyun.com；mtr/client 需网络可达目标

注意事项:
  - 交互环境（终端）下缺失参数会提示输入（可选项带默认值回车确认）；
    非交互环境缺失必填参数时直接报错并打印用法，便于脚本自动化调用。
  - 多实例压测请在两端防火墙/安全组放行对应端口范围。
  - speed 为单线程 HTTP 下载，结果受 CDN 调度与单连接限速影响，
    精确带宽请用 iperf3 在内网/专线两端对测。
  - 停止服务端: kill $(cat /var/log/lops/iperf3-<端口>.pid)，
    或一次性停止全部: pkill -f 'iperf3 -s'。
EOF
}

# ---------- 内部工具 ----------

# 确保 iperf3 可用；未安装则自动通过系统源安装
network__ensure_iperf3() {
  if ! command -v iperf3 >/dev/null; then
    warn "未检测到 iperf3，尝试自动安装..."
    if ! pkg_install iperf3; then
      err "iperf3 自动安装失败，请手动安装: sudo apt-get install -y iperf3 或 sudo yum install -y iperf3"
      return 1
    fi
  fi
}

# 确保 mtr 可用；未安装则自动安装（Debian 系用轻量的 mtr-tiny）
network__ensure_mtr() {
  if ! command -v mtr >/dev/null; then
    warn "未检测到 mtr，尝试自动安装..."
    detect_os
    if is_debian_family; then
      if ! pkg_install mtr-tiny; then
        err "mtr 安装失败，请手动安装: sudo apt-get install -y mtr-tiny"
        return 1
      fi
    else
      if ! pkg_install mtr; then
        err "mtr 安装失败，请手动安装: sudo yum install -y mtr"
        return 1
      fi
    fi
  fi
}

# 正整数参数校验: network__check_num <值> <参数名> <最小> <最大>
network__check_num() {
  [[ "$1" =~ ^[0-9]+$ ]] || { err "参数 $2 必须为正整数，当前值: $1"; return 1; }
  (( "$1" >= "$3" && "$1" <= "$4" )) || { err "参数 $2 超出范围 [$3, $4]，当前值: $1"; return 1; }
}

# 必填参数缺失时的统一处理: 交互环境提示输入，非交互环境报错并打印用法
network__ask_host() {
  local host=""
  if [[ -t 0 ]]; then
    host="$(ask_value "目标主机（IP 或域名）")"
  else
    err "缺少必填参数 <host>: ./lops.sh network <action> <host> [参数]"
    mod_network_help
    return 1
  fi
  [[ -n "$host" ]] || { err "未输入目标主机"; return 1; }
  echo "$host"
}

# ---------- 动作实现 ----------

# 启动 iperf3 服务端（nohup 常驻，多实例端口递增）
network__server() {
  require_root
  network__ensure_iperf3 || return 1

  local port="${1:-}" instances="${2:-}"
  # 交互环境下可选参数缺失时提示输入（带默认值），非交互环境直接取默认值
  if [[ -z "$port" ]]; then
    if [[ -t 0 ]]; then
      port="$(ask_value "iperf3 起始端口" "${LOPS_NET_IPERF_PORT}")"
    else
      port="${LOPS_NET_IPERF_PORT}"
    fi
  fi
  port="${port:-$LOPS_NET_IPERF_PORT}"
  if [[ -z "$instances" ]]; then
    if [[ -t 0 ]]; then
      instances="$(ask_value "启动实例数" "${LOPS_NET_IPERF_INSTANCES}")"
    else
      instances="${LOPS_NET_IPERF_INSTANCES}"
    fi
  fi
  instances="${instances:-$LOPS_NET_IPERF_INSTANCES}"

  network__check_num "$port" "起始端口" 1 65535 || return 1
  network__check_num "$instances" "实例数" 1 64 || return 1

  mkdir -p "${LOPS_LOG_DIR}" || { err "无法创建日志目录 ${LOPS_LOG_DIR}"; return 1; }

  section "启动 iperf3 服务端（起始端口 ${port}，实例数 ${instances}）"
  local i p pid started=0
  for (( i = 0; i < instances; i++ )); do
    p=$(( port + i ))
    if (( p > 65535 )); then
      err "端口 ${p} 超出 65535，剩余实例未启动"
      break
    fi
    # 端口已被监听（IPv4/IPv6 均查）则提示跳过，保证幂等
    if [[ -n "$(ss -H -tln "sport = :${p}")" ]]; then
      warn "端口 ${p} 已有服务监听，疑似实例已在运行，跳过（日志: ${LOPS_LOG_DIR}/iperf3-${p}.log）"
      continue
    fi
    nohup iperf3 -s -p "$p" --logfile "${LOPS_LOG_DIR}/iperf3-${p}.log" >/dev/null &
    pid=$!
    echo "${pid}" > "${LOPS_LOG_DIR}/iperf3-${p}.pid"
    log "iperf3 服务端已启动: 端口 ${p}，PID ${pid}，日志 ${LOPS_LOG_DIR}/iperf3-${p}.log"
    started=$(( started + 1 ))
  done

  if (( started == 0 )); then
    warn "本轮未新启动任何 iperf3 实例（所有端口均已被占用）"
  fi

  section "如何停止"
  cat <<EOF
  停止单个实例: kill \$(cat ${LOPS_LOG_DIR}/iperf3-<端口>.pid)
  停止全部实例: pkill -f 'iperf3 -s'
  实时查看日志: tail -f ${LOPS_LOG_DIR}/iperf3-<端口>.log
EOF
  log "对端测试命令: ./lops.sh network client <本机IP> ${port} [时长秒]"
}

# iperf3 客户端带宽测试（上行 + 下行，输出带宽摘要）
network__client() {
  local host="${1:-}" port="${2:-}" dur="${3:-}"
  # host 必填: 交互环境提示输入，非交互环境报错并打印用法
  if [[ -z "$host" ]]; then
    host="$(network__ask_host)" || return 1
  fi
  # port / 时长可选: 交互环境带默认值询问，非交互环境直接取默认值
  if [[ -z "$port" ]]; then
    if [[ -t 0 ]]; then
      port="$(ask_value "目标端口" "${LOPS_NET_IPERF_PORT}")"
    else
      port="${LOPS_NET_IPERF_PORT}"
    fi
  fi
  port="${port:-$LOPS_NET_IPERF_PORT}"
  if [[ -z "$dur" ]]; then
    if [[ -t 0 ]]; then
      dur="$(ask_value "测试时长（秒）" "${LOPS_NET_IPERF_TIME}")"
    else
      dur="${LOPS_NET_IPERF_TIME}"
    fi
  fi
  dur="${dur:-$LOPS_NET_IPERF_TIME}"

  network__check_num "$port" "端口" 1 65535 || return 1
  network__check_num "$dur" "测试时长" 1 3600 || return 1

  # 参数校验通过后再检查依赖（避免无效参数时仍触发自动安装）
  network__ensure_iperf3 || return 1

  section "iperf3 带宽测试: ${host}:${port}（每方向 ${dur} 秒）"
  local up_out="" dn_out=""

  echo "→ 上行测试（本机 → ${host}）..."
  if ! up_out="$(iperf3 -c "$host" -p "$port" -t "$dur")"; then
    err "上行测试失败: 无法与 ${host}:${port} 建立测试（确认服务端已启动、防火墙已放行）"
    return 1
  fi
  echo "$up_out"
  echo ""

  echo "→ 下行测试（${host} → 本机，-R 反向模式）..."
  if ! dn_out="$(iperf3 -c "$host" -p "$port" -t "$dur" -R)"; then
    err "下行测试失败: ${host}:${port} 反向测试未完成"
    return 1
  fi
  echo "$dn_out"

  section "带宽摘要"
  printf '  上行（本机 → %s）: %s\n' "$host" \
    "$(echo "$up_out" | awk '/sender$/ {s=$0} END {print s}')"
  printf '  下行（%s → 本机）: %s\n' "$host" \
    "$(echo "$dn_out" | awk '/sender$/ {s=$0} END {print s}')"
  log "iperf3 测试完成（逐秒明细见上方输出）"
}

# MTR 路由质量测试（-rwbc N 报告模式 + 丢包跳点分析）
network__mtr() {
  local host="${1:-}"
  if [[ -z "$host" ]]; then
    host="$(network__ask_host)" || return 1
  fi

  local count="$LOPS_NET_MTR_COUNT"
  network__check_num "$count" "探测次数(LOPS_NET_MTR_COUNT)" 1 1000 || return 1

  # 参数校验通过后再检查依赖（避免无效参数时仍触发自动安装）
  network__ensure_mtr || return 1

  section "MTR 路由质量测试: ${host}（${count} 个探测包，约 ${count} 秒）"
  log "测试进行中，请耐心等待..."
  local mtr_out=""
  if ! mtr_out="$(mtr -rwbc "$count" "$host")"; then
    err "mtr 执行失败（部分发行版需要 root 建立 ICMP 套接字），可尝试: sudo ./lops.sh network mtr ${host}"
    return 1
  fi
  echo "$mtr_out"

  # 解析报告: 找出 Loss% > 0 的跳点（跳过 Start 行与表头行，列位置自适应）
  section "丢包分析"
  local loss_lines=""
  loss_lines="$(echo "$mtr_out" | awk 'NR > 2 {
    for (i = 2; i <= NF; i++) {
      if ($i ~ /%$/) {
        v = $i; sub(/%/, "", v)
        if (v + 0 > 0) { print; break }
      }
    }
  }')"
  if [[ -n "$loss_lines" ]]; then
    warn "以下跳点丢包率大于 0%:"
    echo "$loss_lines"
    warn "解读提示: 中间跳丢包常为路由器 ICMP 速率限制（不影响转发的业务流量）；若从某一跳起到目的端持续丢包，才代表真实链路质量问题"
  else
    log "全部跳点丢包率均为 0%，链路质量良好"
  fi
}

# 快速网速测试（curl 限时下载大文件）
network__speed() {
  if ! command -v curl >/dev/null; then
    err "缺少 curl，请先安装: sudo apt-get install -y curl 或 sudo yum install -y curl"
    return 1
  fi

  local url="${LOPS_NET_SPEED_URL}" secs="${LOPS_NET_SPEED_TIME}"
  network__check_num "$secs" "测速时长(LOPS_NET_SPEED_TIME)" 1 120 || return 1

  section "HTTP 下载测速（限时 ${secs} 秒）"
  log "测速地址: ${url}"
  echo "下载中，请稍候..."

  # --max-time 到时主动断开（curl 退出码 28 属预期，不影响 -w 输出）
  # -w 依次输出: 平均速度(字节/秒) 下载总量(字节) 总耗时(秒)
  local raw=""
  raw="$(curl -fsSL -o /dev/null --max-time "$secs" \
    -w '%{speed_download} %{size_download} %{time_total}' "$url")" || true

  local spd="" size="" tsec=""
  read -r spd size tsec <<<"${raw}"
  # 校验测速结果有效（非空、为数字且大于 0）
  if [[ -z "$spd" ]] || ! [[ "$spd" =~ ^[0-9.]+$ ]] \
    || ! awk -v x="$spd" 'BEGIN { exit (x > 0) ? 0 : 1 }'; then
    err "测速失败: 无法从测速地址下载数据（地址失效或网络不可达）"
    return 1
  fi

  awk -v b="$spd" -v n="${size:-0}" -v t="${tsec:-0}" 'BEGIN {
    printf "  下载量:   %.2f MB\n", n / 1024 / 1024
    printf "  耗时:     %.1f 秒\n", t
    printf "  下载速度: %.2f MB/s\n", b / 1024 / 1024
    printf "  等效带宽: %.1f Mbps\n", b * 8 / 1000000
  }'
  log "说明: 单线程 HTTP 下载，结果受 CDN 调度与单连接限速影响，仅供参考"
}

# 本机监听端口与连接概览（只读）
network__ports() {
  if ! command -v ss >/dev/null; then
    err "缺少 ss 命令（iproute2），请先安装后重试"
    return 1
  fi

  section "TCP/UDP 连接概览（ss -s）"
  ss -s
  section "本机监听端口明细（ss -tulpn）"
  ss -tulpn
  hr
  warn "非 root 用户执行时进程归属可能显示不全，加 sudo 可查看全部进程信息"
}

# ---------- 动作分发 ----------

mod_network_run() {
  local action="${1:-}"
  [[ -z "$action" ]] && { mod_network_help; return 1; }
  shift || true

  case "$action" in
    server) network__server "$@" ;;
    client) network__client "$@" ;;
    mtr)    network__mtr "$@" ;;
    speed)  network__speed "$@" ;;
    ports)  network__ports "$@" ;;
    *)
      err "未知动作: network ${action}"
      mod_network_help
      return 1
      ;;
  esac
}
