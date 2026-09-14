#!/usr/bin/env bash
# ==============================================================================
# lops 模块: cron — 计划任务管理
# ==============================================================================
# 功能:
#   - list     汇总当前用户 crontab + /etc/crontab + /etc/cron.d/
#   - backup   备份当前用户 crontab 到 .backup/ 下带时间戳文件
#   - add      交互式添加计划任务（收集表达式/命令/注释，预览确认后写入）
#   - check    crond 服务状态 + 最近执行日志 + 当前任务数统计
#   - restore  从 .backup/ 下的备份文件恢复（覆盖前自动安全备份）
# ==============================================================================

# 备份目录（lops 安装目录下的 .backup/，可用环境变量覆盖）
LOPS_CRON_BACKUP_DIR="${LOPS_CRON_BACKUP_DIR:-${LOPS_ROOT}/.backup}"

mod_cron_desc() {
  echo "计划任务（crontab 汇总/备份/交互添加/服务检查/恢复）"
}

mod_cron_actions() {
  cat <<'EOF'
list|汇总计划任务（当前用户 crontab + /etc/crontab + /etc/cron.d/）
backup|备份当前用户 crontab 到 .backup/ 下带时间戳文件
add|交互式添加计划任务（收集表达式/命令/注释，预览确认后写入）
check|crond 服务状态 + 最近执行日志 + 当前任务数统计
restore|从 .backup/ 下的备份恢复 crontab（覆盖前自动安全备份）
EOF
}

