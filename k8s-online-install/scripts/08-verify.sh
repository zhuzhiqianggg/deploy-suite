#!/usr/bin/env bash
# ============================================================================
# 07 —— 集群最终验证 & 诊断
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.env"
source "${SCRIPT_DIR}/../common.sh"

log_step "08. 集群验证 & 诊断"

ALL_OK=true
check() {
    local desc="$1"; shift
    if "$@"; then
        log_ok "✅ $desc"; return 0
    else
        log_error "❌ $desc"; ALL_OK=false; return 1
    fi
}

# ── 基本连通性 ───────────────────────────────────────────────────────────────
check "kubectl 连通"        kubectl cluster-info &>/dev/null
check "节点 Ready"          bash -c "kubectl get nodes --no-headers 2>/dev/null | grep -q 'Ready'"

# ── 控制平面 ──────────────────────────────────────────────────────────────────
log_info "控制平面 Pod:"
kubectl get pods -n kube-system -o wide

for pod in etcd kube-apiserver kube-controller-manager kube-scheduler; do
    check "Pod Running: $pod" bash -c "kubectl get pods -n kube-system --no-headers 2>/dev/null | grep -q \"^${pod}\""
done
# kubelet 是宿主机 systemd 服务，不是 Pod
check "kubelet 服务 active" bash -c "systemctl is-active kubelet 2>/dev/null | grep -q active"

# ── CNI ───────────────────────────────────────────────────────────────────────
log_info "Calico Pod:"
kubectl get pods -n calico-system 2>/dev/null || true

# kube-proxy 模式（ipvs 性能优于 iptables）；kubeadm v1.29 CM 键为 config.conf
PROXY_MODE=$(kubectl get cm -n kube-system kube-proxy -o jsonpath='{.data.config\.conf}' 2>/dev/null | grep -m1 -A1 "^mode:" | awk '{print $2}' | head -1) || true
PROXY_MODE=${PROXY_MODE:-$(kubectl get cm -n kube-system kube-proxy -o jsonpath='{.data.config\.yaml}' 2>/dev/null | grep -m1 -A1 "^mode:" | awk '{print $2}' | head -1) || true}
if [[ "$PROXY_MODE" == "ipvs" ]]; then
    log_ok "✅ kube-proxy 模式: ipvs"
else
    log_warn "⚠️ kube-proxy 模式: ${PROXY_MODE:-unknown}（推荐 ipvs）"
fi

# Calico ippool 模式
IPIP_MODE=$(kubectl get ippool -o jsonpath='{.items[0].spec.ipipMode}' 2>/dev/null || echo "unknown")
log_info "Calico ipipMode: ${IPIP_MODE}"

# ── DNS ───────────────────────────────────────────────────────────────────────
check "CoreDNS Running" bash -c "kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null | grep -q Running"

# DNS 解析实测：宿主机直接查 CoreDNS ClusterIP（kube-proxy IPVS 下宿主机可达 ClusterIP）
log_info "DNS 解析测试（dig @10.96.0.10）..."
CLUSTER_DNS=$(kubectl get svc -n kube-system kube-dns -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "10.96.0.10")
if command -v dig &>/dev/null && dig +short +time=3 +tries=1 "kubernetes.default.svc.cluster.local" "@${CLUSTER_DNS}" | grep -qE "^10\.|^100\."; then
    log_ok "✅ DNS 解析正常 ($(dig +short "kubernetes.default.svc.cluster.local" "@${CLUSTER_DNS}" | head -1))"
else
    if ! command -v dig &>/dev/null; then
        log_warn "⚠️ 无 dig 命令（apt install dnsutils），改用 CoreDNS Running 作为判断依据"
    else
        log_warn "⚠️ DNS 解析失败 —— 检查 CoreDNS: kubectl logs -n kube-system -l k8s-app=kube-dns"
    fi
fi

# ── 存储 ──────────────────────────────────────────────────────────────────────
log_info "StorageClass:"
kubectl get sc
DEFAULT_COUNT=$(kubectl get sc -o jsonpath='{range .items[*]}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}{end}' 2>/dev/null | grep -c "true" || true)
if [[ "$DEFAULT_COUNT" == "1" ]]; then
    log_ok "✅ 默认 StorageClass 唯一"
else
    log_warn "⚠️ 默认 StorageClass 数量=${DEFAULT_COUNT}（应为 1）—— 重跑 03-nfs-storage.sh 修复"
fi

# NFS server 健康
if systemctl is-active --quiet nfs-kernel-server; then
    NFSD_THREADS_ACTUAL=$(cat /proc/fs/nfsd/threads 2>/dev/null || echo "?")
    log_ok "✅ NFS server 运行中 (nfsd threads=${NFSD_THREADS_ACTUAL})"
else
    log_error "❌ NFS server 未运行"
    ALL_OK=false
fi

# ── kubelet 调优是否生效 ──────────────────────────────────────────────────────
log_info "kubelet 配置核验（configz）..."
CONFIGZ=$(kubectl get --raw "/api/v1/nodes/$(hostname -s)/proxy/configz" 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin)['kubeletconfig']; print(d.get('maxPods','?'), d.get('containerLogMaxSize','?'), (d.get('systemReserved') or {}).get('memory','未设置'))" 2>/dev/null || echo "")
if [[ -n "$CONFIGZ" ]]; then
    log_ok "✅ kubelet: maxPods/日志轮转/systemReserved.mem = $CONFIGZ"
    if echo "$CONFIGZ" | grep -q "未设置"; then
        log_warn "⚠️ systemReserved 未生效 —— 重跑 04-cluster-tuning.sh"
    fi
else
    log_warn "⚠️ 无法读取 configz（kubelet 未就绪或权限问题）"
fi

