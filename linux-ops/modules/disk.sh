#!/usr/bin/env bash
# ==============================================================================
# lops 模块: disk — 磁盘管理
# ==============================================================================

LOPS_DISK_TEST_SIZE="${LOPS_DISK_TEST_SIZE:-2G}"
LOPS_DISK_TEST_RUNTIME="${LOPS_DISK_TEST_RUNTIME:-30}"

mod_disk_desc() {
  echo "磁盘管理（概览/格式化挂载/fstab UUID 化/性能测试/SMART 健康）"
}

mod_disk_actions() {
  cat <<'EOF'
ls|磁盘与挂载概览（标注未挂载裸盘），只读
mount|格式化+挂载数据盘+写 fstab（UUID 方式，二次确认）
uuid|将 fstab 中设备名挂载条目改为 UUID 方式（先备份）
test|fio 磁盘性能测试（顺序/随机 × 读/写，输出 IOPS 与带宽）
health|SMART 健康快照（重映射/待定扇区/温度/通电时长）
EOF
}

mod_disk_help() {
  cat <<EOF
lops disk — 磁盘管理
==============================================================================
覆盖数据盘上线全流程：查看概览 → 格式化挂载（自动写 fstab）→
fstab UUID 加固 → 性能测试 → SMART 健康巡检。
危险操作（格式化）强制二次确认，fstab 修改前自动备份。

用法:
  ./lops.sh disk <action> [参数]

动作说明:
  ls                          磁盘与挂载概览：lsblk 块设备 + df 文件系统，
                              并单独标注"未挂载且无文件系统"的裸盘。
  mount <device> <挂载点> [fstype]
                              数据盘上线：mkfs 格式化（默认 ext4，可选 xfs）
                              → 挂载 → blkid 取 UUID → 追加 fstab 条目
                              "UUID=xxx <挂载点> <fstype> defaults,nofail 0 2"
                              → findmnt --verify 校验。
                              已有文件系统或已挂载的盘会拒绝执行；
                              格式化前显示目标盘信息并要求确认。
  uuid                        把 /etc/fstab 中以设备路径（/dev/sdX、/dev/vdX、
                              /dev/nvmeXnY）挂载的条目全部改为 UUID= 方式，
                              防止盘符漂移导致启动挂载失败。
  test [目录]                 fio 性能测试（默认 /tmp）。四个场景:
                              顺序写(128k) / 顺序读(128k) /
                              随机写(4k) / 随机读(4k)，iodepth=64 direct=1，
                              结尾表格汇总各场景带宽与 IOPS。
  health                      SMART 健康快照：逐盘输出 overall 状态与
                              关键指标（重映射扇区/待定扇区/温度/通电时长，
                              NVMe 盘输出磨损度与可用备用空间），
                              异常值红色标注。

可配置环境变量（test 动作）:
  LOPS_DISK_TEST_SIZE=2G        # 测试文件大小
  LOPS_DISK_TEST_RUNTIME=30     # 单场景时长（秒）

示例:
  ./lops.sh disk ls                            # 查看磁盘概览与裸盘
  ./lops.sh disk mount /dev/sdb /data ext4     # 格式化 sdb 挂到 /data
  ./lops.sh disk mount /dev/nvme1n1 /data-01 xfs
  ./lops.sh disk uuid                          # fstab 全部 UUID 化
  ./lops.sh disk test /data                    # 测 /data 的磁盘性能
  ./lops.sh disk health                        # SMART 健康巡检

前置条件:
  - mount/uuid 需要 root；ls/test/health 建议 root（health 需读 SMART）
  - test 需要 fio、health 需要 smartmontools（缺失自动安装）

注意事项:
  ⚠ mount 会格式化目标盘，盘上现有数据将全部丢失，确认无误再执行。
  - mount 使用 defaults,nofail，即使该盘故障也不阻塞系统启动。
  - test 的顺序写场景会覆盖测试目录下的 fio 测试文件，请指定空目录或 /tmp。
  - fstab 修改前自动备份为 *.bak.<时间戳>，异常可回滚。
EOF
}

