#!/usr/bin/env bash
# ============================================================================
# 10 —— Prometheus 监控套件（kube-prometheus-stack 90.0.0，自部署，不用 Kuboard 内置）
#
# 为什么自部署：Kuboard 内置监控套件配置会被自动恢复（改了也白改），故独立部署
# 官方 kube-prometheus-stack Helm chart，配置完全可控。
#
# 组件与版本（chart 90.0.0，全部 arm64 已验证，见 helm-values/prometheus-stack-images.txt）：
#   - Prometheus Operator v0.93.1 + Prometheus v3.14.0（TSDB 本地盘 local-path，NFS 不适合 TSDB 小 IO）
#   - Alertmanager v0.34.0（NFS 持久化）
#   - Grafana 13.2.1（NFS 持久化，NodePort 30300）
#   - node-exporter v1.12.1（DaemonSet）+ kube-state-metrics v2.20.0
#
# 镜像来源：用户经 images-manager.sh 通道自行同步（sync → SWR → load2k8s 注入官方名）
#           镜像清单: helm-values/prometheus-stack-images.txt
#
# Chart 来源：优先离线 charts/kube-prometheus-stack-90.0.0.tgz（已打包），
#            缺失时自动 helm repo 拉取兜底
#
# 访问（单节点 NodePort 仅绑节点 IP 173.23.1.2，用节点 IP 访问，勿用 127.0.0.1）：
#   - Grafana:      http://<节点IP>:30300  （admin / 密码见 helm-values/grafana-admin-password.txt）
#   - Prometheus:   http://<节点IP>:30900
#   - Alertmanager: http://<节点IP>:30903
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.env"
source "${SCRIPT_DIR}/../common.sh"

RELEASE="kps"
NAMESPACE="${PROMETHEUS_NAMESPACE}"
CHART_VERSION="${PROMETHEUS_STACK_CHART_VERSION}"
KPS_CERTGEN_IMAGE="${KPS_CERTGEN_IMAGE:-registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.5.1}"
CHARTS_DIR="${SCRIPT_DIR}/../charts"
CHART_TGZ="${CHARTS_DIR}/kube-prometheus-stack-${CHART_VERSION}.tgz"
VALUES_FILE="${SCRIPT_DIR}/../helm-values/prometheus-stack-values.yaml"
PASSWORD_FILE="${SCRIPT_DIR}/../helm-values/grafana-admin-password.txt"

log_step "10. Prometheus 监控套件（kube-prometheus-stack ${CHART_VERSION}）"

check_root

# ── 1. 检查本地镜像（缺失不阻塞，等用户 images-manager.sh 通道注入）──────────
log_info "[1/8] 检查本地镜像（monitoring 套件 9 个）..."
STACK_IMAGES=(
    "quay.io/prometheus-operator/prometheus-operator:v0.93.1"
    "quay.io/prometheus-operator/prometheus-config-reloader:v0.93.1"
    "quay.io/prometheus/prometheus:v3.14.0-distroless"
    "quay.io/prometheus/alertmanager:v0.34.0"
    "quay.io/prometheus/node-exporter:v1.12.1-distroless"
    "quay.io/kiwigrid/k8s-sidecar:2.11.2"
    "registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.20.0"
    "docker.io/grafana/grafana:13.2.1-distroless"
    # certgen 是集群级公共镜像（images-manager.sh「K8s 基础组件」分组维护，
    # 与 06 ingress-nginx admission 共用），这里只是前置检查 kps 是否可用
    "registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.5.1"
)
missing=0
for img in "${STACK_IMAGES[@]}"; do
    if sudo ctr -n k8s.io images ls -q 2>/dev/null | grep -q "^${img}$"; then
        log_ok "  本地已有: ${img}"
    else
        log_warn "  本地缺失: ${img}"
        missing=$((missing + 1))
    fi
done
if (( missing > 0 )); then
    log_warn "  ${missing} 个镜像缺失 —— 请先走 images-manager.sh 同步注入（清单: helm-values/prometheus-stack-images.txt）"
    log_warn "  继续部署，缺失镜像由 kubelet 现场拉取（外网不通时会 Pending）"
