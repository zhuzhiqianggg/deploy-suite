#!/usr/bin/env bash
# install_third_party_placeholders.sh - 第三方 tar 包部署占位脚本
# 目录约定:
#   /opt/doris-<version>  + /opt/doris -> /opt/doris-<version>
#   /opt/elasticsearch-<version> + /opt/es -> /opt/elasticsearch-<version>
#   /opt/jdk-<version>

set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%F %T')" "$*"; }

install_latest_tar() {
  local name="$1"
  local src_dir="$2"
  local link_path="$3"
  local prefix_regex="$4"

  if [[ ! -d "$src_dir" ]]; then
    warn "$name 目录不存在，跳过: $src_dir"
    return 0
  fi

  local tar_file
  tar_file=$(ls "$src_dir"/*.tar.gz "$src_dir"/*.tgz "$src_dir"/*.tar 2>/dev/null | head -1 || true)
  if [[ -z "$tar_file" ]]; then
    warn "$name 未提供 tar 包，跳过: $src_dir"
    return 0
  fi

  log "解压 $name: $tar_file"
  tar -xf "$tar_file" -C /opt

  local extracted
  extracted=$(find /opt -maxdepth 1 -type d -regextype posix-extended -regex "$prefix_regex" | sort | tail -1 || true)
  if [[ -n "$extracted" ]]; then
    ln -sfn "$extracted" "$link_path"
    log "$name 软链接: $link_path -> $extracted"
  else
    warn "$name 解压后未匹配目录: $prefix_regex"
  fi
}

install_latest_tar "Doris" "$ROOT_DIR/third-party/doris" "/opt/doris" "/opt/doris-.*"
install_latest_tar "Elasticsearch" "$ROOT_DIR/third-party/elasticsearch" "/opt/es" "/opt/elasticsearch-.*"
install_latest_tar "JDK" "$ROOT_DIR/third-party/jdk" "/opt/jdk" "/opt/jdk.*|/opt/jdk-.*"

log "第三方 tar 包占位部署完成。systemd service 文件后续按实际目录和启动参数补充。"
