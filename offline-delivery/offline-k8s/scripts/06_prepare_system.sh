#!/usr/bin/env bash
# 06_prepare_system.sh - 系统环境准备脚本
# 关闭 swap、防火墙、selinux，加载内核模块
# 参考 K8S基础环境构建.md 文档

set -euo pipefail

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%F %T')" "$*"; }
fatal() { log "ERROR: $*"; exit 1; }

if [[ $EUID -ne 0 ]]; then
  fatal "此脚本必须以 root 用户身份运行"
fi

# 1. 关闭 swap 分区
disable_swap() {
  log "步骤 1: 关闭 swap 分区"
  swapoff -a
  sysctl -w vm.swappiness=0
  # 注释掉 /etc/fstab 中的 swap 行
  sed -ri '/^[^#]*swap/s@^@#@' /etc/fstab
  log "swap 已关闭"
}

# 2. 检查 MAC 地址唯一性
check_mac_unique() {
  log "步骤 2: 检查 MAC 地址/UUID 唯一性"
  local mac
  mac=$(ip link show 2>/dev/null | awk '/ether/ {print $2; exit}' || echo "unknown")
  local uuid
  uuid=$(cat /sys/class/dmi/id/product_uuid 2>/dev/null || echo "unknown")
  log "  MAC: $mac"
  log "  UUID: $uuid"
}

# 3. 加载内核模块
load_kernel_modules() {
  log "步骤 3: 加载内核模块"
  cat > /etc/modules-load.d/k8s.conf <<EOF
br_netfilter
EOF

  modprobe br_netfilter 2>/dev/null || true
  log "  br_netfilter 已加载"
}

# 4. 配置 sysctl
configure_sysctl() {
  log "步骤 4: 配置 sysctl 参数"
  cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
# inotify（大量容器/Go 程序 fsnotify 场景，默认 128 实例会被耗尽，
# 表现为 kubelet/minio 等报 "failed to create fsnotify watcher: too many open files"）
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 1048576
EOF
  sysctl --system >/dev/null 2>&1
  log "  sysctl 已配置"
}

# 5. 关闭防火墙
disable_firewall() {
  log "步骤 5: 关闭防火墙"
  if systemctl is-active --quiet firewalld 2>/dev/null; then
    systemctl stop firewalld.service
    systemctl disable firewalld.service
    log "  firewalld 已关闭"
  else
    log "  firewalld 未运行"
  fi
}

# 6. 关闭 SELinux
disable_selinux() {
  log "步骤 6: 关闭 SELinux"
  if [[ -f /etc/selinux/config ]]; then
    setenforce 0 2>/dev/null || true
    sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
    log "  SELinux 已禁用"
  elif [[ -f /etc/sysconfig/selinux ]]; then
    setenforce 0 2>/dev/null || true
    sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/sysconfig/selinux
    log "  SELinux 已禁用"
  else
    log "  SELinux 配置文件不存在"
  fi
}

# 7. 设置时区和时间同步
configure_timezone() {
  log "步骤 7: 设置时区和时间同步"
  timedatectl set-timezone Asia/Shanghai 2>/dev/null || true

  # 离线环境优先用 chrony 系统时间, 不主动同步远端 NTP 服务器
  if command -v chronyc >/dev/null 2>&1; then
    log "  使用 chrony (如已配置)"
  elif command -v ntpdate >/dev/null 2>&1; then
    # 仅在网络可达时尝试同步 (离线环境会失败, 但不影响安装)
    if ntpdate -q time1.aliyun.com >/dev/null 2>&1; then
      ntpdate time1.aliyun.com 2>/dev/null && log "  时间已同步" || warn "  ntpdate 同步失败"
    else
      log "  网络不可达, 跳过时间同步 (不影响 K8s 安装)"
    fi
  else
    log "  未安装时间同步工具, 跳过"
  fi
}

# 8. 配置 containerd 优化
optimize_containerd() {
  log "步骤 8: 优化 containerd 配置"
  if [[ ! -f /etc/containerd/config.toml ]]; then
    if command -v containerd >/dev/null 2>&1; then
      mkdir -p /etc/containerd
      containerd config default > /etc/containerd/config.toml
    fi
  fi

  if [[ -f /etc/containerd/config.toml ]]; then
    # 启用 SystemdCgroup
    sed -ri 's#(SystemdCgroup = )false#\1true#' /etc/containerd/config.toml || true
    log "  containerd 已配置 SystemdCgroup"
  fi
}

main() {
  log "========================================"
  log "K8s 系统环境准备"
  log "========================================"

  disable_swap
  check_mac_unique
  load_kernel_modules
  configure_sysctl
  disable_firewall
  disable_selinux
  configure_timezone
  optimize_containerd

  log "========================================"
  log "系统准备完成"
  log "========================================"
}

main "$@"
