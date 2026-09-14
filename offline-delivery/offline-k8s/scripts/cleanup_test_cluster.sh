#!/usr/bin/env bash
# cleanup_test_cluster.sh - 清理测试集群脚本
# 彻底清理 K8s 集群 + containerd 残留数据，以便 sealos 完全重新安装

set -euo pipefail

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%F %T')" "$*"; }
fatal() { log "ERROR: $*"; exit 1; }

if [[ $EUID -ne 0 ]]; then
  fatal "此脚本必须以 root 用户身份运行"
fi

cleanup() {
  log "开始清理 Kubernetes 集群 (含 containerd 残留)"

  if command -v sealos >/dev/null 2>&1; then
    log "使用 sealos reset 清理集群 (最多等待 120 秒)"
    timeout 120 sealos reset --force --cluster default >/dev/null 2>&1 || warn "sealos reset 未完成或失败，继续兜底清理"
  fi

  log "停止 kubelet/containerd/docker 并清理进程"
  systemctl stop kubelet 2>/dev/null || true
  systemctl stop containerd 2>/dev/null || true
  systemctl stop docker dockerd 2>/dev/null || true
  systemctl stop registry image-cri-shim 2>/dev/null || true
  for pattern in '^kube-apiserver( |$)' '^kube-controller-manager( |$)' '^kube-scheduler( |$)' '^kubelet( |$)' '(^|/)etcd( |$)' '(^|/)containerd-shim' '(^|/)containerd( |$)' '(^|/)dockerd( |$)'; do
    pkill -9 -f "$pattern" 2>/dev/null || true
  done
  sleep 2

  if command -v crictl >/dev/null 2>&1; then
    crictl stopp -a 2>/dev/null || true
    crictl rm -a 2>/dev/null || true
    crictl rmp -a 2>/dev/null || true
  fi

  log "清理 K8s 配置和数据目录"
  rm -f /root/.kube/config 2>/dev/null || true
  rm -rf /root/.sealos /var/lib/sealos 2>/dev/null || true
  rm -rf /etc/kubernetes /var/lib/etcd /var/lib/kubelet /var/lib/calico /etc/cni/net.d /var/lib/cni 2>/dev/null || true
  rm -f /etc/systemd/system/kubelet.service /etc/systemd/system/registry.service /etc/systemd/system/image-cri-shim.service 2>/dev/null || true

  # 彻底清理 docker（sealos run 检测到 docker 会拒绝安装）
  log "清理 docker 残留"
  pkill -9 -f dockerd 2>/dev/null || true
  rm -rf /var/lib/docker 2>/dev/null || true
  rm -f /etc/docker/daemon.json 2>/dev/null || true
  rm -f /usr/bin/docker /usr/bin/dockerd /usr/local/bin/docker /usr/local/bin/dockerd 2>/dev/null || true
  rm -f /usr/bin/docker-compose /usr/local/bin/docker-compose 2>/dev/null || true
  rm -f /etc/systemd/system/docker.service /etc/systemd/system/docker.socket 2>/dev/null || true

  # 清理 containerd 数据与配置（保留二进制，后续 sealos load 需要）
  log "清理 containerd 残留数据"
  rm -rf /var/lib/containerd 2>/dev/null || true
  rm -rf /etc/containerd 2>/dev/null || true

  mkdir -p /etc/kubernetes /var/lib/kubelet /etc/cni/net.d /var/lib/sealos/data /etc/containerd 2>/dev/null || true

  # 确保 containerd systemd 服务存在
  if ! systemctl list-unit-files containerd.service &>/dev/null; then
    log "重建 containerd systemd 服务"
    cat > /etc/systemd/system/containerd.service <<'SERVICE'
[Unit]
Description=containerd container runtime
After=network.target local-fs.target

[Service]
ExecStartPre=-/sbin/modprobe overlay
ExecStart=/usr/local/bin/containerd
Type=notify
Delegate=yes
KillMode=process
Restart=always
RestartSec=5
LimitNPROC=infinity
LimitCORE=infinity
LimitNOFILE=infinity
TasksMax=infinity
OOMScoreAdjust=-999

[Install]
WantedBy=multi-user.target
SERVICE
    systemctl daemon-reload 2>/dev/null || true
  fi

  # 生成默认 containerd 配置
  if command -v containerd >/dev/null 2>&1; then
    containerd config default > /etc/containerd/config.toml 2>/dev/null || true
  fi

  # 启动 containerd —— 全新状态
  log "启动 containerd (全新状态)"
  systemctl enable containerd 2>/dev/null || true
  systemctl reset-failed containerd 2>/dev/null || true
  systemctl start containerd 2>/dev/null || true

  local wait_sec=0
  while [[ ! -S /run/containerd/containerd.sock ]]; do
    sleep 1
    wait_sec=$((wait_sec + 1))
    if [[ $wait_sec -ge 30 ]] && command -v containerd >/dev/null 2>&1; then
      log "systemd 启动超时，直接启动 containerd"
      nohup /usr/local/bin/containerd >/var/log/containerd.log 2>&1 &
    fi
    if [[ $wait_sec -ge 45 ]]; then
      fatal "containerd socket 未恢复，请手动执行: /usr/local/bin/containerd &"
    fi
  done
  log "containerd socket 已就绪"

  log "清理完成"
}

main() {
  log "========================================"
  log "Kubernetes 集群清理脚本"
  log "========================================"

  if [[ "${ASSUME_YES:-false}" != "true" ]]; then
    if [[ ! -t 0 ]]; then
      fatal "非交互模式下请设置 ASSUME_YES=true 确认继续，或在交互终端执行"
    fi
    local answer
    read -r -p "此操作将清理整个 K8s 集群并重置 containerd，确认继续？输入 yes 继续: " answer
    [[ "$answer" == "yes" ]] || fatal "用户取消清理"
  fi

  cleanup

  log "========================================"
  log "清理完成"
  log "========================================"
  log "如需重新安装，执行: ./install_offline.sh"
  log "========================================"
}

main "$@"
