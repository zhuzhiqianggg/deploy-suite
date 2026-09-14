#!/usr/bin/env bash
# ==============================================================================
# lops 模块: backup — 备份与清理
# ==============================================================================

LOPS_BACKUP_KEEP="${LOPS_BACKUP_KEEP:-7}"

mod_backup_desc() {
  echo "备份与清理（目录打包备份/journald 治理/过期备份清理）"
}

mod_backup_actions() {
  cat <<'EOF'
dir|目录打包备份为带时间戳的 tar.gz（自动轮转保留）
cleanlog|journald 日志用量展示与清理（vacuum 7天/500M）
old|清理目录中超过 N 天的 *.tar.gz / *.bak 文件
EOF
}

mod_backup_help() {
  cat <<EOF
lops backup — 备份与清理
==============================================================================
日常备份三件事：目录打包（自动带时间戳、自动轮转旧备份）、
journald 日志治理（磁盘占用大户）、过期备份/临时文件清理。
删除类操作一律先列清单、二次确认后才执行。

用法:
  ./lops.sh backup <action> [参数]

动作说明:
  dir <源目录> [目标目录]
                    tar.gz 打包备份，文件名:
                    <源目录名>_YYYYmmdd-HHMMSS.tar.gz
                    目标目录默认 /opt/backup/lops（自动创建）。
                    目标目录中同名前缀的旧备份超过 LOPS_BACKUP_KEEP 份时，
                    列出将删除的旧文件，确认后删除（自动轮转）。
  cleanlog         journald 日志治理:
                    ① journalctl --disk-usage 展示当前占用
                    ② 确认后执行 vacuum-time=7d + vacuum-size=500M
                    ③ 列出 /var/log 下 >100M 的大文件（仅提示，不自动删）
  old <目录> [天数]
                    清理目录中 mtime 超过 N 天（默认 30）的
                    *.tar.gz 与 *.bak 文件。先列出清单与总大小，
                    确认后才删除，并汇报删除数量与释放空间。

可配置环境变量:
  LOPS_BACKUP_KEEP=7         # dir 动作保留的备份份数

示例:
  ./lops.sh backup dir /data                  # 备份 /data 到默认目录
  ./lops.sh backup dir /data /mnt/backup      # 备份到指定目录
  LOPS_BACKUP_KEEP=30 ./lops.sh backup dir /data
  ./lops.sh backup cleanlog                   # journald 治理
  ./lops.sh backup old /opt/backup/lops 60    # 清理 60 天前的旧备份

前置条件:
  - dir 写目标目录、cleanlog 执行 vacuum、old 删文件均需 root
  - dir 依赖 tar（系统默认自带）

注意事项:
  - dir 打包期间源目录若有写入，快照可能不一致，重要数据建议
    在业务低峰或停写后备份。
  - cleanlog 只治理 journald；/var/log 的大文件仅列出，
    判断可删后手动处理，避免误删业务日志。
  - old 仅匹配 *.tar.gz 与 *.bak，不会动其他文件。
EOF
}

# ---------- 动作实现 ----------