fi
# webhooks 开启时 certgen 是 pre-install 钩子，缺镜像会卡死 install（不能像其它镜像那样现场拉）
if [[ "${PROMETHEUS_ADMISSION_WEBHOOKS}" == "true" ]] && \
   ! sudo ctr -n k8s.io images ls -q 2>/dev/null | grep -q "^${KPS_CERTGEN_IMAGE}$"; then
    log_error "PROMETHEUS_ADMISSION_WEBHOOKS=true 但 certgen 镜像未注入:"
    log_error "  ${KPS_CERTGEN_IMAGE}（ingress-nginx 官方版，参数/证书密钥名与 kps 期望全兼容）"
    log_error "先经 images-manager.sh 通道（sync → SWR → load2k8s 官方名）注入，或把 config.env 该项改回 false"
    exit 1
fi

# ── 2. Grafana admin 密码（幂等：已有密码文件则复用）────────────────────────
log_info "[2/8] 准备 Grafana 管理员凭据..."
if [[ -n "${GRAFANA_ADMIN_PASSWORD}" ]]; then
    GRAFANA_PASSWORD="${GRAFANA_ADMIN_PASSWORD}"
    log_ok "  使用 config.env 显式配置的密码"
elif [[ -f "${PASSWORD_FILE}" ]]; then
    GRAFANA_PASSWORD="$(head -1 "${PASSWORD_FILE}" | tr -d '[:space:]')"
    log_ok "  复用已保存密码: ${PASSWORD_FILE}"
else
    # 用 python3 secrets 生成（tr|head 读 /dev/urandom 在 set -o pipefail 下会 SIGPIPE）
    GRAFANA_PASSWORD="$(python3 -c 'import secrets,string;print("".join(secrets.choice(string.ascii_letters+string.digits) for _ in range(20)))')"
    printf '%s\n' "${GRAFANA_PASSWORD}" > "${PASSWORD_FILE}"
    chmod 600 "${PASSWORD_FILE}"
    log_ok "  已生成 20 位随机密码 → ${PASSWORD_FILE}"
fi

