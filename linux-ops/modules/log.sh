#!/usr/bin/env bash
# ==============================================================================
# lops 模块: log — 日志管理
# ==============================================================================
# 功能:
#   - journal  journalctl 常用查询（本次启动错误/服务日志/最近N行/磁盘占用）
#   - size     /var/log 大小排行 Top20（超过 100M 标红提示）
#   - clean    日志清理（journald vacuum + 旧轮转文件，先列清单再确认）
#   - rotate   logrotate 检查（演练模式摘要/配置清单/可选强制轮转）
#   - errors   关键词扫描（error/fail/oom/panic）
# ==============================================================================

# 可配置项（执行前可通过环境变量覆盖，见 mod_log_help）
LOPS_LOG_CLEAN_DAYS="${LOPS_LOG_CLEAN_DAYS:-7}"      # clean 动作 journald 保留天数
LOPS_LOG_SCAN_LINES="${LOPS_LOG_SCAN_LINES:-1000}"   # errors 动作默认扫描行数

mod_log_desc() {
  echo "日志管理（journalctl 查询/大小排行/清理/轮转检查/错误扫描）"
}

mod_log_actions() {
  cat <<'EOF'
journal|journalctl 常用查询（本次启动错误/服务日志/最近N行/磁盘占用）
size|/var/log 大小排行 Top20（超过 100M 标红提示）
clean|日志清理（journald vacuum 保留天数/大小 + 旧轮转文件，先列清单再确认）
rotate|logrotate 检查（演练模式摘要/配置清单/可选强制轮转）
errors|关键词扫描（error/fail/oom/panic，默认扫 /var/log/messages 或 syslog）
EOF
}

mod_log_help() {
  cat <<'EOF'
lops log — 日志管理
==============================================================================
日志的「查、量、清、转、扫」五件事：journalctl 常用查询、/var/log 空间
排行、日志清理（journald 收缩 + 旧轮转文件删除）、logrotate 轮转检查、
错误关键词扫描。删除类操作一律先列清单、二次确认后才执行。

用法:
  ./lops.sh log <action> [参数]

动作说明:
  journal [子项] [参数]
      journalctl 常用查询。不带参数进入交互子菜单，也可子命令直达:
        err            本次启动以来的错误及以上级别日志
                       （journalctl -p err -b）
        service <名>   指定服务最近 100 行日志（journalctl -u <名>）
        tail [N]       最近 N 行系统日志（journalctl -n N，默认 50）
        usage          journald 磁盘占用（journalctl --disk-usage）
      小知识: journald 是 systemd 自带的日志服务，日志为二进制格式，
      必须用 journalctl 查询，不能直接 cat / grep。
  size
      /var/log 大小排行: 按文件体积排前 20 名，超过 100M 的标红提示
      （日志把磁盘写爆是最常见的线上故障之一），并给出 /var 所在
      分区的使用率着色展示。
  clean [保留天数] [大小上限]
      日志清理，分两部分，先全部列出再统一确认:
        ① journald 收缩（vacuum）: journalctl --vacuum-time=<天数>d
           可选再执行 --vacuum-size=<大小上限>（如 500M）
        ② 删除 /var/log 下已轮转的旧文件（*.gz / *.old）
      保留天数默认 7（可用参数或环境变量 LOPS_LOG_CLEAN_DAYS 覆盖）。
      小知识: vacuum 直译「抽真空」——把 journald 的历史日志按
      时间/大小裁掉，只留最近的，释放磁盘立竿见影。
  rotate
      logrotate 轮转检查:
        ① 列出主配置 /etc/logrotate.conf 与 /etc/logrotate.d/ 清单
        ② 演练模式摘要: logrotate -d 只「演算」不执行，报告哪些日志
           下次轮转时会怎么处理，可放心运行、零副作用
        ③ 展示自动轮转的触发机制（systemd timer 或 cron.daily）
        ④ 可选强制轮转: logrotate -f 立即切割（需二次确认）
      小知识: logrotate 是日志「切分归档」机制——把写大的日志改名
      留存（messages → messages.1）并压缩（messages.1.gz），程序继续
      写新文件，从而防止单个日志无限膨胀。
  errors [文件] [行数]
      关键词扫描: 在日志文件最近 N 行（默认 1000）中查找
      error / fail / oom / panic（不区分大小写），输出各关键词命中
      次数与最近命中的日志行。文件默认按存在性自动选择:
      /var/log/messages（CentOS 系）或 /var/log/syslog（Ubuntu/Debian 系）。

可配置环境变量（执行前 export 覆盖默认值）:
  LOPS_LOG_CLEAN_DAYS=7        # clean 动作默认保留天数
  LOPS_LOG_SCAN_LINES=1000     # errors 动作默认扫描行数

示例:
  ./lops.sh log journal                     # 交互子菜单
  ./lops.sh log journal err                 # 本次启动以来的错误
  ./lops.sh log journal service nginx       # nginx 服务日志
  ./lops.sh log journal tail 200            # 最近 200 行
  ./lops.sh log size                        # 日志大小排行
  ./lops.sh log clean                       # 清理（默认保留 7 天）
  ./lops.sh log clean 30                    # journald 保留 30 天
  ./lops.sh log clean 7 500M                # 保留 7 天且上限 500M
  ./lops.sh log rotate                      # 轮转检查（含演练摘要）
  ./lops.sh log errors                      # 扫描默认日志
  ./lops.sh log errors /var/log/syslog 3000 # 指定文件与行数

前置条件:
  - journal 需要 journalctl（systemd 系统，CentOS 7+/Ubuntu 16+ 自带）
  - clean 与 rotate 的强制轮转会改系统状态，需要 root
  - size / errors / rotate 演练为只读，无需 root；但普通用户可能
    读不到部分日志文件，建议 sudo 执行效果更好
  - errors 读取 /var/log/syslog 在 Ubuntu 上需要 root 或 adm 组

注意事项:
  - clean 只删除 find -type f 列出的「文件」，绝不删除目录本身；
    正在被进程写入的当前日志（如 messages 本体）不会被动到。
  - journald 日志是二进制格式，不能直接 cat / grep，请用 journalctl。
  - errors 是关键词粗筛，可能误伤个别单词（如 bloom 含 oom），
    定位问题请结合上下文人工确认。
  - rotate 的强制轮转正常情况无需手动执行（每天自动轮转），
    仅在排查轮转异常时使用。
EOF
}

