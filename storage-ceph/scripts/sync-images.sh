#!/usr/bin/env bash
# Rook-Ceph ARM64 镜像同步到华为云 SWR（离线/弱网部署用）
# 用法: ./sync-images.sh [all|list]
# SWR 凭据: ../delivery-tools/.swr-credentials 或当前目录 .swr-credentials（格式: SWR_REPO=... SWR_USER=... SWR_PASS=...）
# 注意: csi-* 辅助镜像的版本必须与 Rook chart 内置默认一致，装完后可用
#   kubectl -n rook-ceph describe deploy/rook-ceph-operator | grep image  核对，不符按提示补同步
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIRROR="docker.m.daocloud.io"
ROOK_VERSION="${ROOK_VERSION:-1.16.4}"
CEPH_VERSION="${CEPH_VERSION:-v19.2.3}"
# 名称=海外原始镜像（key 形式罗列，逐行同步）
IMAGES=(
  "rook/ceph:v${ROOK_VERSION}"
  "quay.io/ceph/ceph:${CEPH_VERSION}"
  "quay.io/cephcsi/cephcsi:v3.13.0"
  "registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.12.0"
  "registry.k8s.io/sig-storage/csi-provisioner:v5.1.0"
  "registry.k8s.io/sig-storage/csi-attacher:v4.7.0"
  "registry.k8s.io/sig-storage/csi-resizer:v1.12.0"
  "registry.k8s.io/sig-storage/csi-snapshotter:v8.1.0"
)

CREDS="$SCRIPT_DIR/.swr-credentials"
[ -f "$CREDS" ] || CREDS="$SCRIPT_DIR/../delivery-tools/.swr-credentials"
[ -f "$CREDS" ] || { echo "缺 SWR 凭据文件，参考 delivery-tools/.swr-credentials 格式创建"; exit 1; }
# shellcheck disable=SC1090
source "$CREDS"

echo "登录 SWR: ${SWR_REPO}"
echo "${SWR_PASS}" | docker login "${SWR_REPO##*//}" -u "${SWR_USER}" --password-stdin >/dev/null

for img in "${IMAGES[@]}"; do
  # quay.io/xxx / registry.k8s.io/xxx / docker.io(裸名) 统一转 SWR 短名: <repo前缀>/<去域名路径>
  short="${img#*/}"                       # 去 registry 域名
  short="${short#ceph/}"                  # quay.io/ceph/ceph → ceph
  dst="${SWR_REPO}/${short%%:*}:v$(echo "${short##*:}" | tr -d 'v')"
  echo ">>> ${MIRROR}/${img}  →  ${dst}"
  docker pull --platform linux/arm64 "${MIRROR}/${img}" >/dev/null
  docker tag "${MIRROR}/${img}" "$dst"
  docker push "$dst" >/dev/null && echo "    ✓ 已推送"
done
echo "全部同步完成。部署时: SWR_REPO=${SWR_REPO} ./deploy.sh install"