# admission webhook 由 config.env PROMETHEUS_ADMISSION_WEBHOOKS 控制（官方 chart 默认开）；
# certgen 用 ingress-nginx 官方镜像（chart 默认的 ghcr.io jkroepke fork 换掉）：
# v1.5.1 实测 create/patch 参数与默认证书密钥名 cert/key 全兼容（ghcr 无加速通道且不必要）
if [[ "${PROMETHEUS_ADMISSION_WEBHOOKS}" == "true" ]]; then
    ADMISSION_BLOCK="prometheusOperator:
  admissionWebhooks:
    enabled: true
    patch:
      image:
        registry: registry.k8s.io
        repository: ingress-nginx/kube-webhook-certgen
        tag: ${KPS_CERTGEN_IMAGE##*:}"
else
    # 关闭时 tls.enabled 必须同设 false：cert 卷挂载由 tls.enabled 控制（默认 true），
    # webhooks 关后 Secret 不创建但卷还在 → FailedMount 卡死（详见文档坑 22）
    ADMISSION_BLOCK='prometheusOperator:
  admissionWebhooks:
    enabled: false
  tls:
    enabled: false'
fi

# ── 3. 生成 Helm values（写入 helm-values/ 便于版本控制）────────────────────
log_info "[3/8] 生成 Helm values: ${VALUES_FILE}"
cat > "${VALUES_FILE}" <<EOF
# ============================================================================
# kube-prometheus-stack values —— 由 10-prometheus-stack.sh 从 config.env 生成
# release: ${RELEASE} / chart: kube-prometheus-stack ${CHART_VERSION} / namespace: ${NAMESPACE}
# ============================================================================
# 用户后续自己部署 ServiceMonitor/PodMonitor 时也能被纳管（默认只认本 release 的）
prometheus:
  service:
    type: NodePort
    nodePort: ${PROMETHEUS_NODEPORT}
  prometheusSpec:
    retention: ${PROMETHEUS_RETENTION}
    retentionSize: ${PROMETHEUS_RETENTION_SIZE}
    scrapeInterval: 30s
    evaluationInterval: 30s
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    ruleSelectorNilUsesHelmValues: false
    probeSelectorNilUsesHelmValues: false
    scrapeConfigSelectorNilUsesHelmValues: false
    resources:
      requests:
        cpu: "${PROMETHEUS_CPU_REQ}"
        memory: "${PROMETHEUS_MEM_REQ}"
      limits:
        cpu: "${PROMETHEUS_CPU_LIM}"
        memory: "${PROMETHEUS_MEM_LIM}"
    # local-path 底层是 hostPath：不响应 fsGroup，且 volumeMount 带 subPath（prometheus-db/），
    # 非 root 运行必然 permission denied（queries.active）→ 以 root 运行（单节点 lab 权衡）
    securityContext:
      runAsUser: 0
      runAsGroup: 0
      runAsNonRoot: false
      fsGroup: 0
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: ${PROMETHEUS_STORAGE_CLASS}
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: ${PROMETHEUS_STORAGE_SIZE}

alertmanager:
  service:
    type: NodePort
    nodePort: ${ALERTMANAGER_NODEPORT}
  alertmanagerSpec:
    replicas: 1
    resources:
      requests:
        cpu: "100m"
        memory: "256Mi"
      limits:
        cpu: "1"
        memory: "1Gi"
    storage:
      volumeClaimTemplate:
        spec:
          storageClassName: ${ALERTMANAGER_STORAGE_CLASS}
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: ${ALERTMANAGER_STORAGE_SIZE}

grafana:
  service:
    type: NodePort
    nodePort: ${GRAFANA_NODEPORT}
  adminUser: "${GRAFANA_ADMIN_USER}"
  adminPassword: "${GRAFANA_PASSWORD}"
  persistence:
    enabled: true
    storageClassName: ${GRAFANA_STORAGE_CLASS}
    accessModes: ["ReadWriteOnce"]
    size: ${GRAFANA_STORAGE_SIZE}

# ── 组件开关 ────────────────────────────────────────────────────────────────
${ADMISSION_BLOCK}
nodeExporter:
  enabled: true
kubeStateMetrics:
  enabled: true
# kube-proxy 指标默认只监听 127.0.0.1:10249，Pod 侧抓不到 → 关掉避免 targetDown 告警噪音
kubeProxy:
  enabled: false
# etcd 指标需要客户端证书认证，配置复杂且已有每日自动快照兜底 → 关掉
kubeEtcd:
  enabled: false
# kubeadm/sealos 静态 Pod 的 scheduler/controller-manager：填节点 IP endpoints，
# 证书为 kubelet serving 证书 → https + 跳过校验
kubeScheduler:
  enabled: true
  endpoints: ["${NODE_IP}"]
  serviceMonitor:
    https: true
    tlsConfig:
      insecureSkipVerify: true
kubeControllerManager:
  enabled: true
  endpoints: ["${NODE_IP}"]
  serviceMonitor:
    https: true
    tlsConfig:
      insecureSkipVerify: true
EOF
log_ok "values 已生成"

# ── 3.5 local-path setup 自愈：hostPath 不响应 fsGroup，PV 目录必须 0777 ────
if kubectl get cm -n local-path-storage local-path-config >/dev/null 2>&1; then
    if ! kubectl get cm -n local-path-storage local-path-config -o jsonpath='{.data.setup}' | grep -q '0777'; then
        log_warn "local-path setup 脚本缺 0777 权限赋予（Prometheus 非 root 写不进 PV），自动修补..."
        kubectl patch cm -n local-path-storage local-path-config --type merge \
            -p '{"data":{"setup":"#!/bin/sh\nset -eu\nmkdir -m 0777 -p \"$VOL_DIR\"\nchmod 0777 \"$VOL_DIR\""}}' >/dev/null
        log_ok "local-path setup 已修补（存量 PV 目录需手动 chmod，见文档坑 23）"
    fi
fi

# ── 4. Chart 来源：离线 tgz 优先，缺失则 helm repo 兜底 ─────────────────────
log_info "[4/8] 准备 chart（kube-prometheus-stack ${CHART_VERSION}）..."
if [[ -f "${CHART_TGZ}" ]]; then
    log_ok "  使用离线包: ${CHART_TGZ}"
else
    log_warn "  离线包缺失，尝试 helm repo 拉取（外网较慢，耐心等待）..."
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
    helm repo update prometheus-community
    mkdir -p "${CHARTS_DIR}"
    helm pull prometheus-community/kube-prometheus-stack --version "${CHART_VERSION}" -d "${CHARTS_DIR}"
    [[ -f "${CHART_TGZ}" ]] || { log_error "chart 拉取失败: ${CHART_TGZ}"; exit 1; }
fi

# ── 5. helm install / upgrade ───────────────────────────────────────────────
kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1 || kubectl create namespace "${NAMESPACE}"
HELM_STATE="$(helm list -n "${NAMESPACE}" -f '^'"${RELEASE}"'$' -o json 2>/dev/null \
    | python3 -c 'import sys,json;l=json.load(sys.stdin);print(l[0]["status"] if l else "")')"
case "${HELM_STATE}" in
    "" )
        log_info "[5/8] helm install（CRDs 较多，需数分钟）..."
        helm install "${RELEASE}" "${CHART_TGZ}" \
            --namespace "${NAMESPACE}" \
            --values "${VALUES_FILE}" \
            --timeout 15m
        ;;
    deployed|failed)
        log_info "[5/8] release 状态 ${HELM_STATE}，helm upgrade..."
        helm upgrade "${RELEASE}" "${CHART_TGZ}" \
            --namespace "${NAMESPACE}" \
            --values "${VALUES_FILE}" \
            --timeout 15m
        ;;
    * )
        # pending-install/pending-upgrade 等中间态：upgrade 会报错，先卸载重来
        log_warn "release 处于中间态 ${HELM_STATE}，卸载后重新安装..."
        helm uninstall "${RELEASE}" -n "${NAMESPACE}"
        kubectl delete job -n "${NAMESPACE}" --all --ignore-not-found
        helm install "${RELEASE}" "${CHART_TGZ}" \
            --namespace "${NAMESPACE}" \
            --values "${VALUES_FILE}" \
            --timeout 15m
        ;;
