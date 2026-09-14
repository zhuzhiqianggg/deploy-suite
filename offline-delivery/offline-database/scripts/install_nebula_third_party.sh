#!/usr/bin/env bash
# install_nebula_third_party.sh - NebulaGraph 辅助组件 tar 包占位部署
# 仅属于 offline-database，不属于 offline-k8s/offline-docker。

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%F %T')" "$*"; }

install_component() {
  local name="$1"
  local src_dir="$2"
  local link_path="$3"
  local match_regex="$4"

  local tar_file extracted
  tar_file=$(ls "$src_dir"/*.tar.gz "$src_dir"/*.tgz "$src_dir"/*.tar 2>/dev/null | head -1 || true)

  if [[ -n "$tar_file" ]]; then
    log "解压 $name: $tar_file"
    tar -xf "$tar_file" -C /opt
  else
    warn "$name 未提供 tar 包，跳过解压: $src_dir"
  fi

  extracted=$(find /opt -maxdepth 1 -type d -regextype posix-extended -regex "$match_regex" | sort | tail -1 || true)
  if [[ -n "$extracted" ]]; then
    ln -sfn "$extracted" "$link_path"
    log "$name 软链接: $link_path -> $extracted"
  else
    warn "$name 未找到可链接目录: $match_regex"
  fi
}

mkdir -p /data/nebulagraph

install_component "NebulaGraph" "$ROOT_DIR/third-party/nebula-graph" "/opt/nebula-graph" "/opt/nebula-graph.*"
install_component "Nebula Dashboard" "$ROOT_DIR/third-party/nebula-dashboard" "/opt/nebula-dashboard" "/opt/nebula-dashboard.*"
install_component "Nebula Studio" "$ROOT_DIR/third-party/nebula-studio" "/opt/nebula-studio" "/opt/nebula-studio.*"

log "NebulaGraph 辅助组件占位部署完成。"