# ---------- journal ----------

log__journal() {
  require_cmd journalctl || return 1
  banner "lops log journal — journalctl 常用查询"

  # 普通用户可能只能看到部分系统日志
  if [[ "${EUID}" -ne 0 ]]; then
    warn "当前非 root，可能只能看到部分日志（sudo 执行可查看全部系统日志）"
  fi

  local sub="${1:-}"
  if [[ -z "$sub" && -t 0 ]]; then
    local -a opts=(
      "本次启动以来的错误日志（journalctl -p err -b）"
      "指定服务日志（journalctl -u <服务>，最近 100 行）"
      "最近 N 行日志（journalctl -n N）"
      "journald 磁盘占用（journalctl --disk-usage）"
    )
    local c
    c="$(menu_choose "journalctl 常用查询" "${opts[@]}")"
    case "$c" in
      1) sub="err" ;;
      2) sub="service" ;;
      3) sub="tail" ;;
      4) sub="usage" ;;
      *) return 0 ;;
    esac
  fi

  case "$sub" in
    err)
      section "本次启动以来的错误及以上级别（journalctl -p err -b）"
      journalctl -p err -b --no-pager
      ;;
    service)
      local svc="${2:-}"
      if [[ -z "$svc" && -t 0 ]]; then
        svc="$(ask_value "服务名（如 nginx / sshd / docker）")"
      fi
      if [[ -z "$svc" ]]; then
        err "用法: lops.sh log journal service <服务名>"
        return 1
      fi
      section "服务 ${svc} 最近 100 行日志（journalctl -u ${svc}）"
      journalctl -u "$svc" -n 100 --no-pager
      echo ""
      log "持续跟踪可执行: journalctl -u ${svc} -f"
      ;;
    tail)
      local n="${2:-}"
      if [[ -z "$n" && -t 0 ]]; then
        n="$(ask_value "查看最近多少行" "50")"
      fi
      n="${n:-50}"
      if ! [[ "$n" =~ ^[0-9]+$ ]] || (( n == 0 )); then
        err "行数需为正整数: ${n}"
        return 1
      fi
      section "最近 ${n} 行系统日志（journalctl -n ${n}）"
      journalctl -n "$n" --no-pager
      ;;
    usage)
      section "journald 磁盘占用（journalctl --disk-usage）"
      journalctl --disk-usage
      ;;
    *)
      err "未知子项: log journal ${sub}（可用: err / service / tail / usage）"
      return 1
      ;;
  esac
}

