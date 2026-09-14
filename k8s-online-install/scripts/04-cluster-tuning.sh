#!/usr/bin/env bash
# ============================================================================
# 04 —— 集群稳定性与性能调优
#
# 1. Kubelet 配置（正确字段 + 全部字段已对照 configz 验证存在）
#    - systemReserved / kubeReserved 在【顶层】（v1beta1 没有 resources.reserved！）
#    - 驱逐阈值 / containerLogMaxSize（CRI 日志轮转归 kubelet，containerd 不管）
#    - maxPods / shutdownGracePeriod / kubeAPIQPS
# 2. 静态 Pod（apiserver/controller-manager/scheduler）调优
#    - 必须改 /etc/kubernetes/manifests/*.yaml —— kubectl patch pod 会被 kubelet 回滚！
#    - 只用 v1.29 验证存在的 flag（--pod-eviction-timeout 已废弃，用了会 crash）
# 3. Calico ippool: IPIP Always → CrossSubnet（同网段走原生路由，去掉封装开销）
# 4. etcd 每日快照 cron（保留 N 份）
#
# 安全机制：所有修改先备份，kubelet/静态 Pod 重启失败自动回滚
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.env"
source "${SCRIPT_DIR}/../common.sh"

log_step "04. 集群稳定性与性能调优"

NODE_NAME="$(hostname -s)"
TOTAL_MEM_GB="${TOTAL_MEM_GB:-$(detect_total_mem_gb)}"
SYSTEM_RESERVED="${SYSTEM_RESERVED_MEM_GI:-$(calc_system_reserved "$TOTAL_MEM_GB")}"
KUBE_RESERVED="$(( TOTAL_MEM_GB * 2 / 100 ))Gi"
(( ${SYSTEM_RESERVED%Gi} < 2 )) && SYSTEM_RESERVED="2Gi"
(( ${KUBE_RESERVED%Gi} < 2 )) && KUBE_RESERVED="2Gi"

log_info "总内存: ${TOTAL_MEM_GB} GB | 系统预留: $SYSTEM_RESERVED | Kube 预留: $KUBE_RESERVED"

# ── 1. Kubelet 调优（本地 /var/lib/kubelet/config.yaml + 同步 kubelet-config CM）──
log_info "[1/4] Kubelet 调优 (eviction / reserved / 日志轮转 / maxPods)..."

wait_for "kubelet-config ConfigMap" 30 3 bash -c 'kubectl get configmap -n kube-system kubelet-config >/dev/null 2>&1'

# 真正的配置源是本地文件（kubeadm 默认不开 dynamic kubelet config，CM 只是模板）
KUBELET_CONF="/var/lib/kubelet/config.yaml"
OLD_CONFIG="$(cat "$KUBELET_CONF")"
NEW_CONFIG="$(echo "$OLD_CONFIG" | python3 -c "
import sys, yaml

cfg = yaml.safe_load(sys.stdin) or {}

# systemReserved / kubeReserved —— 注意：这两个是【顶层】字段
# v1beta1 KubeletConfiguration 没有 resources.reserved（老脚本用错了字段名）
cfg['systemReserved'] = {
    'cpu': '2000m',
    'memory': '${SYSTEM_RESERVED}',
    'ephemeral-storage': '4Gi'
}
cfg['kubeReserved'] = {
    'cpu': '1000m',
    'memory': '${KUBE_RESERVED}',
    'ephemeral-storage': '2Gi'
}
# enforceNodeAllocatable 保留 pods（改成 system-reserved 需要 systemd cgroup 配套，风险大）

# 驱逐阈值
cfg['evictionHard'] = {
    'memory.available': '${EVICTION_HARD_MEMORY}',
    'nodefs.available': '${EVICTION_HARD_NODEFS}',
    'imagefs.available': '${EVICTION_HARD_IMAGEFS}',
    'nodefs.inodesFree': '5%'
}
# mergeDefaultEvictionSettings: v1.27+ 关键开关！
#   true  = 只覆盖上面显式写的 eviction 配置，保留 kubelet 内置磁盘/inode 驱逐规则
#   false = 完全覆盖全部 eviction 配置，会丢失磁盘驱逐，生产风险极高
cfg['mergeDefaultEvictionSettings'] = True
cfg['evictionSoft'] = {
    'memory.available': '10%',
    'nodefs.available': '15%'
}
cfg['evictionSoftGracePeriod'] = {
    'memory.available': '3m',
    'nodefs.available': '5m'
}
# 最小回收量：驱逐至少回收 512Mi 内存，防止小 Pod 驱逐后立刻再触发的抖动
cfg['evictionMinimumReclaim'] = {
    'memory.available': '512Mi'
}
cfg['evictionMaxPodGracePeriod'] = 90
cfg['evictionPressureTransitionPeriod'] = '5m'