# ── ingress-nginx（hostNetwork 80/443）────────────────────────────────────────
log_info "ingress-nginx:"
if kubectl get ns ingress-nginx >/dev/null 2>&1; then
    if kubectl -n ingress-nginx get deployment ingress-nginx-controller -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null | grep -q True; then
        log_ok "✅ ingress-nginx controller 运行中 (hostNetwork)"
        for port in 80 443; do
            if ss -tlnp 2>/dev/null | grep -qE ":${port}\s"; then
                log_ok "✅ 宿主机端口 ${port} 监听正常"
            else
                log_warn "⚠️ 宿主机端口 ${port} 未监听"
            fi
        done
        kubectl get ingressclass nginx >/dev/null 2>&1 \
            && log_ok "✅ IngressClass: nginx" \
            || log_warn "⚠️ IngressClass nginx 不存在"
    else
        log_warn "⚠️ ingress-nginx 未就绪 —— 重跑 06-ingress-nginx.sh 或查看: kubectl get pods -n ingress-nginx"
    fi
else
    log_warn "⚠️ ingress-nginx 未部署 —— 重跑 06-ingress-nginx.sh"
fi

# ── Kuboard（NodePort 30080）─────────────────────────────────────────────────
log_info "Kuboard:"
if kubectl get ns kuboard >/dev/null 2>&1; then
    if kubectl -n kuboard get deployment kuboard-v4 -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null | grep -q True; then
        log_ok "✅ Kuboard v4 运行中"
        kubectl -n kuboard get svc kuboard-v4 -o jsonpath='{.spec.ports[?(@.nodePort==30080)].nodePort}' 2>/dev/null | grep -q 30080 \
            && log_ok "✅ NodePort 30080 已暴露 → http://${NODE_IP}:30080" \
            || log_warn "⚠️ NodePort 30080 未配置"
    else
        log_warn "⚠️ Kuboard 未就绪（镜像可能未注入: images-manager.sh load2k8s kuboard）"
    fi
else
    log_warn "⚠️ Kuboard 未部署 —— 重跑 05-kuboard.sh"
fi

# ── 补全 & metrics-server ─────────────────────────────────────────────────────
if [[ -f /etc/bash_completion.d/kubectl ]] && [[ -f /etc/bash_completion.d/helm ]]; then
    log_ok "✅ 命令补全文件就绪 (kubectl/helm)"
else
    log_warn "⚠️ 补全文件缺失 —— 重跑 09-usability.sh"
fi

if kubectl top nodes &>/dev/null; then
    log_ok "✅ metrics-server 可用 (kubectl top)"
    kubectl top nodes || true
else
    log_warn "⚠️ kubectl top 不可用（metrics-server 未装或采集预热中）"
fi

# ── etcd 快照 ─────────────────────────────────────────────────────────────────
if [[ -f /etc/cron.d/etcd-backup ]]; then
    LATEST_SNAP=$(ls -1t "${ETCD_SNAPSHOT_DIR}"/etcd-snapshot-*.db 2>/dev/null | head -1 || echo "")
    if [[ -n "$LATEST_SNAP" ]]; then
        log_ok "✅ etcd 快照: $(basename "$LATEST_SNAP") ($(du -h "$LATEST_SNAP" | awk '{print $1}'))"
    else
        log_warn "⚠️ 尚无快照文件 —— 首次 cron 触发后查看 /var/log/etcd-backup.log"
    fi
fi

# ── sealos 状态 ──────────────────────────────────────────────────────────────
log_info "sealos status:"
sealos status 2>/dev/null | head -30 || true

# ── 证书有效期 ────────────────────────────────────────────────────────────────
log_info "证书有效期:"
kubeadm certs check-expiration 2>/dev/null | head -15 || true

# ── 资源使用 ──────────────────────────────────────────────────────────────────
log_info "系统资源:"
echo "  内存: $(free -h | awk '/Mem:/{print $3"/"$2}')"
echo "  Swap: $(free -h | awk '/Swap:/{print $2}')"
echo "  磁盘 /: $(df -h / | awk 'NR==2{print $3"/"$2}')"
echo "  磁盘 /data: $(df -h /data | awk 'NR==2{print $3"/"$2}')"

# ── 异常 Pod 扫描 ─────────────────────────────────────────────────────────────
# 列(带 -A 含命名空间): 1=NAMESPACE 2=NAME 3=READY 4=STATUS 5=RESTARTS 6=AGE
BAD_PODS=$(kubectl get pods -A --no-headers 2>/dev/null | awk '$4 != "Running" && $4 != "Completed"' || true)
if [[ -n "$BAD_PODS" ]]; then
    log_warn "⚠️ 异常状态 Pod:"
    echo "$BAD_PODS"
else
    log_ok "✅ 全集群无异常状态 Pod"
fi

# ── 汇总 ──────────────────────────────────────────────────────────────────────
log_step "诊断汇总"
if [[ "$ALL_OK" == true ]]; then
    log_ok "🎉 集群健康！"
else
    log_warn "⚠️ 有组件异常，请检查上面的 ❌ 项"
fi

echo ""
log_info "常用命令:"
echo "  kubectl get nodes          # 节点"
echo "  kubectl get pods -A        # 所有 Pod (别名: kgpa)"
echo "  kubectl get svc -A         # 服务"
echo "  kubectl describe pod <n>   # Pod 详情 (别名: kdesc)"
echo "  kubectl logs -f <pod>      # 日志 (别名: kl)"
echo "  kubectl top nodes          # 资源使用率 (metrics-server)"
echo "  sealos status              # sealos 集群状态"
echo "  crictl ps                  # containerd 容器"
echo "  sudo journalctl -u kubelet -f"
echo "  /usr/local/bin/k8s-etcd-backup.sh   # 手动触发 etcd 快照"
