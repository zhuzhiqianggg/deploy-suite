#!/usr/bin/env bash
# install_third_party_binaries.sh - 第三方二进制包部署脚本
# 支持: JDK / Elasticsearch / Doris
#
# 约定:
#   - 将 tar 包放到 offline-database/third-party/{jdk,elasticsearch,doris}/
#   - 解压到 /opt/{jdk,elasticsearch,doris-<version>,doris-<version>}
#   - 创建软链接 /opt/jdk /opt/es /opt/doris 指向最新版本
#   - 数据目录: /data/{elasticsearch,doris}/{data,logs,conf}

set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log()  { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%F %T')" "$*"; }
fatal(){ printf '[%s] ERROR: %s\n' "$(date '+%F %T')" "$*"; exit 1; }

# 查找最新的压缩包
find_latest_pkg() {
  local src_dir="$1"
  if [[ ! -d "$src_dir" ]]; then
    return 1
  fi
  ls -1 "$src_dir"/*.tar.gz "$src_dir"/*.tgz "$src_dir"/*.tar "$src_dir"/*.tar.xz 2>/dev/null | sort -V | tail -1
}

# 通用解压安装
install_pkg() {
  local name="$1"
  local src_dir="$2"
  local link_path="$3"
  local prefix_regex="$4"

  local pkg
  pkg=$(find_latest_pkg "$src_dir" || true)
  if [[ -z "$pkg" ]]; then
    warn "$name 未提供安装包，跳过: $src_dir"
    return 0
  fi

  log "解压 $name: $pkg"
  case "$pkg" in
    *.tar.xz) tar -xJf "$pkg" -C /opt ;;
    *.tar.gz|*.tgz) tar -xzf "$pkg" -C /opt ;;
    *.tar) tar -xf "$pkg" -C /opt ;;
    *) fatal "未知压缩格式: $pkg" ;;
  esac

  local extracted
  extracted=$(find /opt -maxdepth 1 -type d -regextype posix-extended -regex "$prefix_regex" | sort -V | tail -1 || true)
  if [[ -n "$extracted" ]]; then
    ln -sfn "$extracted" "$link_path"
    log "$name 软链接: $link_path -> $extracted"
  else
    warn "$name 解压后未匹配目录: $prefix_regex"
  fi
}

# 安装 JDK
install_jdk() {
  install_pkg "JDK" "$ROOT_DIR/third-party/jdk" "/opt/jdk" "/opt/jdk.*|/opt/jdk-.*|/opt/jre.*|/opt/jre-.*"
  if [[ -L "/opt/jdk" ]]; then
    log "设置 JAVA_HOME=/opt/jdk"
    mkdir -p /etc/profile.d
    cat > /etc/profile.d/jdk.sh <<'EOF'
export JAVA_HOME=/opt/jdk
export PATH=$JAVA_HOME/bin:$PATH
export CLASSPATH=.:$JAVA_HOME/lib
EOF
    chmod +x /etc/profile.d/jdk.sh
  fi
}

# 安装 Elasticsearch
install_elasticsearch() {
  install_pkg "Elasticsearch" "$ROOT_DIR/third-party/elasticsearch" "/opt/es" "/opt/elasticsearch-.*"
  if [[ -L "/opt/es" ]]; then
    log "创建 Elasticsearch 数据目录"
    mkdir -p /data/elasticsearch/{data,logs,config}
    chown -R 1000:1000 /data/elasticsearch 2>/dev/null || warn "无法修改 /data/elasticsearch 属主(非 root 运行?), ES 容器内使用 uid 1000"
    log "Elasticsearch 二进制已安装到 /opt/es"
    log "启动命令(单机): /opt/es/bin/elasticsearch -d -p /data/elasticsearch/es.pid"
  fi
}

# 安装 Doris
install_doris() {
  install_pkg "Doris" "$ROOT_DIR/third-party/doris" "/opt/doris" "/opt/apache-doris-.*|/opt/doris-.*"
  if [[ -L "/opt/doris" ]]; then
    log "创建 Doris 数据目录"
    mkdir -p /data/doris/{fe,be}/{data,log,conf}
    log "Doris 二进制已安装到 /opt/doris"
    warn "Doris 生产集群部署请参考官方文档配置 FE/BE，当前仅完成解压和目录初始化"
  fi
}

# 入口
install_jdk
install_elasticsearch
install_doris

log "第三方二进制包部署完成。"
