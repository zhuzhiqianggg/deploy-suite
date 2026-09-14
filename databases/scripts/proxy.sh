#!/usr/bin/env bash
# ============================================================================
# K8s containerd 临时代理 (拉镜像用, 用完一键清理)
# 基于 Shadowsocks 代理 → HTTP_PROXY 给 containerd
#
# 用法:
#   sudo bash proxy-on.sh          # 开启代理
#   sudo bash proxy-off.sh         # 关闭代理 (清理还原)
#   sudo bash proxy-on.sh --pull   # 开启后拉所有 DB 镜像再关闭
# ============================================================================
set -euo pipefail

ACTION="${1:-on}"

# ── SS 节点配置 (你提供的) ────────────────────────────────────────────────────
SS_SERVER="159.138.83.250"
SS_PORT="53580"
SS_CIPHER="aes-256-gcm"
SS_PASSWORD="74AxSaPRu7C4GQmwLzVhVQ=="
LOCAL_HTTP_PORT="10809"          # 本地 HTTP 代理端口
LOCAL_SOCKS_PORT="10808"          # 本地 SOCKS5 端口

# ── 临时目录 ─────────────────────────────────────────────────────────────────
PROXY_DIR="/tmp/k8s-proxy"
SS_LOCAL="${PROXY_DIR}/ss-local"
SS_LOG="${PROXY_DIR}/ss.log"
PROXY_ENV_FILE="/etc/systemd/system/containerd.service.d/http-proxy.conf"

# ── 需要拉取的所有镜像 ────────────────────────────────────────────────────────
IMAGES=(
  # NFS
  "registry.k8s.io/sig-storage/nfs-subdir-external-provisioner:v4.0.2"
  # MySQL 8.4
  "bitnami/mysql:8.4-debian-12-r0"
  "bitnami/mysqld-exporter:0.17.2-debian-12-r16"
  # Redis 8.2
  "bitnami/redis:8.2.1-debian-12-r0"
  "bitnami/redis-exporter:1.63.0-debian-12-r0"
  # Kafka 4.0
  "bitnami/kafka:4.0.0-debian-12-r0"
  "bitnami/kafka-exporter:1.8.0-debian-12-r0"
  # ES 7.17.x 最新
  "docker.elastic.co/elasticsearch/elasticsearch:7.17.3"
  "docker.elastic.co/kibana/kibana:7.17.3"
  # Kafka-UI
  "provectuslabs/kafka-ui:v0.9.0"
  # Kafka-Exporter
  "danielqsj/kafka-exporter:v1.8.0"
  # ES-Exporter
  "quay.io/prometheuscommunity/elasticsearch-exporter:v1.7.0"
)

GREEN='\033[32m'; RED='\033[31m'; YELLOW='\033[33m'; BLUE='\033[34m'; RESET='\033[0m'
log()   { echo -e "${GREEN}[INFO]${RESET} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET} $*"; }
err()   { echo -e "${RED}[ERROR]${RESET} $*"; exit 1; }
stage() { echo -e "\n${BLUE}══════════════════════════════════════════${RESET}"; echo -e "${BLUE}  $*${RESET}"; echo -e "${BLUE}══════════════════════════════════════════${RESET}"; }

# ============================================================================
# 1. 安装 ss-local (shadowsocks-libev)
# ============================================================================
install_ss() {
  mkdir -p "$PROXY_DIR"

  if command -v ss-local >/dev/null 2>&1; then
    log "ss-local 已安装"
    return
  fi

  if [[ ! -f "$SS_LOCAL" ]]; then
    log "下载 ss-local 到 $PROXY_DIR/..."
    # 下载独立编译的二进制 (ARM64)
    curl -fsSL "https://github.com/shadowsocks/shadowsocks-libev/releases/download/v3.3.5/shadowsocks-libev-3.3.5-llvm12-linux-aarch64.tar.gz" \
      -o "${PROXY_DIR}/ss.tar.gz" 2>/dev/null || {
      # 备用: apt
      apt-get install -y shadowsocks-libev 2>/dev/null && command -v ss-local >/dev/null 2>&1 && return || true
      err "ss-local 安装失败，请手动: apt install shadowsocks-libev"
    }
    tar xzf "${PROXY_DIR}/ss.tar.gz" -C "$PROXY_DIR" 2>/dev/null
    cp "${PROXY_DIR}/bin/ss-local" "$SS_LOCAL" 2>/dev/null || true
    chmod +x "$SS_LOCAL"
  fi
}