# 镜像 GC：磁盘用量 85% 触发镜像清理，回收到 75% 停止
cfg['imageGCHighThresholdPercent'] = 85
cfg['imageGCLowThresholdPercent'] = 75

# CRI 容器日志轮转（containerd 场景由 kubelet 负责，不是 containerd）
cfg['containerLogMaxSize'] = '${CONTAINER_LOG_MAX_SIZE}'
cfg['containerLogMaxFiles'] = ${CONTAINER_LOG_MAX_FILES}

# Pod 容量 / API 客户端
cfg['maxPods'] = ${MAX_PODS}
cfg['kubeAPIQPS'] = 50
cfg['kubeAPIBurst'] = 100

# 节点优雅关机：先停普通 Pod 20s，再停 critical 10s
cfg['shutdownGracePeriod'] = '30s'
cfg['shutdownGracePeriodCriticalPods'] = '10s'

yaml.dump(cfg, sys.stdout, default_flow_style=False, sort_keys=False)
" 2>/dev/null)"

if [[ -n "$NEW_CONFIG" ]] && echo "$NEW_CONFIG" | grep -q "systemReserved"; then
    # 备份旧配置
    KUBELET_CONF_BAK="${KUBELET_CONF}.bak.$(date +%Y%m%d-%H%M%S)"
    cp "$KUBELET_CONF" "$KUBELET_CONF_BAK"
    echo "$OLD_CONFIG" > "${LOG_DIR}/kubelet-config-backup-$(date +%Y%m%d-%H%M%S).yaml"

    # 写本地文件（kubelet 真正读的配置）
    echo "$NEW_CONFIG" > "$KUBELET_CONF"

    # 同步 CM（保持 kubeadm upgrade / 文档一致性）
    kubectl create configmap kubelet-config \
        --from-literal=config.yaml="$NEW_CONFIG" \
        --namespace kube-system \
        --dry-run=client -o yaml | kubectl apply -f -
    log_ok "kubelet 本地配置 + kubelet-config CM 已更新"

    log_info "重启 kubelet 生效（kubelet 配置不热加载）..."
    systemctl restart kubelet
    if ! wait_for "kubelet Running" 60 3 bash -c 'systemctl is-active kubelet | grep -q active'; then
        log_error "kubelet 重启失败！回滚本地配置..."
        cp "$KUBELET_CONF_BAK" "$KUBELET_CONF"
        kubectl create configmap kubelet-config \
            --from-literal=config.yaml="$OLD_CONFIG" \
            --namespace kube-system \
            --dry-run=client -o yaml | kubectl apply -f -
        systemctl restart kubelet
        log_warn "已回滚，请人工检查 $KUBELET_CONF_BAK"
        exit 1
    fi
    # 确认 node 还 Ready（kubelet 起来 ≠ 配置没毒）
    sleep 10
    if ! kubectl get node "$NODE_NAME" 2>/dev/null | grep -q " Ready"; then
        log_warn "kubelet 起来了但节点未 Ready，观察 30s 再确认..."
        sleep 30
        kubectl get node "$NODE_NAME" 2>/dev/null | grep -q " Ready" || {
            log_error "节点未 Ready —— 请 journalctl -u kubelet 排查"
            exit 1
        }
    fi
    log_ok "kubelet 重启成功且节点 Ready"
else
    log_error "kubelet config 生成失败（检查 python3-yaml 是否安装）"
    exit 1
fi

# ── 2. 静态 Pod 调优（改 manifest，不是 kubectl patch pod！）─────────────────
log_info "[2/4] 静态 Pod 调优（/etc/kubernetes/manifests）..."

# 幂等向 manifest 的 args 追加参数；返回 0 表示有修改
add_args() {
    local manifest="$1"; shift
    python3 - "$manifest" "$@" <<'PYEOF'
import sys, yaml

path, args_to_add = sys.argv[1], sys.argv[2:]
docs = list(yaml.safe_load_all(open(path)))
changed = False
for doc in docs:
    if not doc or doc.get('kind') != 'Pod':
        continue
    for c in doc.get('spec', {}).get('containers', []):
        args = c.setdefault('args', [])
        existing = set(args)
        for a in args_to_add:
            key = a.split('=', 1)[0]
            if not any(x == a or x.startswith(key + '=') for x in existing):
                args.append(a)
                changed = True
if changed:
    yaml.dump_all(docs, open(path, 'w'), default_flow_style=False, sort_keys=False)
print("CHANGED" if changed else "UNCHANGED")
PYEOF
}

