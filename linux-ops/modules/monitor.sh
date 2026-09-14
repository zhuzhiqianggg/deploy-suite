#!/usr/bin/env bash
# ==============================================================================
# lops 模块: monitor — 监控与巡检
# ==============================================================================

mod_monitor_desc() {
  echo "监控巡检（一键健康检查/资源排行/node_exporter/磁盘健康监控）"
}

mod_monitor_actions() {
  cat <<'EOF'
check|一键健康巡检（负载/内存/磁盘/IO/网络/失败服务/内核错误）
top|资源占用排行（CPU/内存/IO Top5）
node_exporter|安装并常驻 node_exporter（:9100）
disk_monitor|部署磁盘健康监控 systemd 服务（SMART 上报）
EOF
}

mod_monitor_help() {
  cat <<EOF
lops monitor — 监控与巡检
==============================================================================
日常巡检与监控组件部署：一键健康检查（值班/交接必跑）、
资源占用排行（快速定位吃资源的进程）、node_exporter 与
磁盘健康监控的标准化部署。

用法:
  ./lops.sh monitor <action>

动作说明:
  check           一键健康巡检（只读，无需 root），逐项输出 ✓/⚠/✘:
                    ① 负载       loadavg 与逻辑核数比值（>1 ⚠ / >2 ✘）
                    ② 内存       使用率着色输出 + available 余额（<2GB 异常）
                                + 内存保底水位 vm.min_free_kbytes 检查 + swap 占用
                    ③ 磁盘       空间与 inode 使用率（>=80% ⚠ / >=90% ✘）
                    ④ 磁盘 IO    iostat 采样中 util > 80% 的设备
                    ⑤ 网络       TCP 连接摘要、TIME_WAIT 数量（>5000 ⚠）
                    ⑥ 失败服务   systemctl --failed 列表
                    ⑦ 内核错误   dmesg 最近的 OOM/IO 错误
                  结尾输出异常清单与总体结论。
  top             资源占用排行（只读）：CPU Top5 / 内存 Top5 /
                  IO Top5（pidstat 存在时，否则跳过 IO 部分）。
  node_exporter   安装 node_exporter v1.8.2 到 /opt/monitor/node_exporter/，
                  systemd 常驻监听 :9100，enable --now 并自验证 metrics。
                  已安装则显示版本与状态，幂等。
  disk_monitor    部署磁盘健康监控 systemd 服务：安装 smartmontools、
                  复制 assets/disk_health_monitor.sh 到
                  /opt/monitor/disk_monitor/scripts/、注册
                  disk-health-monitor.service 并 enable --now。
                  该服务周期采集 SMART 指标并上报 PushGateway。

示例:
  ./lops.sh monitor check            # 每日巡检 / 值班交接必跑
  ./lops.sh monitor top              # 机器卡顿，快速看谁在吃资源
  ./lops.sh monitor node_exporter    # 接入 Prometheus 监控
  ./lops.sh monitor disk_monitor     # 部署磁盘健康上报

前置条件:
  - check/top 只读无需 root
  - node_exporter/disk_monitor 需要 root 与外网（或预置安装包）
  - check 的内核错误检查需要 root 才能读 dmesg（无权限自动跳过）

注意事项:
  - disk_monitor 的 PushGateway 上报地址在脚本内配置
    （assets/disk_health_monitor.sh 的 PUSHGATEWAY_URL），部署前按需修改。
  - node_exporter 下载优先走镜像加速，失败自动回退官方源。
EOF
}

# ---------- check ----------