esac

# ── 6. 等待 Pod 就绪 ────────────────────────────────────────────────────────
log_info "[6/8] 等待 ${NAMESPACE} 命名空间 Pod 就绪（首次需拉镜像，可能较久）..."
wait_pods_ready "${NAMESPACE}" "" 900 || true
kubectl get pods -n "${NAMESPACE}" -o wide

# ── 7. NodePort 冒烟验证（节点 IP 访问，NodePort 是 IPVS 转发无 LISTEN 属正常）─
log_info "[7/8] NodePort 冒烟验证（${NODE_IP}）..."
verify_url() {
    local name="$1" port="$2" path="$3"
    if curl -sS -m 5 -o /dev/null -w '%{http_code}' "http://${NODE_IP}:${port}${path}" 2>/dev/null | grep -q '200\|302'; then
        log_ok "  ${name}: http://${NODE_IP}:${port}${path} ✓"
    else
        log_warn "  ${name}: http://${NODE_IP}:${port}${path} 暂不可达（Pod 未就绪或镜像未注入）"
    fi
}
verify_url "Grafana      " "${GRAFANA_NODEPORT}" "/api/health"
verify_url "Prometheus   " "${PROMETHEUS_NODEPORT}" "/-/ready"
verify_url "Alertmanager " "${ALERTMANAGER_NODEPORT}" "/-/ready"

# ── 8. 汇总 ─────────────────────────────────────────────────────────────────
log_step "✅ Prometheus 监控套件部署完成"
cat <<EOF

  组件访问（远程经 VPN 时用 SSH 隧道转发以下端口，目标写节点 IP）:
    Grafana:      http://${NODE_IP}:${GRAFANA_NODEPORT}   admin / 见 helm-values/grafana-admin-password.txt
    Prometheus:   http://${NODE_IP}:${PROMETHEUS_NODEPORT}
    Alertmanager: http://${NODE_IP}:${ALERTMANAGER_NODEPORT}

  存储: Prometheus TSDB=${PROMETHEUS_STORAGE_CLASS} ${PROMETHEUS_STORAGE_SIZE}
       (保留 ${PROMETHEUS_RETENTION} / ${PROMETHEUS_RETENTION_SIZE})
       Alertmanager=${ALERTMANAGER_STORAGE_CLASS} ${ALERTMANAGER_STORAGE_SIZE}
       Grafana=${GRAFANA_STORAGE_CLASS} ${GRAFANA_STORAGE_SIZE}
  数据源: Grafana 已内置 Prometheus 数据源（chart 自动配置），自带 Kubernetes 监控大盘
  自定义监控: 部署 ServiceMonitor/PodMonitor 即被自动纳管（selector 已放开）

EOF
