#!/usr/bin/env bash
# 前置检查（只读，不改集群）：节点数 / 空闲磁盘 / 内核模块 / 工具链
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="rook-ceph"
FAIL=0

pass() { echo -e "\033[32m[✓]\033[0m $*"; }
fail() { echo -e "\033[31m[✗]\033[0m $*"; FAIL=1; }
warn() { echo -e "\033[33m[!]\033[0m $*"; }

echo "===== 1. Kubernetes 节点 ====="
NODES=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"{print $1}')
N=$(echo "$NODES" | grep -c . || true)
if [ "$N" -ge 3 ]; then pass "Ready 节点数 ${N}（>=3 满足 mon/mgr/OSD HA）"; else
  fail "Ready 节点数 ${N} < 3：Ceph HA 至少 3 节点（单节点部署无 HA 意义，不建议）"; fi
kubectl get nodes -o wide

echo; echo "===== 2. 每节点空闲磁盘（需人工核对输出）====="
warn "useAllDevices=true 会吞掉每节点所有'空闲裸盘'，以下盘会被格式化，务必核对！"
for node in $NODES; do
  echo "--- node: ${node} ---"
  kubectl debug node/"$node" -it --image="${MIRROR:-docker.m.daocloud.io}/library/busybox:latest" -- chroot /host lsblk -d -o NAME,SIZE,TYPE,MOUNTPOINTS 2>/dev/null \
    || warn "  无法探查（kubectl debug 失败），请手动: ssh ${node} lsblk"
done

echo; echo "===== 3. 内核模块（本机示例，各 worker 节点同样执行）====="
for m in rbd libceph ceph; do
  if lsmod | grep -q "^${m} " || modprobe "$m" 2>/dev/null; then pass "内核模块 ${m}"; else
    fail "内核模块 ${m} 缺失（Ubuntu 22.04 自带，若缺失检查内核）"; fi
done

echo; echo "===== 4. 工具链 ====="
for t in kubectl helm; do command -v $t >/dev/null && pass "$t: $($t version --short 2>/dev/null | head -1)" || fail "缺 $t"; done

echo; echo "===== 5. 已有存储共存确认 ====="
kubectl get sc 2>/dev/null || warn "无法列出 SC"
warn "Ceph 与 NFS 可共存：新业务用 rook-ceph-*，存量 NFS PVC 不受影响，迁移见 README"

if [ $FAIL = 1 ]; then echo -e "\n\033[31m检查未通过，解决上述 [✗] 后再 install\033[0m"; exit 1; fi
echo -e "\n\033[32m检查通过。确认磁盘无误后执行: ./deploy.sh install\033[0m"