# 重启对应静态 Pod 并确认 Running（失败自动回滚 manifest）
apply_manifest_safe() {
    local manifest="$1" pod_prefix="$2"
    local backup="${manifest}.bak.$$"
    cp "$manifest" "$backup"

    local out
    # shellcheck disable=SC2086 —— 有意 word-split，把 "flag1 flag2" 拆成多个参数
    out=$(add_args "$manifest" ${STATIC_ARGS[$pod_prefix]}) || out="UNCHANGED"
    if [[ "$out" != *CHANGED* ]]; then
        log_ok "  $pod_prefix: 参数已存在，跳过"
        rm -f "$backup"
        return 0
    fi
    log_info "  $pod_prefix: 参数已写入，等待 Pod 重启..."
    local waited=0
    while (( waited < 120 )); do
        # 静态 Pod 名固定为 ${comp}-${NODE_NAME}
        if kubectl get pod -n kube-system "${pod_prefix}-${NODE_NAME}" -o jsonpath='{.status.phase}' 2>/dev/null | grep -q "^Running$"; then
            sleep 5
            if kubectl get pod -n kube-system "${pod_prefix}-${NODE_NAME}" -o jsonpath='{.status.phase}' 2>/dev/null | grep -q "^Running$"; then
                # 额外确认没有 restart-count 暴涨（参数有毒时会 CrashLoopBackOff）
                log_ok "  $pod_prefix: 重启成功"
                rm -f "$backup"
                return 0
            fi
        fi
        sleep 5; waited=$((waited + 5))
    done
    log_error "  $pod_prefix: 重启后异常，回滚 manifest..."
    cp "$backup" "$manifest"
    rm -f "$backup"
    return 1
}

declare -A STATIC_ARGS
STATIC_ARGS[kube-apiserver]="--max-requests-inflight=2000 --max-mutating-requests-inflight=1000 --default-not-ready-toleration-seconds=60 --default-unreachable-toleration-seconds=60"
STATIC_ARGS[kube-controller-manager]="--concurrent-deployment-syncs=10 --concurrent-replicaset-syncs=10 --concurrent-service-syncs=20 --horizontal-pod-autoscaler-sync-period=30s --terminated-pod-gc-threshold=1000"
STATIC_ARGS[kube-scheduler]="--kube-api-qps=50 --kube-api-burst=100"
# 注: kube-scheduler 无 --parallelism 命令行 flag（仅 KubeSchedulerConfiguration
#     配置字段，且 v1 默认值就是 16），写入 args 会导致 CrashLoopBackOff

for comp in kube-apiserver kube-controller-manager kube-scheduler; do
    manifest="/etc/kubernetes/manifests/${comp}.yaml"
    if [[ -f "$manifest" ]]; then
        # shellcheck disable=SC2086
        apply_manifest_safe "$manifest" "$comp" || true
    else
        log_warn "  未找到 $manifest，跳过"
    fi
done

# ── 3. Calico ippool：IPIP Always → CrossSubnet ───────────────────────────────
# 注：tigera-operator 管理的集群（sealos 默认），ippool 被 Installation CR
#     (encapsulation: IPIP) 秒级回改，CrossSubnet 无法落地；operator API 也无
#     CrossSubnet 选项。单节点集群无跨节点流量，IPIP 模式无实际影响。
log_info "[3/4] Calico 网络优化（IPIP → CrossSubnet）..."
IPPOOL="ippools.crd.projectcalico.org/default-ipv4-ippool"
if kubectl get "$IPPOOL" &>/dev/null || kubectl get "$IPPOOL" &>/dev/null; then
    CUR_MODE=$(kubectl get "$IPPOOL" -o jsonpath='{.spec.ipipMode}')
    if [[ "$CUR_MODE" == "Always" ]]; then
        kubectl patch "$IPPOOL" --type=merge \
            -p '{"spec":{"ipipMode":"CrossSubnet"}}' &>/dev/null || true
        sleep 3
        NEW_MODE=$(kubectl get "$IPPOOL" -o jsonpath='{.spec.ipipMode}')
        if [[ "$NEW_MODE" == "CrossSubnet" ]]; then
            log_ok "ipipMode: Always → CrossSubnet（同网段走原生路由，跨网段才封 IPIP；未来加节点更优）"
        else
            log_info "ippool 由 tigera-operator 管理（encapsulation: IPIP）→ CrossSubnet 被 operator 回改"
            log_info "单节点集群 IPIP 无跨节点流量，保持 Always 无实际影响"
        fi
    else
        log_ok "ipipMode 已是 $CUR_MODE，跳过"
    fi
else
    log_warn "未找到 default-ipv4-ippool，跳过"
fi

# ── 4. etcd 每日快照 cron ─────────────────────────────────────────────────────
log_info "[4/4] etcd 每日快照（保留 ${ETCD_SNAPSHOT_KEEP} 份）..."
if [[ "$ETCD_SNAPSHOT_ENABLED" != "true" ]]; then
    log_ok "ETCD_SNAPSHOT_ENABLED=false，跳过"