backup__dir() {
  local src="${1:-}"
  local dst="${2:-/opt/backup/lops}"

  if [[ -t 0 && -z "$src" ]]; then
    src="$(ask_value "要备份的源目录")"
  fi
  if [[ -z "$src" ]]; then
    err "用法: lops.sh backup dir <源目录> [目标目录]"
    return 1
  fi
  if [[ ! -d "$src" ]]; then
    err "源目录不存在: ${src}"
    return 1
  fi

  require_root
  mkdir -p "$dst"

  local name ts outfile
  name="$(basename "$src")"
  ts="$(date '+%Y%m%d-%H%M%S')"
  outfile="${dst}/${name}_${ts}.tar.gz"

  section "打包备份"
  print_kv "源目录" "$src"
  print_kv "备份文件" "$outfile"
  log "开始打包（目录大时耗时较长）..."
  if ! tar -czf "$outfile" -C "$(dirname "$src")" "$name"; then
    err "打包失败"
    rm -f "$outfile"
    return 1
  fi
  print_kv "文件大小" "$(du -h "$outfile" | awk '{print $1}')"
  mark_ok "备份完成"

  # 轮转旧备份（用数组承载路径，避免路径含空格时被切分）
  local -a olds=()
  local f total listing
  # shellcheck disable=SC2012  # 需按 mtime 排序取最旧的轮转备份，ls -1t 最直接
  listing="$(ls -1t "${dst}/${name}_"*.tar.gz 2>/dev/null | tail -n +$(( LOPS_BACKUP_KEEP + 1 )))"
  while IFS= read -r f; do
    [[ -n "$f" ]] && olds+=("$f")
  done <<< "$listing"
  if (( ${#olds[@]} > 0 )); then
    echo ""
    section "旧备份轮转（保留最近 ${LOPS_BACKUP_KEEP} 份）"
    echo "以下旧备份将被删除:"
    for f in "${olds[@]}"; do echo "  $f"; done
    total="$(du -ch -- "${olds[@]}" 2>/dev/null | tail -n 1 | awk '{print $1}')"
    print_kv "可释放空间" "${total:-未知}"
    if confirm "确认删除上述旧备份"; then
      rm -f -- "${olds[@]}"
      log "旧备份已清理"
    else
      log "跳过清理，旧备份保留"
    fi
  fi
}

backup__cleanlog() {
  require_root
  section "journald 日志治理"
  log "当前 journald 占用:"
  journalctl --disk-usage

  echo ""
  if ! confirm "执行清理（保留 7 天 / 上限 500M）"; then
    log "已取消清理"
    return 0
  fi

  journalctl --vacuum-time=7d
  journalctl --vacuum-size=500M
  echo ""
  log "清理后占用:"
  journalctl --disk-usage

  echo ""
  section "/var/log 下大于 100M 的文件（仅提示，请人工判断）"
  local big
  big="$(find /var/log -type f -size +100M 2>/dev/null || true)"
  if [[ -n "$big" ]]; then
    while read -r f; do
      [[ -z "$f" ]] && continue
      mark_warn "$(du -h "$f" | awk '{print $1}')  $f"
    done <<< "$big"
    log "确认可删的请手动处理（如已轮转的旧日志）"
  else
    mark_ok "无 >100M 的日志文件"
  fi
}

backup__old() {
  local dir="${1:-}"
  local days="${2:-30}"

  if [[ -t 0 && -z "$dir" ]]; then
    dir="$(ask_value "要清理的目录")"
  fi
  if [[ -z "$dir" || ! -d "$dir" ]]; then
    err "用法: lops.sh backup old <目录> [天数]"
    [[ -n "$dir" ]] && err "目录不存在: ${dir}"
    return 1
  fi

  section "过期文件清理（mtime > ${days} 天）"
  # 用数组承载路径，避免路径含空格时被切分
  local -a targets=()
  local f total
  while IFS= read -r f; do
    if [[ -n "$f" ]]; then targets+=("$f"); fi
  done < <(find "$dir" -maxdepth 1 -type f \( -name '*.tar.gz' -o -name '*.bak' \) -mtime +"$days" 2>/dev/null || true)
  if (( ${#targets[@]} == 0 )); then
    mark_ok "无超过 ${days} 天的 *.tar.gz / *.bak 文件"
    return 0
  fi

  echo "以下文件将被删除:"
  for f in "${targets[@]}"; do
    printf "  %s\t%s\n" "$(du -h "$f" | awk '{print $1}')" "$f"
  done
  total="$(du -ch -- "${targets[@]}" 2>/dev/null | tail -n 1 | awk '{print $1}')"
  print_kv "合计" "${total}（${#targets[@]} 个文件）"

  if ! confirm "确认删除上述文件（不可恢复）"; then
    log "已取消"
    return 0
  fi

  rm -f -- "${targets[@]}"
  log "已删除 ${#targets[@]} 个文件，释放 ${total}"
}

# ---------- 动作分发 ----------
mod_backup_run() {
  local action="${1:-}"
  [[ -z "$action" ]] && { mod_backup_help; return 1; }
  shift || true

  case "$action" in
    dir)      backup__dir "$@" ;;
    cleanlog) backup__cleanlog ;;
    old)      backup__old "$@" ;;
    *)
      err "未知动作: backup ${action}"
      mod_backup_help
      return 1
      ;;
  esac
}