# ---------- size ----------

log__size() {
  banner "lops log size — /var/log 大小排行"
  if [[ ! -d /var/log ]]; then
    err "/var/log 目录不存在"
    return 1
  fi

  section "总览"
  print_kv "/var/log 总大小" "$(du -sh /var/log 2>/dev/null | awk '{print $1}')"
  local bigcnt
  bigcnt="$(find /var/log -type f -size +100M 2>/dev/null | wc -l || true)"
  print_kv "超过 100M 的日志文件" "${bigcnt} 个"
  # /var/log 所在分区使用率（日志写爆磁盘是最常见场景）
  local var_total var_used pct
  var_total="$(df -kP /var/log 2>/dev/null | awk 'NR==2{print $2}')"
  var_used="$(df -kP /var/log 2>/dev/null | awk 'NR==2{print $3}')"
  if [[ "${var_total}" =~ ^[0-9]+$ && "${var_used}" =~ ^[0-9]+$ ]] && (( var_total > 0 )); then
    pct=$(( var_used * 100 / var_total ))
    printf "  %-24s " "/var 所在分区使用率:"
    pct_color "$pct"
  fi
  if [[ "${EUID}" -ne 0 ]]; then
    warn "非 root 执行，部分受保护文件可能未统计到"
  fi

  echo ""
  section "文件大小 Top20（du -m 统一按 MB 排序）"
  local sz path disp found=0
  while read -r sz path; do
    [[ -z "${path:-}" ]] && continue
    found=1
    if (( sz >= 1024 )); then
      disp="$(awk -v s="$sz" 'BEGIN{printf "%.1fG", s/1024}')"
    else
      disp="${sz}M"
    fi
    if (( sz >= 100 )); then
      echo -e "  ${RED}${disp}${NC}\t${path}  ${RED}← 超过 100M，建议关注${NC}"
    else
      printf "  %-10s %s\n" "$disp" "$path"
    fi
  done < <(find /var/log -type f -exec du -m {} + 2>/dev/null | sort -rn | head -n 20)

  if (( found == 0 )); then
    mark_ok "/var/log 下未发现日志文件（或无读取权限）"
  else
    echo ""
    log "排查建议: 大文件若是已轮转的旧日志（*.gz / *.old），可用 lops.sh log clean 清理"
  fi
}

# ---------- clean ----------

