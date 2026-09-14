#!/usr/bin/env bash
# 00_check_env.sh - 环境预检查脚本
# 在执行任何安装或下载操作前验证系统环境

set -euo pipefail

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%F %T')" "$*"; }
fatal() { log "ERROR: $*"; exit 1; }

ROOT_DIR="${ROOT_DIR:-/opt/install/offline-k8s}"

# 检查是否为 root 用户
check_root() {
  if [[ $EUID -ne 0 ]]; then
    fatal "此脚本必须以 root 用户身份运行"
  fi
  log "root 用户检查通过"
}

# 检查架构
check_arch() {
  local arch
  arch=$(uname -m)
  source "$ROOT_DIR/config/versions.lock" 2>/dev/null
  local expected_rpm="${RPM_ARCH:-aarch64}"
  if [[ "$arch" != "$expected_rpm" ]]; then
    warn "当前架构: $arch, 目标架构: $expected_rpm (ARCH=${ARCH:-arm64})"
    warn "如果目标服务器架构不同，当前环境可能仅用于打包"
  else
    log "架构检查通过: $arch"
  fi
}

# 检查操作系统
check_os() {
  if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    log "操作系统: $NAME $VERSION"
  else
    warn "无法确定操作系统类型"
  fi
}

# 检查必要的命令
check_commands() {
  local missing=()
  local required_cmds=("curl" "tar" "sha256sum" "python3" "gawk" "dnf" "kubeadm" "kubectl" "crictl")

  for cmd in "${required_cmds[@]}"; do
    if command -v "$cmd" >/dev/null 2>&1; then
      log "  已安装: $cmd"
    else
      warn "  缺失: $cmd"
      missing+=("$cmd")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    warn "缺少 ${#missing[@]} 个命令，某些功能可能受限"
  fi
}

# 检查网络连接
check_network() {
  log "检查网络连接..."
  if curl -fsSL --connect-timeout 5 "https://dl.k8s.io/release/stable.txt" >/dev/null 2>&1; then
    log "  Kubernetes 下载源: 可达"
  else
    warn "  Kubernetes 下载源: 不可达"
  fi

  if curl -fsSL --connect-timeout 5 "https://api.github.com" >/dev/null 2>&1; then
    log "  GitHub API: 可达"
  else
    warn "  GitHub API: 不可达"
  fi

  if curl -fsSL --connect-timeout 5 "https://registry.k8s.io" >/dev/null 2>&1; then
    log "  K8s 镜像仓库: 可达"
  else
    warn "  K8s 镜像仓库: 不可达"
  fi
}

# 检查磁盘空间
check_disk_space() {
  local required_gb=50
  local available_gb

  if [[ -d "$ROOT_DIR" ]]; then
    available_gb=$(df -BG "$ROOT_DIR" | awk 'NR==2 {print $4}' | tr -d 'G')
    available_gb=${available_gb:-0}

    if [[ $available_gb -ge $required_gb ]]; then
      log "磁盘空间检查通过: ${available_gb}G 可用 (需要 ${required_gb}G)"
    else
      warn "磁盘空间不足: ${available_gb}G 可用，需要 ${required_gb}G"
    fi
  fi
}

# 检查版本文件
check_versions() {
  local versions_file="$ROOT_DIR/config/versions.lock"
  if [[ -f "$versions_file" ]]; then
    log "版本锁定文件存在: $versions_file"
    log "组件版本:"
    grep -E '^[A-Z_]+=' "$versions_file" | while read -r line; do
      log "  $line"
    done
  else
    warn "版本锁定文件不存在: $versions_file"
  fi
}

# 检查 Kubernetes 服务状态
check_kubernetes() {
  if systemctl is-active --quiet kubelet 2>/dev/null; then
    log "kubelet 服务: 运行中"
  else
    warn "kubelet 服务: 未运行"
  fi

  if command -v kubectl >/dev/null 2>&1; then
    local version
    version=$(kubectl version --client 2>/dev/null | grep -oP 'GitVersion:"v\K[^"]+' || echo "unknown")
    log "kubectl 版本: $version"
  fi
}

# 检查容器运行时
check_container_runtime() {
  if command -v docker >/dev/null 2>&1; then
    log "Docker: $(docker --version 2>/dev/null || echo '可用但版本未知')"
  fi

  if command -v podman >/dev/null 2>&1; then
    log "Podman: $(podman --version 2>/dev/null || echo '可用但版本未知')"
  fi

  if command -v crictl >/dev/null 2>&1; then
    log "crictl: 可用"
  fi
}

# 主函数
main() {
  log "========================================"
  log "离线 K8s 部署环境预检查"
  log "========================================"

  check_root
  check_arch
  check_os
  check_commands
  check_network
  check_disk_space
  check_versions
  check_kubernetes
  check_container_runtime

  log "========================================"
  log "环境检查完成"
  log "========================================"

  if command -v "$ROOT_DIR/scripts/01_download_online.sh" >/dev/null 2>&1; then
    log "下一步: 执行 01_download_online.sh 进行下载"
  fi
}

main "$@"