monitor__check() {
  banner "lops monitor check — 一键健康巡检"
  local issues=()

  # ① 负载
  section "① 负载"
  uptime
  local load1 ncpu ratio
  read -r load1 _ < /proc/loadavg
  ncpu="$(grep -c ^processor /proc/cpuinfo)"
  ratio="$(awk -v l="$load1" -v c="$ncpu" 'BEGIN{printf "%.2f", l/c}')"
  print_kv "负载/逻辑核" "${load1}/${ncpu} = ${ratio}"
  if awk -v r="$ratio" 'BEGIN{exit !(r>=2)}'; then
    mark_bad "负载过高（>=2倍核数），列入异常"
    issues+=("负载过高: ${load1}")
  elif awk -v r="$ratio" 'BEGIN{exit !(r>=1)}'; then
    mark_warn "负载偏高（>=1倍核数）"
  else
    mark_ok "负载正常"
  fi

  # ② 内存
  section "② 内存"
  local mt mu mp
  mt="$(free -m | awk '/^Mem:/{print $2}')"
  mu="$(free -m | awk '/^Mem:/{print $3}')"
  mp="$(( mu * 100 / mt ))"
  printf "  %-24s " "内存使用率:"
  pct_color "$mp"
  if (( mp >= 90 )); then
    mark_bad "内存使用 ${mp}%，列入异常"
    issues+=("内存使用率 ${mp}%")
  fi
  free -h | grep -E '^(Mem|Swap)'
  # 可用内存（内存耗尽会触发内核同步回收，导致整机卡死而非单纯 OOM）
  local avail mfk swu
  avail="$(free -m | awk '/^Mem:/{print $7}')"
  if (( avail < 2048 )); then
    mark_bad "可用内存仅 ${avail}MB（<2GB），将触发内核同步回收、整机面临卡死"
    issues+=("可用内存不足 2GB（${avail}MB）")
  elif (( avail < 4096 )); then
    mark_warn "可用内存 ${avail}MB（<4GB），关注内存增长趋势"
  else
    mark_ok "可用内存 ${avail}MB"
  fi
  # 内存水位防线（内核保底空闲内存，防整机卡死；lops init limits 生成）
  mfk="$(sysctl -n vm.min_free_kbytes 2>/dev/null || echo 0)"
  if (( mfk < 131072 )); then
    mark_warn "内存保底水位未配置或过低（vm.min_free_kbytes=${mfk}KB），建议执行: ./lops.sh init limits"
  else
    mark_ok "内存保底水位 vm.min_free_kbytes=${mfk}KB"
  fi
  # swap 占用（延迟敏感服务禁用 swap，越换越卡）
  swu="$(free -m | awk '/^Swap:/{print $3+0}')"
  if (( swu > 0 )); then
    mark_warn "swap 已使用 ${swu}MB，数据库/中间件节点建议禁用 swap"
  fi

  # ③ 磁盘空间与 inode
  section "③ 磁盘空间与 inode"
  df -hP -x tmpfs -x devtmpfs -x overlay | awk 'NR>1 {
    gsub(/%/,"",$5)
    printf "  %-24s %6s  ", $6, $5"%"
    if ($5+0>=90) printf "\033[0;31m✘ 危险\033[0m\n"
    else if ($5+0>=80) printf "\033[1;33m⚠ 警告\033[0m\n"
    else printf "\033[0;32m✓\033[0m\n"
  }'
  local dm
  for dm in $(df -hP -x tmpfs -x devtmpfs -x overlay | awk 'NR>1 && ($5+0)>=90 {print $6}'); do
    mark_bad "挂载点 ${dm} 使用率 >=90%，列入异常"
    issues+=("磁盘 ${dm} 使用率>=90%")
  done
  echo ""
  df -iP -x tmpfs -x devtmpfs -x overlay | awk 'NR>1 && ($5+0)>=90 {printf "  ⚠ inode: %-20s %s\n", $6, $5}'

  # ④ 磁盘 IO
  section "④ 磁盘 IO"
  if command -v iostat >/dev/null 2>&1; then
    local io_out
    io_out="$(iostat -x 1 2 | awk '/^Device/{c++} c==2' | awk '$NF+0>80 {printf "%s(util=%s%%)", $1, $NF}')"
    if [[ -n "$io_out" ]]; then
      mark_bad "高利用率设备: ${io_out}"
      issues+=("磁盘 IO util>80%: ${io_out}")
    else
      mark_ok "磁盘 IO 正常（无 util>80% 设备）"
    fi
  else
    mark_warn "iostat 不可用（sysstat 未安装），跳过 IO 检查"
  fi

  # ⑤ 网络
  section "⑤ 网络"
  ss -s | head -n 4
  local tw
  tw="$(ss -ant | grep -c TIME-WAIT || true)"
  print_kv "TIME_WAIT 数" "$tw"
  if (( tw > 5000 )); then
    mark_warn "TIME_WAIT 偏多（>5000），关注连接复用"
  else
    mark_ok "TCP 连接状态正常"
  fi

  # ⑥ 失败服务
  section "⑥ 失败的 systemd 服务"
  local failed
  failed="$(systemctl --failed --no-legend 2>/dev/null | grep -v '^$' || true)"
  if [[ -n "$failed" ]]; then
    while read -r line; do
      [[ -z "$line" ]] && continue
      mark_bad "$line"
      issues+=("失败服务: $(echo "$line" | awk '{print $1}')")
    done <<< "$failed"
  else
    mark_ok "无失败服务"
  fi

  # ⑦ 内核错误
  section "⑦ 内核错误（dmesg）"
  if dmesg >/dev/null 2>&1; then
    local kerr
    kerr="$(dmesg | tail -n 500 | grep -iE 'oom|i/o error|hardware error|ext4-fs error|xfs.*error' | tail -n 5 || true)"
    if [[ -n "$kerr" ]]; then
      while read -r line; do
        [[ -z "$line" ]] && continue
        mark_bad "$line"
      done <<< "$kerr"
      issues+=("dmesg 存在 OOM/IO 错误")
    else
      mark_ok "最近无 OOM / IO / 硬件错误"
    fi
  else
    mark_warn "无 dmesg 读取权限（需 root），跳过"
  fi

  # 汇总
  echo ""
  banner "巡检结论"
  if (( ${#issues[@]} == 0 )); then
    mark_ok "整体健康，未发现异常项"
  else
    mark_bad "发现 ${#issues[@]} 项异常:"
    local i
    for i in "${issues[@]}"; do
      echo "  ✘ $i"
    done
  fi
}

# ---------- top ----------

monitor__top() {
  section "CPU 占用 Top5"
  ps -eo pid,comm,%cpu,%mem --sort=-%cpu | head -n 6
  echo ""
  section "内存占用 Top5"
  ps -eo pid,comm,%cpu,%mem,rss --sort=-rss | head -n 6 | awk 'NR==1{printf "%-8s %-16s %6s %6s %10s\n","PID","COMMAND","%CPU","%MEM","RSS(MB)"} NR>1{printf "%-8s %-16s %6s %6s %10.1f\n",$1,$2,$3,$4,$5/1024}'
  echo ""
  section "磁盘 IO Top5"
  if command -v pidstat >/dev/null 2>&1; then
    pidstat -d 1 2 | awk '/^Average:/ && $NF!="-" {printf "%-8s %-16s 读:%8sKB/s 写:%8sKB/s\n",$1,$6,$3,$4}' | head -n 6
  else
    mark_warn "pidstat 不可用（sysstat 未安装），跳过 IO 排行"
  fi
}

# ---------- node_exporter ----------

monitor__node_exporter() {
  require_root
  section "node_exporter 安装"
  local node_dir="/opt/monitor/node_exporter"
  local version="1.8.2"
  local tarball="node_exporter-${version}.linux-amd64.tar.gz"

  if systemctl is-active --quiet node_exporter 2>/dev/null; then
    mark_ok "node_exporter 已在运行（systemd active）"
    "${node_dir}/node_exporter" --version 2>/dev/null | head -n 1 || true
    systemctl status node_exporter --no-pager | head -n 5
    return 0
  fi

  mkdir -p "$node_dir"
  local url1="https://mirror.ghproxy.com/https://github.com/prometheus/node_exporter/releases/download/v${version}/${tarball}"
  local url2="https://github.com/prometheus/node_exporter/releases/download/v${version}/${tarball}"
  log "下载 node_exporter v${version}（优先镜像加速）..."
  if ! curl -fsSL --max-time 120 "$url1" -o "/tmp/${tarball}"; then
    log "镜像下载失败，回退官方源..."
    curl -fsSL --max-time 180 "$url2" -o "/tmp/${tarball}" || { err "下载失败，请手动下载 ${tarball} 后放到 /tmp/ 重试"; return 1; }
  fi

  tar -xzf "/tmp/${tarball}" -C /tmp
  install -m 0755 "/tmp/node_exporter-${version}.linux-amd64/node_exporter" "${node_dir}/node_exporter"
  rm -rf "/tmp/node_exporter-${version}.linux-amd64" "/tmp/${tarball}"

  cat > /etc/systemd/system/node_exporter.service <<EOF
[Unit]
Description=Prometheus node_exporter (lops)
After=network.target

[Service]
Type=simple
ExecStart=${node_dir}/node_exporter --web.listen-address=:9100
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now node_exporter
  sleep 2

  if curl -s --max-time 3 http://127.0.0.1:9100/metrics | head -n 3; then
    mark_ok "node_exporter 部署成功并已自验证（:9100/metrics）"
  else
    mark_warn "服务已启动但 metrics 未就绪，请稍后手动验证: curl 127.0.0.1:9100/metrics"
  fi
}

# ---------- disk_monitor ----------

monitor__disk_monitor() {
  require_root
  section "磁盘健康监控部署"
  local src="${LOPS_ROOT}/assets/disk_health_monitor.sh"
  if [[ ! -f "$src" ]]; then
    err "素材脚本缺失: ${src}"
    return 1
  fi

  command -v smartctl >/dev/null 2>&1 || { log "安装 smartmontools..."; pkg_install smartmontools; }

  mkdir -p /opt/monitor/disk_monitor/scripts
  install -m 0755 "$src" /opt/monitor/disk_monitor/scripts/disk_health_monitor.sh

  cat > /etc/systemd/system/disk-health-monitor.service <<'EOF'
[Unit]
Description=Disk Health Monitor - SMART PushGateway Exporter (lops)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/opt/monitor/disk_monitor/scripts/disk_health_monitor.sh --pushgateway
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=disk-health-monitor

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now disk-health-monitor
  sleep 2
  print_kv "服务状态" "$(systemctl is-active disk-health-monitor)"
  print_kv "上报脚本" "/opt/monitor/disk_monitor/scripts/disk_health_monitor.sh"
  log "磁盘健康监控部署完成（SMART 指标周期上报 PushGateway）"
  warn "PushGateway 地址请检查脚本内 PUSHGATEWAY_URL 配置"
}

# ---------- 动作分发 ----------
mod_monitor_run() {
  local action="${1:-}"
  [[ -z "$action" ]] && { mod_monitor_help; return 1; }
  shift || true

  case "$action" in
    check)         monitor__check ;;
    top)           monitor__top ;;
    node_exporter) monitor__node_exporter ;;
    disk_monitor)  monitor__disk_monitor ;;
    *)
      err "未知动作: monitor ${action}"
      mod_monitor_help
      return 1
      ;;
  esac
}
