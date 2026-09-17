#!/usr/bin/env bash
# 部署后验证：RWO(RBD) 与 RWX(CephFS) 各建测试 PVC，写入/读取/扩容实测，默认通过后清理
# 用法: ./verify.sh [--keep]   --keep 保留测试资源便于排查
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="rook-ceph-verify"
KEEP="${1:-}"

cleanup() { [ "$KEEP" = "--keep" ] || kubectl delete ns "$NS" --ignore-not-found --timeout=120s >/dev/null; }
trap cleanup EXIT

log()  { echo -e "\033[32m[verify]\033[0m $*"; }
fail() { echo -e "\033[31m[verify] 失败:\033[0m $*" >&2; exit 1; }

kubectl create ns "$NS" >/dev/null

# ---------- RWO: RBD ----------
log "创建 RWO 测试 PVC（rook-ceph-block, 1Gi）"
cat <<'EOF' | kubectl apply -f - >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: rwo-test, namespace: rook-ceph-verify }
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: rook-ceph-block
  resources: { requests: { storage: 1Gi } }
EOF
cat <<'EOF' | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: { name: rwo-test, namespace: rook-ceph-verify }
spec:
  restartPolicy: Never
  containers:
  - name: w
    image: docker.m.daocloud.io/library/busybox:latest
    command: ["sh","-c","echo rbd-$(date +%s) > /mnt/stamp && sync && sleep 1 && cat /mnt/stamp"]
    volumeMounts: [{ name: d, mountPath: /mnt }]
  volumes:
  - name: d
    persistentVolumeClaim: { claimName: rwo-test }
EOF
kubectl -n "$NS" wait --for=condition=Ready pod/rwo-test --timeout=300s >/dev/null 2>&1 \
  || fail "RWO 测试 Pod 未 Ready（kubectl -n $NS describe pod rwo-test）"
RBD_STAMP=$(kubectl -n "$NS" logs rwo-test | grep rbd- | tail -1)
[ -n "$RBD_STAMP" ] || fail "RBD 写入未取回时间戳"
log "RWO(RBD) 写读通过: $RBD_STAMP"

# RBD 在线扩容（NFS provisioner 做不到的能力）
log "RWO PVC 在线扩容 1Gi → 2Gi"
kubectl -n "$NS" patch pvc rwo-test -p '{"spec":{"resources":{"requests":{"storage":"2Gi"}}}}' >/dev/null
sleep 10
CAP=$(kubectl -n "$NS" get pvc rwo-test -o jsonpath='{.status.capacity.storage}')
[ "$CAP" = "2Gi" ] || fail "RBD 扩容未生效（当前 $CAP）"
log "RBD 在线扩容通过: 2Gi"

# ---------- RWX: CephFS ----------
log "创建 RWX 测试 PVC（rook-cephfs, 1Gi）双 Pod 共挂载互写"
cat <<'EOF' | kubectl apply -f - >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: rwx-test, namespace: rook-ceph-verify }
spec:
  accessModes: [ReadWriteMany]
  storageClassName: rook-cephfs
  resources: { requests: { storage: 1Gi } }
EOF
for pod in cephfs-a cephfs-b; do
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: { name: ${pod}, namespace: rook-ceph-verify }
spec:
  containers:
  - name: w
    image: docker.m.daocloud.io/library/busybox:latest
    command: ["sh","-c","echo ${pod}-ok > /mnt/\${HOSTNAME}.txt && sleep infinity"]
    volumeMounts: [{ name: d, mountPath: /mnt }]
  volumes:
  - name: d
    persistentVolumeClaim: { claimName: rwx-test }
EOF
done
kubectl -n "$NS" wait --for=condition=Ready pod/cephfs-a pod/cephfs-b --timeout=300s >/dev/null 2>&1 \
  || fail "RWX 测试 Pod 未 Ready（多见 fsName/pool 配置错，kubectl -n rook-ceph get cephfilesystem）"
A=$(kubectl -n "$NS" exec cephfs-a -- cat /mnt/cephfs-b.txt 2>/dev/null)
[ "$A" = "cephfs-b-ok" ] || fail "CephFS 双 Pod 互读失败"
log "RWX(CephFS) 双 Pod 共享读写通过"

echo
echo -e "\033[32m====== 验证全部通过：RWO(RBD) / RWX(CephFS) / 在线扩容 ✓ ======\033[0m"
[ "$KEEP" = "--keep" ] && log "测试资源保留在 ns: $NS"
