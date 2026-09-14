#!/usr/bin/env bash
# 03_test_install_local.sh - 本地测试安装 Kubernetes 集群
# 在当前服务器上测试安装，验证所有组件正常工作

set -euo pipefail

ROOT_DIR="${ROOT_DIR:-/opt/install/offline-k8s}"
CONFIG_DIR="$ROOT_DIR/config"
VERSIONS_LOCK="$CONFIG_DIR/versions.lock"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%F %T')" "$*"; }
error() { printf '[%s] ERROR: %s\n' "$(date '+%F %T')" "$*"; }
fatal() { error "$*"; exit 1; }

# 加载版本锁定
# shellcheck disable=SC1090
source "$VERSIONS_LOCK"

SEALOS="${ROOT_DIR}/bin/${ARCH}/sealos"

get_master_ip() {
  local ip
  ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  ip=${ip:-127.0.0.1}
  echo "$ip"
}

check_prerequisites() {
  log "检查前提条件"

  if [[ ! -x "$SEALOS" ]]; then
    fatal "sealos 未安装: $SEALOS"
  fi

  if [[ ! -f "${ROOT_DIR}/sealos-images/kubernetes-${KUBERNETES_VERSION}-${ARCH}.tar" ]]; then
    fatal "缺少 Kubernetes cluster image"
  fi

  if [[ ! -f "${ROOT_DIR}/sealos-images/calico-${CALICO_VERSION}-${ARCH}.tar" ]]; then
    fatal "缺少 Calico cluster image"
  fi

  if [[ $EUID -ne 0 ]]; then
    fatal "必须以 root 用户运行"
  fi

  log "前提条件检查通过"
}

load_images() {
  log "加载离线 cluster images"

  log "加载 Kubernetes image"
  "$SEALOS" load -i "${ROOT_DIR}/sealos-images/kubernetes-${KUBERNETES_VERSION}-${ARCH}.tar"

  log "加载 Calico image"
  "$SEALOS" load -i "${ROOT_DIR}/sealos-images/calico-${CALICO_VERSION}-${ARCH}.tar"
}

install_kubernetes() {
  local master_ip
  master_ip=$(get_master_ip)
  log "安装单节点 Kubernetes 集群"
  log "Master IP: $master_ip"

  # 清理可能存在的旧集群
  if "$SEALOS" reset -f 2>/dev/null; then
    log "已清理旧集群"
  fi

  rm -f /root/.kube/config 2>/dev/null || true

  log "执行 sealos run 安装集群"
  if ! "$SEALOS" run "docker.io/labring/kubernetes:${KUBERNETES_VERSION}" \
    "docker.io/labring/calico:${CALICO_VERSION}" \
    --masters "$master_ip" --force 2>&1; then
    fatal "Kubernetes 安装失败"
  fi

  export KUBECONFIG=/root/.kube/config

  log "等待集群就绪 (最多等待 10 分钟)"
  for i in $(seq 1 60); do
    if kubectl get nodes >/dev/null 2>&1 && kubectl get nodes | grep -q ' Ready '; then
      log "集群就绪，节点已 Ready"
      break
    fi
    if [[ $i -eq 60 ]]; then
      warn "等待超时，集群可能未完全就绪"
    fi
    sleep 10
  done
}

verify_cluster() {
  log "验证集群状态"

  export KUBECONFIG=/root/.kube/config

  log "节点状态:"
  kubectl get nodes -o wide || true

  log "Pod 状态:"
  kubectl get pods -A || true

  log "集群信息:"
  kubectl cluster-info || true

  local ready_nodes
  ready_nodes=$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready ' || echo 0)
  if [[ "$ready_nodes" -ge 1 ]]; then
    log "集群验证成功: $ready_nodes 个 Ready 节点"
    return 0
  else
    warn "集群验证：未找到 Ready 节点"
    return 1
  fi
}

load_app_images() {
  log "测试应用镜像导入"
  if [[ ! -d "${ROOT_DIR}/images" ]]; then
    log "应用镜像目录不存在，跳过"
    return 0
  fi

  local tar_count
  tar_count="$(find "${ROOT_DIR}/images" -maxdepth 1 -name '*.tar' 2>/dev/null | wc -l)"
  if [[ $tar_count -eq 0 ]]; then
    log "无应用镜像 tar 文件，跳过"
    return 0
  fi

  log "找到 $tar_count 个应用镜像 tar 文件"
  log "导入到 containerd k8s.io namespace..."

  local imported=0 failed=0
  for image_tar in "$ROOT_DIR"/images/${ARCH}/*.tar; do
    [[ -f "$image_tar" ]] || continue
    local fname
    fname=$(basename "$image_tar")

    if ctr --address=/run/containerd/containerd.sock -n k8s.io images import "$image_tar" >/dev/null 2>&1; then
      imported=$((imported + 1))
      log "  [OK] $fname"
    else
      warn "  [FAIL] $fname"
      failed=$((failed + 1))
    fi
  done

  log "应用镜像导入: 成功 $imported, 失败 $failed"

  if [[ $imported -gt 0 ]]; then
    log "已导入的应用镜像:"
    ctr --address=/run/containerd/containerd.sock -n k8s.io images ls \
      | grep -v '^REF\|sha256' | head -20 || true
  fi
}

cleanup_test_cluster() {
  log "清理测试集群"
  export KUBECONFIG=/root/.kube/config

  if "$SEALOS" reset -f 2>/dev/null; then
    log "测试集群已清理"
  fi

  rm -f /root/.kube/config 2>/dev/null || true
}

main() {
  log "========================================"
  log "本地 Kubernetes 集群安装测试"
  log "========================================"
  log "用法: $0 [--cleanup|--full-test|--with-apps]"
  log "  --cleanup    清理测试集群"
  log "  --full-test  完整测试 (安装集群 + 导入应用镜像)"
  log "  --with-apps  安装集群后导入应用镜像"
  log "========================================"

  local test_apps=false

  for arg in "$@"; do
    case "$arg" in
      --cleanup)
        cleanup_test_cluster
        exit 0
        ;;
      --full-test|--with-apps)
        test_apps=true
        ;;
    esac
  done

  check_prerequisites
  load_images
  install_kubernetes
  verify_cluster

  if [[ "$test_apps" == "true" ]]; then
    echo ""
    load_app_images
  fi

  log "========================================"
  log "测试完成"
  if [[ "$test_apps" == "true" ]]; then
    log "已导入应用镜像"
  fi
  log "如需清理集群，执行: $0 --cleanup"
  log "========================================"
}

main "$@"
