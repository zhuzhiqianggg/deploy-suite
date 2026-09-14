#!/usr/bin/env bash
# 05_package_business_apps.sh - 业务应用打包脚本
# 用于将业务系统的 Helm Chart 或 K8s 资源打包到离线包中
# 此脚本作为扩展预留，当前为空实现

set -euo pipefail

ROOT_DIR="${ROOT_DIR:-/opt/install/offline-k8s}"
CONFIG_DIR="$ROOT_DIR/config"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn() { log "WARN: $*"; }
fatal() { log "ERROR: $*"; exit 1; }

usage() {
  cat <<EOF
用法: $0 <command> [options]

命令:
  add <chart>     添加 Helm Chart 到离线包
  list           列出已打包的业务应用
  verify         验证已打包的应用

示例:
  $0 add myapp-1.0.0.tgz
  $0 list
  $0 verify

注意:
  此脚本为业务扩展预留，当前版本尚未实现具体功能。
  业务应用打包将在后续阶段添加。

EOF
}

add_chart() {
  local chart_file="$1"
  if [[ ! -f "$chart_file" ]]; then
    fatal "Chart 文件不存在: $chart_file"
  fi

  log "添加 Chart: $chart_file"
  log "注意: 业务应用打包功能尚未实现"
  warn "请等待后续版本更新"
}

list_charts() {
  log "已打包的业务应用:"
  local charts_dir="${ROOT_DIR}/bundle/business-apps"
  if [[ -d "$charts_dir" ]]; then
    find "$charts_dir" -name "*.tgz" -o -name "*.tar.gz" 2>/dev/null | while read -r chart; do
      log "  $chart"
    done
  else
    log "  (暂无)"
  fi
}

verify_charts() {
  log "验证业务应用包:"
  local charts_dir="${ROOT_DIR}/bundle/business-apps"
  if [[ ! -d "$charts_dir" ]]; then
    log "  (暂无应用包需要验证)"
    return 0
  fi

  log "注意: 验证功能尚未实现"
}

main() {
  local command="${1:-}"

  case "$command" in
    add)
      add_chart "${2:-}"
      ;;
    list)
      list_charts
      ;;
    verify)
      verify_charts
      ;;
    help|--help|-h|"")
      usage
      ;;
    *)
      fatal "未知命令: $command"
      ;;
  esac
}

main "$@"
