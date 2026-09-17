#!/usr/bin/env bash
# =============================================================================
# Rook-Ceph 一键部署脚本（K8s 分布式存储，替代 NFS 的集群级方案）
#
# 用法:
#   ./deploy.sh check      # 前置检查（节点数/磁盘/内核模块，不改动集群）
#   ./deploy.sh install    # 一键安装: operator(Helm) → CephCluster → CephFS → 双 StorageClass
#   ./deploy.sh verify     # 部署后验证: RWO(RBD) + RWX(CephFS) 测试 PVC 读写实测
#   ./deploy.sh status     # 查看 ceph 集群健康与组件状态
#   ./deploy.sh uninstall  # 卸载（见 README"卸载"章节，会清数据，慎用）
#
# 环境变量（可选覆盖默认值）:
#   ROOK_VERSION      Rook chart 版本，默认 1.16.4（升级时先查 charts.rook.io 最新稳定版）
#   CEPH_IMAGE        Ceph 容器镜像，默认 quay.io/ceph/ceph:v19.2.3（多架构含 ARM64）
#   MIRROR            海外镜像拉取代理，默认 docker.m.daocloud.io（直连可设为空 MIRROR=）
#   SWR_REPO          华为云 SWR 仓库前缀（如 swr.cn-east-3.myhuaweicloud.com/xxx），
#                     设置后 operator/ceph 镜像改为从 SWR 拉取（离线/弱网环境）
#   DEVICE_FILTER     OSD 磁盘过滤正则（如 "nvme" 或 "sd[b-d]"），空=使用所有空闲裸盘
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ROOK_VERSION="${ROOK_VERSION:-1.16.4}"
CEPH_IMAGE="${CEPH_IMAGE:-quay.io/ceph/ceph:v19.2.3}"
MIRROR="${MIRROR-docker.m.daocloud.io}"
SWR_REPO="${SWR_REPO:-}"
DEVICE_FILTER="${DEVICE_FILTER:-}"
NS="rook-ceph"
HELM_REPO="https://charts.rook.io/release"

# SWR 镜像源：设置后 CephCluster 与 operator 均改用 SWR 前缀
if [ -n "$SWR_REPO" ]; then
  CEPH_IMAGE="${SWR_REPO}/ceph:${CEPH_IMAGE##*:}"
  OPERATOR_IMAGE="${SWR_REPO}/ceph:${ROOK_VERSION}"
else
  OPERATOR_IMAGE="rook/ceph:v${ROOK_VERSION}"
fi

log()  { echo -e "\033[32m[ceph-deploy]\033[0m $*"; }
warn() { echo -e "\033[33m[ceph-deploy]\033[0m $*"; }
err()  { echo -e "\033[31m[ceph-deploy]\033[0m $*" >&2; }

# 镜像名加 MIRROR 前缀（用于 helm pull / docker pull 阶段；SWR_REPO 已设置时不加）
mirror_img() {
  local img="$1"
  if [ -n "$SWR_REPO" ]; then echo "$img"; return; fi
  if [ -n "$MIRROR" ]; then echo "${MIRROR}/${img}"; else echo "$img"; fi
}

cmd_check() {
  bash "$SCRIPT_DIR/scripts/00-check-prereqs.sh"
}

cmd_install() {
  log "1/6 安装 Rook operator（Helm chart ${ROOK_VERSION}）"
  helm repo add rook-release "$HELM_REPO" >/dev/null 2>&1 || true
  helm repo update rook-release >/dev/null

  local helm_set=(--set image.repository="$(mirror_img "${OPERATOR_IMAGE%:*}")" \
                  --set image.tag="${OPERATOR_IMAGE##*:}")
  helm upgrade --install rook-ceph rook-release/rook-ceph \
    -n "$NS" --create-namespace \
    --version "$ROOK_VERSION" \
    "${helm_set[@]}" \
    --wait --timeout 600s

  log "2/6 等待 operator 就绪"
  kubectl -n "$NS" wait --for=condition=Available deploy/rook-ceph-operator --timeout=300s

  log "3/6 部署 CephCluster（mon×3 + mgr×2 + OSD）"
  # DEVICE_FILTER 通过 sed 注入 cluster CR（与 databases/ 的模板替换约定一致）
  sed "s|__CEPH_IMAGE__|${CEPH_IMAGE}|; s|__DEVICE_FILTER__|${DEVICE_FILTER}|" \
    "$SCRIPT_DIR/manifests/10-cluster.yaml" | kubectl apply -f -

  log "4/6 等待 Ceph 集群 HEALTH_OK（首次拉 OSD 镜像+格式化磁盘，可能 10~20 分钟）"
  local i=0
  until [ "$(kubectl -n "$NS" get cephcluster rook-ceph -o jsonpath='{.status.phase}' 2>/dev/null)" = "Ready" ]; do
    i=$((i+1)); [ $i -gt 120 ] && { err "20 分钟未 Ready，请 ./deploy.sh status 排查"; exit 1; }
    sleep 10
  done

  log "5/6 部署 CephFS（RWX 共享文件系统）与双 StorageClass"
  kubectl apply -f "$SCRIPT_DIR/manifests/15-filesystem.yaml"
  kubectl apply -f "$SCRIPT_DIR/manifests/20-storageclass.yaml"

  log "6/6 完成。执行 ./deploy.sh verify 做读写实测"
  kubectl get sc | grep -E "rook-ceph|NAME"
}

cmd_status() {
  kubectl -n "$NS" get pods -o wide
  kubectl -n "$NS" exec deploy/rook-ceph-tools -- ceph -s 2>/dev/null \
    || warn "toolbox 未就绪，稍后再试（deploy/rook-ceph-tools）"
}

cmd_verify() {
  bash "$SCRIPT_DIR/scripts/verify.sh"
}

cmd_uninstall() {
  err "即将卸载 Rook-Ceph 并清除所有数据！请先迁移/备份所有 PVC。"
  read -rp "确认继续？输入 yes: " a; [ "$a" = "yes" ] || { echo "已取消"; exit 1; }
  # 顺序很重要：先删占用 RBD/RWX 的业务 PVC，再删 SC，否则删除会卡 Terminating
  kubectl delete -f "$SCRIPT_DIR/manifests/20-storageclass.yaml" --ignore-not-found
  kubectl delete -f "$SCRIPT_DIR/manifests/15-filesystem.yaml" --ignore-not-found
  kubectl delete cephcluster rook-ceph -n "$NS" --ignore-not-found
  warn "等待 OSD/mon 全部退出后（kubectl -n $NS get pods 应只剩 operator），再执行以下清理："
  echo "  kubectl delete ns $NS --timeout=600s"
  echo "  kubectl delete crd \$(kubectl get crd | grep ceph.rook.io -oE '^[a-z.]+') --ignore-not-found"
  echo "  # 每台节点: rm -rf /var/lib/rook  （重装必须清，否则 mon 起不来）"
  echo "  # 每台节点: 彻底清盘 dd if=/dev/zero of=/dev/<盘> bs=1M count=100（重装 OSD 必须清）"
}

case "${1:-help}" in
  check)     cmd_check ;;
  install)   cmd_install ;;
  status)    cmd_status ;;
  verify)    cmd_verify ;;
  uninstall) cmd_uninstall ;;
  *) grep '^#   ' "$0" | head -8 ;;
esac