# ============================================================================
# 2. 启动 SS 本地代理
# ============================================================================
start_proxy() {
  if pgrep -f "ss-local.*${SS_SERVER}" >/dev/null 2>&1; then
    log "SS 代理已在运行"
    return
  fi

  stage "启动 Shadowsocks 本地代理"
  install_ss

  cat > "${PROXY_DIR}/ss-config.json" <<EOF
{
  "server": "${SS_SERVER}",
  "server_port": ${SS_PORT},
  "password": "${SS_PASSWORD}",
  "timeout": 300,
  "method": "${SS_CIPHER}",
  "fast_open": false
}
EOF

  ss-local -c "${PROXY_DIR}/ss-config.json" \
    -l 127.0.0.1:${LOCAL_SOCKS_PORT} \
    -v >"$SS_LOG" 2>&1 &

  sleep 3
  if pgrep -f "ss-local.*${SS_SERVER}" >/dev/null 2>&1; then
    log "✅ SS 代理运行 (SOCKS5 127.0.0.1:${LOCAL_SOCKS_PORT})"
  else
    err "SS 启动失败, 看日志: $SS_LOG"
  fi

  # 用 privoxy 把 SOCKS5 转 HTTP (如果有)
  # 或者直接用 goproxy
  if ! command -v goproxy >/dev/null 2>&1; then
    log "下载 goproxy..."
    curl -fsSL "https://github.com/snail007/goproxy/releases/download/v9.7/proxy-linux-arm64.tar.gz" \
      -o "${PROXY_DIR}/goproxy.tar.gz" 2>/dev/null && {
      mkdir -p "${PROXY_DIR}/goproxy"
      tar xzf "${PROXY_DIR}/goproxy.tar.gz" -C "${PROXY_DIR}/goproxy"
    } || warn "goproxy 下载失败, 直接用 SOCKS5 代理环境变量"
  fi

  # 直接用 SOCKS5 环境变量
  export HTTPS_PROXY="socks5h://127.0.0.1:${LOCAL_SOCKS_PORT}"
  export HTTP_PROXY="socks5h://127.0.0.1:${LOCAL_SOCKS_PORT}"
  export NO_PROXY="localhost,127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.local,.svc"
  log "✅ 代理环境变量已设置"
}

# ============================================================================
# 3. 把代理注入 containerd (systemd drop-in)
# ============================================================================
apply_containerd_proxy() {
  stage "配置 containerd 代理"

  mkdir -p "$(dirname "$PROXY_ENV_FILE")"
  cat > "$PROXY_ENV_FILE" <<EOF
[Service]
Environment="HTTP_PROXY=socks5h://127.0.0.1:${LOCAL_SOCKS_PORT}"
Environment="HTTPS_PROXY=socks5h://127.0.0.1:${LOCAL_SOCKS_PORT}"
Environment="NO_PROXY=localhost,127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.local,.svc,sealos.hub"
EOF

  log "重启 containerd..."
  sudo systemctl daemon-reload
  sudo pkill -9 containerd 2>/dev/null; sleep 2
  sudo systemctl start containerd
  sleep 8
  sudo ctr plugins ls 2>/dev/null | grep -q "cri.*ok" && log "✅ containerd 代理已生效" || err "containerd CRI 未就绪"
}

# ============================================================================
# 4. 关闭代理 (清理还原)
# ============================================================================
stop_proxy() {
  stage "清理代理配置"

  # 杀 ss-local
  pkill -f "ss-local.*${SS_SERVER}" 2>/dev/null || true
  pkill -f "goproxy" 2>/dev/null || true

  # 清 containerd 代理
  if [[ -f "$PROXY_ENV_FILE" ]]; then
    rm -f "$PROXY_ENV_FILE"
    log "已删除 $PROXY_ENV_FILE"
  fi

  sudo systemctl daemon-reload
  sudo pkill -9 containerd 2>/dev/null; sleep 2
  sudo systemctl start containerd
  sleep 8
  sudo ctr plugins ls 2>/dev/null | grep -q "cri.*ok" && log "✅ containerd 已还原" || warn "containerd 状态检查失败"

  # 清环境变量
  unset HTTPS_PROXY HTTP_PROXY NO_PROXY

  # 清临时文件
  # rm -rf "$PROXY_DIR"  # 留着下次用
  log "✅ 代理已关闭, 环境已还原"
}

# ============================================================================
# 5. 批量拉取所有镜像
# ============================================================================
pull_all() {
  stage "批量拉取镜像 (${#IMAGES[@]} 个)"
  SUCCESS=0
  FAIL=0
  PULLED=()

  for img in "${IMAGES[@]}"; do
    echo -n "  $img ... "
    if sudo ctr images pull "$img" >/dev/null 2>&1; then
      echo -e "${GREEN}✅${RESET}"
      SUCCESS=$((SUCCESS + 1))
      PULLED+=("$img")
    else
      echo -e "${RED}❌${RESET}"
      FAIL=$((FAIL + 1))
    fi
  done

  echo ""
  echo "══════════════════════════════════════════"
  echo "  拉取完成: ✅ $SUCCESS  ❌ $FAIL"
  echo "══════════════════════════════════════════"

  if [[ ${#PULLED[@]} -gt 0 ]]; then
    echo ""
    echo "成功列表 (可复制到 sync-images.sh):"
    for p in "${PULLED[@]}"; do echo "  $p"; done
  fi
}

# ============================================================================
# 主入口
# ============================================================================
case "${1:-on}" in
  on)        start_proxy; apply_containerd_proxy ;;
  off)       stop_proxy ;;
  pull)      start_proxy; apply_containerd_proxy; pull_all ;;
  clean)     stop_proxy; rm -rf "$PROXY_DIR"; log "✅ 完全清理" ;;
  *)
    cat <<USAGE
用法: sudo bash proxy.sh [命令]

  on        开启代理 (SS → containerd)
  off       关闭代理 + 还原环境
  pull      开启代理 → 批量拉取镜像 → 保持开启 (等部署完手动 off)
  clean     完全清理 (代理+临时文件)

USAGE
    ;;
esac