mod_cron_help() {
  cat <<'EOF'
lops cron — 计划任务管理
==============================================================================
crontab 的日常五件事：看（汇总所有计划任务）、备（改前备份）、加
（交互式添加）、查（服务状态与执行日志）、恢复（从备份回滚）。
所有操作针对「执行命令的用户」——sudo 执行即管理 root 的 crontab。

用法:
  ./lops.sh cron <action> [参数]

动作说明:
  list
      汇总三处计划任务并统计条数:
        ① 当前用户 crontab（crontab -l，实际存于 /var/spool/cron/）
        ② /etc/crontab（系统级总表，含 run-parts 调度四个周期目录）
        ③ /etc/cron.d/*（软件包或管理员投放的任务文件）
      小知识: 用户任务用 crontab -e 编辑，每行 6 列（5 列时间 + 1 列
      命令）；/etc/crontab 与 /etc/cron.d/ 的行是 7 列——第 6 列多
      一个「执行用户」。
  backup
      把当前用户 crontab 导出到 <lops目录>/.backup/crontab.<用户>.
      <时间戳> 文件。改动前先备份是好习惯，restore 依赖这些文件。
  add
      交互式添加: 依次询问调度表达式（分 时 日 月 周）、要执行的
      命令、注释，展示将写入的行，确认后追加到当前用户 crontab
      末尾: (crontab -l; echo ...) | crontab -
      内置校验: 表达式必须是 5 个字段；命令含 % 会警告
      （crontab 里 % 是特殊字符，表示换行）。
  check
      ① crond/cron 服务状态与开机自启（Debian 系叫 cron，
         CentOS 系叫 crond，自动识别）
      ② 最近执行日志: /var/log/cron（CentOS）或
         journalctl -u cron/crond（Ubuntu），取最近 30 行
      ③ 当前任务数统计（用户 crontab / /etc/crontab / /etc/cron.d/）
      小知识: cron 日志只记录「何时以谁的身份执行了什么命令」，
      命令自身的输出不会出现在这里——输出默认会以邮件发给本机
      用户（/var/spool/mail/），建议在任务里用 >> 重定向落盘。
  restore [序号|备份文件路径]
      列出 .backup/ 下当前用户的备份文件供选择（交互菜单，或直接
      按序号/路径指定），预览内容并确认后整体覆盖恢复；
      覆盖前会先对当前 crontab 做一次安全备份（*.pre-restore）。

示例:
  ./lops.sh cron list                     # 看所有计划任务
  ./lops.sh cron backup                   # 改动前先备份
  ./lops.sh cron add                      # 交互式加任务
  sudo ./lops.sh cron check               # root 任务与执行日志
  ./lops.sh cron restore                  # 菜单选择备份恢复
  ./lops.sh cron restore 2                # 直接按序号恢复第 2 个

前置条件:
  - list / backup / add / restore 管理当前用户自身，无需 root；
    管理 root 的任务请 sudo 执行
  - check 读取 /var/log/cron 与系统日志通常需要 root（Ubuntu 为
    adm 组），无权限时自动降级提示
  - 需要 crontab 命令（cron / cronie 包提供，一般系统自带）

注意事项:
  - 备份目录默认 <lops目录>/.backup/（可用 LOPS_CRON_BACKUP_DIR
    覆盖），需保证可写；备份文件不会自动清理，积累多了可手动清理。
  - add 只追加不覆盖，已有任务不受影响；写错可用 restore 恢复。
  - crontab 修改即时生效，无需重启 crond 服务。
EOF
}

# ---------- 内部工具 ----------

# 统计文件中有效任务行数（排除注释与空行）
cron__count_file() {
  local c=0
  if [[ -r "$1" ]]; then
    c="$(grep -vcE '^[[:space:]]*(#|$)' "$1" 2>/dev/null || true)"
    [[ "$c" =~ ^[0-9]+$ ]] || c=0
  fi
  echo "$c"
}

# 当前用户 crontab 有效任务行数（无 crontab 返回 0）
cron__count_user() {
  local c=0
  if command -v crontab >/dev/null 2>&1; then
    c="$(crontab -l 2>/dev/null | grep -vcE '^[[:space:]]*(#|$)' || true)"
    [[ "$c" =~ ^[0-9]+$ ]] || c=0
  fi
  echo "$c"
}

# ---------- list ----------

cron__list() {
  command -v crontab >/dev/null 2>&1 || { err "缺少 crontab 命令（cron/cronie 包提供）"; return 1; }
  banner "lops cron list — 计划任务汇总"

  local user_total=0 sys_total=0 d_total=0

  section "① 当前用户 crontab（$(id -un)）"
  if crontab -l 2>/dev/null | grep -q .; then
    crontab -l
    user_total="$(cron__count_user)"
    print_kv "有效任务数" "${user_total}"
  else
    mark_warn "当前用户（$(id -un)）尚无 crontab"
  fi

  section "② /etc/crontab（系统级）"
  if [[ -f /etc/crontab ]]; then
    cat /etc/crontab
    sys_total="$(cron__count_file /etc/crontab)"
    print_kv "有效任务数" "${sys_total}（含 run-parts 调度 4 个周期目录）"
  else
    mark_warn "/etc/crontab 不存在"
  fi

  section "③ /etc/cron.d/（软件包/管理员投放的任务）"
  local f n=0
  for f in /etc/cron.d/*; do
    [[ -f "$f" ]] || continue
    n=$((n + 1))
    echo "--- ${f}（$(cron__count_file "$f") 条） ---"
    grep -vE '^[[:space:]]*(#|$)' "$f" 2>/dev/null || true
    d_total=$(( d_total + $(cron__count_file "$f") ))
  done
  if (( n == 0 )); then
    mark_warn "/etc/cron.d/ 下没有任务文件"
  else
    print_kv "cron.d 有效任务数" "${d_total}（${n} 个文件）"
  fi

  section "汇总"
  print_kv "当前用户 crontab" "${user_total} 条"
  print_kv "/etc/crontab" "${sys_total} 条"
  print_kv "/etc/cron.d/" "${d_total} 条"
  print_kv "合计" "$(( user_total + sys_total + d_total )) 条"
  log "提示: /etc/cron.{hourly,daily,weekly,monthly}/ 下的脚本由 /etc/crontab 的 run-parts 统一调度，不在本清单逐个展开"
}

# ---------- backup ----------

cron__backup() {
  command -v crontab >/dev/null 2>&1 || { err "缺少 crontab 命令（cron/cronie 包提供）"; return 1; }
  local bdir="${LOPS_CRON_BACKUP_DIR}"
  if ! mkdir -p "$bdir" 2>/dev/null; then
    err "无法创建备份目录: ${bdir}"
    return 1
  fi

  local user f
  user="$(id -un)"
  f="${bdir}/crontab.${user}.$(date '+%Y%m%d-%H%M%S')"

  section "备份当前用户（${user}）crontab"
  if crontab -l > "$f" 2>/dev/null; then
    print_kv "备份文件" "$f"
    print_kv "有效任务数" "$(cron__count_file "$f")"
    mark_ok "备份完成"
  else
    : > "$f"
    warn "当前用户（${user}）尚无 crontab，已生成空备份: ${f}"
  fi
}

# ---------- add ----------

cron__add() {
  command -v crontab >/dev/null 2>&1 || { err "缺少 crontab 命令（cron/cronie 包提供）"; return 1; }
  if [[ ! -t 0 ]]; then
    err "add 为交互式动作，请在终端环境执行"
    return 1
  fi

  section "交互式添加计划任务（当前用户: $(id -un)）"

  # ① 调度表达式（分 时 日 月 周）
  local sched
  sched="$(ask_value "调度表达式，5 个字段: 分 时 日 月 周（示例 0 2 * * * = 每天 02:00）")"
  if [[ -z "$sched" ]]; then
    err "调度表达式不能为空"
    return 1
  fi
  local -a fields
  read -r -a fields <<< "$sched"
  if (( ${#fields[@]} != 5 )); then
    err "调度表达式应为 5 个字段（分 时 日 月 周），当前 ${#fields[@]} 个: ${sched}"
    return 1
  fi

  # ② 要执行的命令
  local cmd
  cmd="$(ask_value "要执行的命令（建议绝对路径，输出重定向落盘，如 /opt/app/backup.sh >> /var/log/backup.log 2>&1）")"
  if [[ -z "$cmd" ]]; then
    err "命令不能为空"
    return 1
  fi
  if [[ "$cmd" == *"%"* ]]; then
    warn "命令包含 %: crontab 中 % 是特殊字符（换行，其后内容作为命令的 stdin），请确认或转义为 \\%"
  fi

  # ③ 注释（可选）
  local comment
  comment="$(ask_value "任务注释（可选，便于日后识别用途）")"

  # ④ 预览 + 确认
  echo ""
  section "将追加到当前用户 crontab 末尾:"
  [[ -n "$comment" ]] && echo "# ${comment}"
  echo "${sched} ${cmd}"
  echo ""
  if ! confirm "确认添加该计划任务"; then
    log "已取消"
    return 0
  fi

  # (crontab -l; echo ...) | crontab - ：读旧表+追加新行后整体写回
  if ! { crontab -l 2>/dev/null || true
         [[ -n "$comment" ]] && echo "# ${comment}"
         echo "${sched} ${cmd}"
       } | crontab -; then
    err "写入 crontab 失败（权限或磁盘问题?）"
    return 1
  fi

  mark_ok "已添加，当前 crontab 末尾内容:"
  crontab -l | tail -n 3
}

# ---------- check ----------

cron__check() {
  banner "lops cron check — crond 服务与执行情况"

  # ① 服务状态（Debian 系叫 cron，CentOS 系叫 crond）
  section "① crond 服务状态"
  local svc="" s unit en
  for s in crond cron; do
    if systemctl is-active --quiet "$s" 2>/dev/null; then
      svc="$s"
      break
    fi
  done
  if [[ -n "$svc" ]]; then
    mark_ok "服务 ${svc}.service 运行中"
    en="$(systemctl is-enabled "$svc" 2>/dev/null || true)"
    print_kv "开机自启" "${en:-unknown}"
  else
    unit="$(systemctl list-unit-files --no-legend 2>/dev/null | awk '{print $1}' | grep -E '^(cron|crond)\.service$' | head -n 1 || true)"
    if [[ -n "$unit" ]]; then
      mark_bad "服务 ${unit} 未运行（启动: systemctl enable --now ${unit%.service}）"
    else
      mark_bad "未找到 cron/crond 服务（Debian/Ubuntu 装 cron 包，CentOS/RHEL 装 cronie 包）"
    fi
  fi

  # ② 最近执行日志
  section "② 最近执行日志（最近 30 行）"
  if [[ -r /var/log/cron ]]; then
    tail -n 30 /var/log/cron
  elif journalctl -u cron -u crond -n 30 --no-pager >/dev/null 2>&1; then
    journalctl -u cron -u crond -n 30 --no-pager
  else
    warn "无法读取 cron 执行日志（/var/log/cron 不可读或无 journal 权限），建议 sudo 执行"
  fi

  # ③ 任务数统计
  section "③ 当前任务数统计"
  local user_total=0 sys_total=0 d_total=0 f
  user_total="$(cron__count_user)"
  if [[ -f /etc/crontab ]]; then
    sys_total="$(cron__count_file /etc/crontab)"
  fi
  for f in /etc/cron.d/*; do
    [[ -f "$f" ]] || continue
    d_total=$(( d_total + $(cron__count_file "$f") ))
  done
  print_kv "当前用户（$(id -un)）" "${user_total} 条"
  print_kv "/etc/crontab" "${sys_total} 条"
  print_kv "/etc/cron.d/" "${d_total} 条"
  print_kv "合计" "$(( user_total + sys_total + d_total )) 条"
}

# ---------- restore ----------

cron__restore() {
  command -v crontab >/dev/null 2>&1 || { err "缺少 crontab 命令（cron/cronie 包提供）"; return 1; }
  local bdir="${LOPS_CRON_BACKUP_DIR}"
  local user
  user="$(id -un)"

  # 收集当前用户的备份文件（文件名含时间戳，按名称排序即按时间排序）
  local -a files=()
  local f
  while IFS= read -r f; do
    [[ -n "$f" ]] && files+=("$f")
  done < <(ls -1 "${bdir}/crontab.${user}."* 2>/dev/null || true)

  if (( ${#files[@]} == 0 )); then
    err "备份目录下没有用户 ${user} 的备份（${bdir}/，可先执行 lops.sh cron backup）"
    return 1
  fi

  # 选择备份: 参数序号 / 参数路径 / 交互菜单
  local pick="${1:-}"
  if [[ -z "$pick" ]]; then
    if [[ ! -t 0 ]]; then
      err "非交互环境需指定备份: lops.sh cron restore <序号|文件路径>"
      return 1
    fi
    local -a opts=()
    for f in "${files[@]}"; do
      opts+=("$(basename "$f")（$(cron__count_file "$f") 条任务）")
    done
    local c
    c="$(menu_choose "选择要恢复的备份" "${opts[@]}")"
    if (( c == 0 )); then
      return 0
    fi
    pick="${files[$(( c - 1 ))]}"
  elif [[ "$pick" =~ ^[0-9]+$ ]]; then
    if (( pick < 1 || pick > ${#files[@]} )); then
      err "序号超出范围: ${pick}（可用 1-${#files[@]}）"
      return 1
    fi
    pick="${files[$(( pick - 1 ))]}"
  elif [[ ! -f "$pick" ]]; then
    err "备份文件不存在: ${pick}"
    return 1
  fi

  # 预览
  section "备份内容预览: $(basename "$pick")"
  cat "$pick"
  echo ""

  warn "恢复将整体覆盖当前用户（${user}）的 crontab"
  if ! confirm "确认覆盖恢复"; then
    log "已取消"
    return 0
  fi

  # 覆盖前对当前 crontab 做安全备份
  if crontab -l >/dev/null 2>&1; then
    local safe
    safe="${bdir}/crontab.${user}.$(date '+%Y%m%d-%H%M%S').pre-restore"
    mkdir -p "$bdir"
    if crontab -l > "$safe" 2>/dev/null; then
      log "已自动备份当前 crontab -> ${safe}"
    fi
  fi

  if crontab "$pick"; then
    mark_ok "恢复完成，当前 crontab（末尾预览）:"
    crontab -l | tail -n 5
  else
    err "恢复失败（备份文件内容未通过 crontab 格式校验?）"
    return 1
  fi
}

# ---------- 动作分发 ----------

mod_cron_run() {
  local action="${1:-}"
  [[ -z "$action" ]] && { mod_cron_help; return 1; }
  shift || true

  case "$action" in
    list)    cron__list ;;
    backup)  cron__backup ;;
    add)     cron__add ;;
    check)   cron__check ;;
    restore) cron__restore "$@" ;;
    *)
      err "未知动作: cron ${action}"
      mod_cron_help
      return 1
      ;;
  esac
}