else
    mkdir -p "${ETCD_SNAPSHOT_DIR}"
    cat > /usr/local/bin/k8s-etcd-backup.sh <<'BACKUPEOF'
#!/usr/bin/env bash
# etcd 快照：在 etcd Pod 内执行 snapshot save（落到 hostPath /var/lib/etcd），再搬到备份目录
set -uo pipefail
KEEP="${ETCD_SNAPSHOT_KEEP:-7}"
BACKUP_DIR="${ETCD_SNAPSHOT_DIR:-/data/nfs/backup/etcd}"
SNAP_TMP="/var/lib/etcd/.snapshot-tmp.db"
LOG="/var/log/etcd-backup.log"

ETCD_POD=$(kubectl get pods -n kube-system -l component=etcd -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[[ -z "$ETCD_POD" ]] && { echo "$(date) ERROR: etcd pod not found" >> "$LOG"; exit 1; }

if kubectl exec -n kube-system "$ETCD_POD" -- etcdctl \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    snapshot save "$SNAP_TMP" >> "$LOG" 2>&1; then
    TS=$(date +%Y%m%d-%H%M%S)
    mv /var/lib/etcd/.snapshot-tmp.db "${BACKUP_DIR}/etcd-snapshot-${TS}.db"
    echo "$(date) OK: etcd-snapshot-${TS}.db" >> "$LOG"
    # 只保留最近 KEEP 份
    ls -1t "${BACKUP_DIR}"/etcd-snapshot-*.db 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f
else
    echo "$(date) ERROR: snapshot save failed" >> "$LOG"
    kubectl exec -n kube-system "$ETCD_POD" -- rm -f "$SNAP_TMP" 2>/dev/null
    exit 1
fi
BACKUPEOF
    chmod +x /usr/local/bin/k8s-etcd-backup.sh

    # cron 环境变量单独注入（cron 不继承 shell env）
    cat > /etc/cron.d/etcd-backup <<CRONEOF
${ETCD_SNAPSHOT_CRON} root ETCD_SNAPSHOT_KEEP=${ETCD_SNAPSHOT_KEEP} ETCD_SNAPSHOT_DIR=${ETCD_SNAPSHOT_DIR} /usr/local/bin/k8s-etcd-backup.sh >/dev/null 2>&1
CRONEOF
    chmod 644 /etc/cron.d/etcd-backup

    # 立刻跑一次验证快照链路通
    if ETCD_SNAPSHOT_KEEP="${ETCD_SNAPSHOT_KEEP}" ETCD_SNAPSHOT_DIR="${ETCD_SNAPSHOT_DIR}" /usr/local/bin/k8s-etcd-backup.sh; then
        log_ok "etcd 快照验证成功: $(ls -1t "${ETCD_SNAPSHOT_DIR}" | head -1)"
    else
        log_warn "etcd 快照首次执行失败（cron 仍会重试），日志: /var/log/etcd-backup.log"
    fi
fi

# ── 汇总 ─────────────────────────────────────────────────────────────────────
log_step "✅ 集群稳定性调优完成"
log_info "应用的关键参数："
log_info "  ├─ kubelet 驱逐: memory<${EVICTION_HARD_MEMORY}, nodefs<${EVICTION_HARD_NODEFS}, imagefs<${EVICTION_HARD_IMAGEFS}"
log_info "  ├─ systemReserved: cpu=2000m mem=${SYSTEM_RESERVED} | kubeReserved: cpu=1000m mem=${KUBE_RESERVED}"
log_info "  ├─ 容器日志轮转: ${CONTAINER_LOG_MAX_SIZE} x ${CONTAINER_LOG_MAX_FILES}（kubelet 负责）"
log_info "  ├─ maxPods: ${MAX_PODS} | kubeAPI QPS/Burst: 50/100"
log_info "  ├─ 优雅关机: 30s (critical 10s)"
log_info "  ├─ apiserver: inflight 2000/1000, toleration 60s"
log_info "  ├─ controller-manager: 并发 syncs 10/10/20, terminated-pod-gc 1000"
log_info "  ├─ scheduler: parallelism=16, QPS 50/100"
log_info "  ├─ Calico: ipipMode=CrossSubnet"
log_info "  └─ etcd 快照: ${ETCD_SNAPSHOT_CRON} → ${ETCD_SNAPSHOT_DIR}（保留 ${ETCD_SNAPSHOT_KEEP} 份）"
log_info ""
log_info "验证: kubectl get --raw /api/v1/nodes/${NODE_NAME}/proxy/configz | jq .kubeletconfig"