log__clean() {
  require_root
  local days="${1:-${LOPS_LOG_CLEAN_DAYS}}"
  local size="${2:-}"

  banner "lops log clean — 日志清理"
  if ! [[ "$days" =~ ^[0-9]+$ ]] || (( days == 0 )); then
    err "保留天数需为正整数: ${days}"
    return 1
  fi

  # ---------- ① journald vacuum ----------
  local has_journal=0
  command -v journalctl >/dev/null 2>&1 && has_journal=1
  if (( has_journal )); then
    section "① journald 日志收缩（vacuum）"
    journalctl --disk-usage
    print_kv "时间策略" "journalctl --vacuum-time=${days}d（保留最近 ${days} 天）"
    if [[ -n "$size" ]]; then
      print_kv "大小策略" "journalctl --vacuum-size=${size}（收缩到 ${size} 以内）"
    fi
  fi

  # ---------- ② /var/log 已轮转旧文件 ----------
  section "② /var/log 已轮转旧文件（*.gz / *.old）"
  local -a targets=()
  local f total
  while IFS= read -r f; do
    [[ -n "$f" ]] && targets+=("$f")
  done < <(find /var/log -type f \( -name '*.gz' -o -name '*.old' \) 2>/dev/null || true)

  if (( ${#targets[@]} > 0 )); then
    echo "以下已轮转旧文件将被删除（仅删文件，不动任何目录）:"
    for f in "${targets[@]}"; do
      printf "  %s\t%s\n" "$(du -h "$f" 2>/dev/null | awk '{print $1}')" "$f"
    done
    total="$(du -ch -- "${targets[@]}" 2>/dev/null | tail -n 1 | awk '{print $1}')"
    print_kv "合计" "${total:-0}（${#targets[@]} 个文件）"
  else
    mark_ok "/var/log 无 *.gz / *.old 旧文件"
  fi

  # 两部分都没有可清理内容时直接结束
  if (( ! has_journal )) && (( ${#targets[@]} == 0 )); then
    mark_ok "没有可清理的内容"
    return 0
  fi

  # ---------- 统一确认 ----------
  echo ""
  if ! confirm "确认执行上述清理（journald 保留 ${days} 天${size:+、上限 ${size}}；删除 ${#targets[@]} 个旧文件）"; then
    log "已取消清理"
    return 0
  fi

  if (( has_journal )); then
    journalctl --vacuum-time="${days}d" || warn "journald vacuum-time 执行失败"
    if [[ -n "$size" ]]; then
      journalctl --vacuum-size="$size" || warn "journald vacuum-size 执行失败"
    fi
  fi
  if (( ${#targets[@]} > 0 )); then
    # 仅删除上面 find -type f 列出的文件，绝不触碰目录本身
    rm -f -- "${targets[@]}"
    log "已删除 ${#targets[@]} 个旧轮转文件，释放约 ${total:-未知}"
  fi

  echo ""
  section "清理结果"
  if (( has_journal )); then
    journalctl --disk-usage
  fi
  print_kv "/var/log 当前总大小" "$(du -sh /var/log 2>/dev/null | awk '{print $1}')"
  log "日志清理完成"
}

# ---------- rotate ----------

log__rotate() {
  require_root
  require_cmd logrotate || return 1
  banner "lops log rotate — logrotate 轮转检查"

  # ---------- ① 配置清单 ----------
  section "① 配置文件清单"
  if [[ ! -f /etc/logrotate.conf ]]; then
    err "主配置 /etc/logrotate.conf 不存在"
    return 1
  fi
  print_kv "主配置" "/etc/logrotate.conf"
  echo ""
  echo "子配置目录 /etc/logrotate.d/:"
  local f n=0
  for f in /etc/logrotate.d/*; do
    [[ -f "$f" ]] || continue
    printf "  %-28s %s\n" "$(basename "$f")" "$(du -h "$f" 2>/dev/null | awk '{print $1}')"
    n=$((n + 1))
  done
  if (( n == 0 )); then
    mark_warn "/etc/logrotate.d/ 为空"
  fi

  # ---------- ② 演练模式摘要 ----------
  section "② 演练模式摘要（logrotate -d，只演算不执行，无副作用）"
  local dry
  dry="$(logrotate -d /etc/logrotate.conf 2>&1 || true)"
  local pcount
  pcount="$(grep -c 'rotating pattern:' <<<"$dry" || true)"
  [[ "$pcount" =~ ^[0-9]+$ ]] || pcount=0
  print_kv "受管日志条目" "${pcount} 个（rotating pattern）"
  echo ""
  if (( pcount > 0 )); then
    echo "各条目切割策略（前 20 条）:"
    grep 'rotating pattern:' <<<"$dry" | head -n 20 || true
  else
    mark_warn "演练输出未识别到 rotating pattern，请手动执行 logrotate -d /etc/logrotate.conf 查看"
  fi
  echo ""
  local rerr
  rerr="$(grep 'error:' <<<"$dry" || true)"
  if [[ -n "$rerr" ]]; then
    mark_bad "演练发现错误:"
    echo "$rerr" | head -n 10
  else
    mark_ok "演练模式无错误"
  fi

  # ---------- ③ 自动轮转触发机制 ----------
  section "③ 自动轮转触发机制"
  if systemctl list-timers --no-pager 2>/dev/null | grep -q logrotate; then
    systemctl list-timers --no-pager 2>/dev/null | grep -E '(^NEXT|logrotate)' || true
    print_kv "触发方式" "systemd 定时器 logrotate.timer"
  elif [[ -f /etc/cron.daily/logrotate ]]; then
    print_kv "触发方式" "/etc/cron.daily/logrotate（每日执行一次）"
  else
    mark_warn "未识别到 logrotate 自动触发机制（请检查 logrotate.timer / /etc/cron.daily/logrotate）"
  fi

  # ---------- ④ 可选强制轮转 ----------
  section "④ 强制轮转（可选）"
  echo "logrotate -f /etc/logrotate.conf 会立即切割所有受管日志"
  echo "（正常情况无需手动执行，轮转由上面③的机制每天自动完成）"
  if confirm "是否立即强制轮转一次"; then
    if logrotate -f /etc/logrotate.conf; then
      mark_ok "强制轮转完成（旧文件可在 /var/log 下看到 *.1 / *.gz）"
    else
      mark_bad "强制轮转失败（可用 logrotate -dv /etc/logrotate.conf 排查）"
      return 1
    fi
  else
    log "跳过强制轮转"
  fi
}

# ---------- errors ----------

log__errors() {
  local file="${1:-}"
  local lines="${2:-${LOPS_LOG_SCAN_LINES}}"

  banner "lops log errors — 错误关键词扫描"

  # 默认文件: 按存在性自动选择（CentOS: messages / Ubuntu: syslog）
  if [[ -z "$file" ]]; then
    if [[ -f /var/log/messages ]]; then
      file="/var/log/messages"
    elif [[ -f /var/log/syslog ]]; then
      file="/var/log/syslog"
    else
      err "未找到默认日志文件（/var/log/messages 或 /var/log/syslog），请指定文件路径"
      err "用法: lops.sh log errors <文件> [行数]（systemd 日志可用 lops.sh log journal err）"
      return 1
    fi
  fi

  if [[ ! -f "$file" ]]; then
    err "文件不存在: ${file}"
    return 1
  fi
  if [[ ! -r "$file" ]]; then
    err "无读取权限: ${file}（Ubuntu 的 syslog 属 adm 组，请 sudo 执行）"
    return 1
  fi
  if ! [[ "$lines" =~ ^[0-9]+$ ]] || (( lines == 0 )); then
    err "扫描行数需为正整数: ${lines}"
    return 1
  fi

  section "扫描范围"
  print_kv "文件" "$file"
  print_kv "范围" "最近 ${lines} 行"
  print_kv "关键词" "error / fail / oom / panic（不区分大小写）"

  section "命中统计"
  local kw c total=0
  for kw in error fail oom panic; do
    c="$(tail -n "$lines" "$file" | grep -iac "$kw" || true)"
    [[ "$c" =~ ^[0-9]+$ ]] || c=0
    print_kv "$kw" "${c} 次"
    total=$(( total + c ))
  done

  echo ""
  if (( total == 0 )); then
    mark_ok "最近 ${lines} 行未命中任何关键词"
    return 0
  fi

  section "最近命中的日志行（最后 10 条）"
  tail -n "$lines" "$file" | grep -iaE 'error|fail|oom|panic' | tail -n 10 || true
  echo ""
  mark_warn "关键词共命中 ${total} 次，请结合上下文判断是否为真实故障（粗筛可能误伤，如 bloom 含 oom）"
}

# ---------- 动作分发 ----------

mod_log_run() {
  local action="${1:-}"
  [[ -z "$action" ]] && { mod_log_help; return 1; }
  shift || true

  case "$action" in
    journal) log__journal "$@" ;;
    size)    log__size ;;
    clean)   log__clean "$@" ;;
    rotate)  log__rotate ;;
    errors)  log__errors "$@" ;;
    *)
      err "未知动作: log ${action}"
      mod_log_help
      return 1
      ;;
  esac
}