# ---------- 动作实现 ----------

disk__ls() {
  section "块设备概览"
  lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL 2>/dev/null || lsblk
  echo ""
  section "文件系统使用"
  df -hT -x tmpfs -x devtmpfs -x overlay

  # 标注未挂载且无文件系统的裸盘
  local bare=() dev
  for dev in $(lsblk -rno NAME,TYPE,FSTYPE,MOUNTPOINT | awk '$2=="disk" && $3=="" && $4=="" {print "/dev/"$1}'); do
    # 排除有分区的盘
    if ! lsblk -rno TYPE "$dev" | grep -q part; then
      bare+=("$dev")
    fi
  done
  echo ""
  section "未挂载裸盘（可执行 disk mount 上线）"
  if (( ${#bare[@]} == 0 )); then
    mark_ok "无未挂载裸盘"
  else
    for dev in "${bare[@]}"; do
      local size
      size="$(lsblk -rno SIZE "$dev")"
      mark_warn "${dev}  ${size}  （无文件系统、无分区、未挂载）"
    done
  fi
}

disk__mount() {
  require_root
  local device="${1:-}"
  local mountpoint="${2:-}"
  local fstype="${3:-ext4}"

  # 交互环境参数缺失时提示
  if [[ -t 0 ]]; then
    [[ -z "$device" ]] && device="$(ask_value "目标设备（如 /dev/sdb）")"
    [[ -z "$mountpoint" ]] && mountpoint="$(ask_value "挂载点（如 /data）")"
  fi
  if [[ -z "$device" || -z "$mountpoint" ]]; then
    err "用法: lops.sh disk mount <device> <mountpoint> [fstype]"
    return 1
  fi
  if [[ ! -b "$device" ]]; then
    err "${device} 不是块设备，请用 ./lops.sh disk ls 确认"
    return 1
  fi
  if [[ ! "$fstype" =~ ^(ext4|xfs)$ ]]; then
    err "仅支持 ext4 / xfs，当前: ${fstype}"
    return 1
  fi
  if findmnt -S "$device" >/dev/null 2>&1; then
    err "${device} 已有挂载，如需重新初始化请先卸载并确认数据可弃"
    return 1
  fi
  if blkid "$device" >/dev/null 2>&1; then
    err "${device} 已有文件系统/签名，拒绝格式化（防止误毁数据）"
    err "确认要重置请手动执行: wipefs -a ${device} 后重试"
    return 1
  fi
  if findmnt "$mountpoint" >/dev/null 2>&1; then
    err "挂载点 ${mountpoint} 已被占用:"
    findmnt "$mountpoint"
    return 1
  fi

  # 展示信息 + 二次确认
  echo ""
  section "即将执行以下操作"
  lsblk "$device" -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT
  echo ""
  echo "  1) mkfs.${fstype} ${device}"
  echo "  2) mkdir -p ${mountpoint}"
  echo "  3) mount ${device} ${mountpoint}"
  echo "  4) 写入 fstab（UUID 方式 + nofail）"
  echo ""
  if ! confirm "⚠ ${device} 将被格式化，数据全部丢失，确认继续"; then
    log "已取消"
    return 0
  fi

  mkfs."$fstype" "$device" || { err "格式化失败"; return 1; }
  mkdir -p "$mountpoint"
  mount "$device" "$mountpoint" || { err "挂载失败"; return 1; }

  local uuid
  uuid="$(blkid -s UUID -o value "$device")"
  if [[ -z "$uuid" ]]; then
    err "无法获取 UUID，fstab 未写入（盘已挂载可用）"
    return 1
  fi

  backup_file /etc/fstab
  echo "UUID=${uuid} ${mountpoint} ${fstype} defaults,nofail 0 2" >> /etc/fstab
  if command -v findmnt >/dev/null 2>&1; then
    if ! findmnt --verify; then
      err "fstab 校验异常，请人工检查 /etc/fstab（已备份）"
      return 1
    fi
  fi

  log "数据盘上线完成"
  print_kv "设备" "$device"
  print_kv "挂载点" "$mountpoint"
  print_kv "文件系统" "$fstype"
  print_kv "UUID" "$uuid"
  df -hT "$mountpoint"
}

disk__uuid() {
  require_root
  section "fstab 设备名 → UUID 化"
  backup_file /etc/fstab

  local tmp changed=0 line dev uuid fstype rest
  tmp="$(mktemp)"
  while IFS= read -r line; do
    dev="$(echo "$line" | awk '{print $1}')"
    if [[ "$dev" =~ ^/dev/(sd|vd|nvme|hd)[a-z0-9]+$ ]]; then
      uuid="$(blkid -s UUID -o value "$dev" 2>/dev/null || true)"
      if [[ -n "$uuid" ]]; then
        # 注意: awk 参数必须用 -v OFS 传递；写成尾部 "OFS=' '" 会被当作文件名导致 awk 致命退出
        echo "$line" | awk -v u="UUID=${uuid}" -v OFS=' ' '{$1=u; print}' >> "$tmp"
        log "已替换: $dev -> UUID=${uuid}"
        changed=$((changed + 1))
      else
        warn "取不到 $dev 的 UUID，保留原条目"
        echo "$line" >> "$tmp"
      fi
    else
      echo "$line" >> "$tmp"
    fi
  done < /etc/fstab

  if (( changed == 0 )); then
    mark_ok "fstab 无设备名挂载条目，无需修改"
    rm -f "$tmp"
    return 0
  fi

  cat "$tmp" > /etc/fstab
  rm -f "$tmp"
  if command -v findmnt >/dev/null 2>&1; then
    findmnt --verify || { err "fstab 校验异常，请用备份回滚"; return 1; }
  fi
  log "共替换 ${changed} 条，fstab 已更新（原文件已备份）"
}

disk__test() {
  local dir="${1:-/tmp}"
  if [[ ! -d "$dir" ]]; then
    err "目录不存在: ${dir}"
    return 1
  fi
  # fio 未安装时自动装包（需 root；非 root 明确报错而非静默中断）
  if ! command -v fio >/dev/null 2>&1; then
    if [[ "${EUID}" -ne 0 ]]; then
      err "fio 未安装且安装需要 root 权限，请 sudo 执行"
      return 1
    fi
    log "安装 fio..."
    pkg_install fio || { err "fio 安装失败，请手动安装后重试"; return 1; }
  fi

  section "fio 磁盘性能测试"
  print_kv "测试目录" "$dir"
  print_kv "文件大小" "$LOPS_DISK_TEST_SIZE"
  print_kv "单场景时长" "${LOPS_DISK_TEST_RUNTIME}s"

  local common="--direct=1 --iodepth=64 --ioengine=libaio --size=${LOPS_DISK_TEST_SIZE} --runtime=${LOPS_DISK_TEST_RUNTIME} --directory=${dir}"
  declare -a names=("顺序写" "顺序读" "随机写" "随机读")
  declare -a args=("rw=write bs=128k" "rw=read bs=128k" "rw=randwrite bs=4k" "rw=randread bs=4k")
  declare -a bw_results=() iops_results=()

  local i out bw iops
  for i in 0 1 2 3; do
    echo ""
    log "场景 ${names[$i]} ..."
    # shellcheck disable=SC2086  # fio 参数需按空格拆分为多个参数，故意不加引号
    out="$(fio --name=lops_test ${common} ${args[$i]} --output-format=json 2>/dev/null || true)"
    if [[ -z "$out" ]]; then
      # JSON 失败则回退文本输出
      # shellcheck disable=SC2086
      fio --name=lops_test ${common} ${args[$i]}
      bw_results+=("-") iops_results+=("-")
      continue
    fi
    bw="$(echo "$out" | awk -F'"bw_bytes": ' '{split($2,a,","); print a[1]}' | head -n1)"
    iops="$(echo "$out" | awk -F'"iops": ' '{split($2,a,","); print a[1]}' | head -n1)"
    if [[ -n "$bw" && "$bw" =~ ^[0-9]+$ ]]; then
      bw_results+=("$(awk -v b="$bw" 'BEGIN{printf "%.1f MB/s", b/1024/1024}')")
    else
      bw_results+=("-")
    fi
    [[ -n "$iops" && "$iops" =~ ^[0-9.]+$ ]] && iops_results+=("$iops") || iops_results+=("-")
    log "完成: ${names[$i]}  带宽=${bw_results[$(( ${#bw_results[@]} - 1 ))]}  IOPS=${iops_results[$(( ${#iops_results[@]} - 1 ))]}"
  done

  rm -f "${dir}"/lops_test* 2>/dev/null || true
  echo ""
  section "性能汇总"
  printf "  %-10s %-14s %-12s\n" "场景" "带宽" "IOPS"
  hr
  for i in 0 1 2 3; do
    printf "  %-10s %-14s %-12s\n" "${names[$i]}" "${bw_results[$i]}" "${iops_results[$i]}"
  done
}

disk__health() {
  if ! command -v smartctl >/dev/null 2>&1; then
    if [[ "${EUID}" -ne 0 ]]; then
      err "smartctl 未安装且安装需要 root 权限，请 sudo 执行"
      return 1
    fi
    log "安装 smartmontools..."
    pkg_install smartmontools || { err "smartmontools 安装失败，请手动安装后重试"; return 1; }
  fi
  section "SMART 磁盘健康快照"

  local devices=() d
  for d in /dev/sd[a-z] /dev/nvme[0-9]n[0-9] /dev/vd[a-z]; do
    [[ -b "$d" ]] && devices+=("$d")
  done
  if (( ${#devices[@]} == 0 )); then
    warn "未发现 SATA/SAS/NVMe 块设备"
    return 0
  fi

  local dev overall attr
  for dev in "${devices[@]}"; do
    echo ""
    hr
    print_kv "设备" "$dev"
    overall="$(smartctl -H "$dev" 2>/dev/null | grep -iE 'overall|result' | head -n1 | xargs)"
    if [[ -z "$overall" ]]; then
      mark_warn "无法读取 SMART（虚拟盘或权限不足）"
      continue
    fi
    if echo "$overall" | grep -qi "PASSED\|OK"; then
      mark_ok "$overall"
    else
      mark_bad "$overall"
    fi

    if [[ "$dev" == *nvme* ]]; then
      smartctl -A "$dev" 2>/dev/null | grep -E '^(Critical Warning|Temperature|Percentage Used|Available Spare|Power On Hours|Unsafe Shutdowns)' | while read -r attr; do
        printf "    %s\n" "$attr"
      done
    else
      smartctl -A "$dev" 2>/dev/null | awk -v RED="$RED" -v NC="$NC" '
        $1 ~ /^(5|10|12|194|196|197|198)$/ {
          flag=""
          if (($1==196||$1==197||$1==198) && $10+0 > 0) flag=RED" <-- 异常!"NC
          printf "    %-28s 原始值: %-12s%s\n", $2, $10, flag
        }'
    fi
  done
  echo ""
  log "SMART 快照完成（196/197/198 非零 = 存在坏扇区风险）"
}

# ---------- 动作分发 ----------
mod_disk_run() {
  local action="${1:-}"
  [[ -z "$action" ]] && { mod_disk_help; return 1; }
  shift || true

  case "$action" in
    ls)     disk__ls ;;
    mount)  disk__mount "$@" ;;
    uuid)   disk__uuid ;;
    test)   disk__test "$@" ;;
    health) disk__health ;;
    *)
      err "未知动作: disk ${action}"
      mod_disk_help
      return 1
      ;;
  esac
}
