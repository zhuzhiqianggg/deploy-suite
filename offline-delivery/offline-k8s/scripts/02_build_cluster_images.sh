#!/usr/bin/env bash
# 02_build_cluster_images.sh - 构建自定义 Sealos cluster images
# 当官方预构建镜像不可用时，使用此脚本构建自定义镜像

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="$ROOT_DIR/config"
VERSIONS_LOCK="$CONFIG_DIR/versions.lock"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
fatal() { log "ERROR: $*"; exit 1; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%F %T')" "$*"; }

# 加载版本锁定
# shellcheck disable=SC1090
source "$VERSIONS_LOCK"

# 根据 ARCH 推导 OCI 平台
case "$ARCH" in
  arm64) OCI_PLATFORM="linux/arm64" ;;
  amd64) OCI_PLATFORM="linux/amd64" ;;
  *) fatal "不支持的架构: $ARCH" ;;
esac

SEALOS="${ROOT_DIR}/bin/${ARCH}/sealos"

check_sealos() {
  if [[ ! -x "$SEALOS" ]]; then
    fatal "sealos 未安装，请先执行 01_download_online.sh"
  fi
  "$SEALOS" version || fatal "sealos 版本检查失败"
}

create_kubeadm_config() {
  local cfg="$ROOT_DIR/kubeadm-config.yaml"
  cat > "$cfg" <<EOF
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: ${KUBERNETES_VERSION}
controller:
  extraArgs:
    cloud-provider: ""
networking:
  dnsDomain: cluster.local
  podSubnet: 10.244.0.0/16
  serviceSubnet: 10.96.0.0/12
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
EOF
  log "已创建 kubeadm 配置: $cfg"
}

create_clusterfile() {
  local cf="$ROOT_DIR/Clusterfile"
  cat > "$cf" <<EOF
apiVersion: sealos.cloud/v1beta1
kind: Cluster
metadata:
  name: default
spec:
  hub: docker.io
  kubernetes:
    version: ${KUBERNETES_VERSION}
  images:
    - docker.io/labring/calico:${CALICO_VERSION}
EOF
  log "已创建 Clusterfile: $cf"
}

build_images() {
  log "检查现有 cluster images"

  local kube_tar="${ROOT_DIR}/sealos-images/kubernetes-${KUBERNETES_VERSION}-${ARCH}.tar"
  local calico_tar="${ROOT_DIR}/sealos-images/calico-${CALICO_VERSION}-${ARCH}.tar"

  if [[ -f "$kube_tar" ]]; then
    log "Kubernetes cluster image 已存在: $kube_tar"
  else
    log "Kubernetes cluster image 不存在，需要构建"
    create_kubeadm_config
    create_clusterfile

    log "尝试构建 Kubernetes cluster image"
    if "$SEALOS" build -t "docker.io/labring/kubernetes:${KUBERNETES_VERSION}" \
      -f "$ROOT_DIR/Clusterfile" \
      "$ROOT_DIR" 2>/dev/null; then
      log "成功构建 Kubernetes cluster image"
      "$SEALOS" save -o "$kube_tar" "docker.io/labring/kubernetes:${KUBERNETES_VERSION}"
    else
      log "sealos build 失败，将使用 kubeadm 直接拉取镜像"
    fi
  fi

  if [[ -f "$calico_tar" ]]; then
    log "Calico cluster image 已存在: $calico_tar"
  else
    log "Calico cluster image 不存在，尝试构建"
    if ! "$SEALOS" pull "docker.io/labring/calico:${CALICO_VERSION}" 2>/dev/null; then
      log "无法获取 Calico 镜像"
    else
      "$SEALOS" save -o "$calico_tar" "docker.io/labring/calico:${CALICO_VERSION}"
    fi
  fi
}

verify_images() {
  log "验证 cluster images"
  local images=(
    "${ROOT_DIR}/sealos-images/kubernetes-${KUBERNETES_VERSION}-${ARCH}.tar"
    "${ROOT_DIR}/sealos-images/calico-${CALICO_VERSION}-${ARCH}.tar"
  )

  for img in "${images[@]}"; do
    if [[ -f "$img" ]]; then
      log "  存在: $(basename "$img") ($(du -h "$img" | cut -f1))"
    else
      warn "  缺失: $(basename "$img")"
    fi
  done
}

main() {
  log "========================================"
  log "构建自定义 Cluster Images"
  log "========================================"
  check_sealos
  build_images
  verify_images
  log "完成"
}

main "$@"
