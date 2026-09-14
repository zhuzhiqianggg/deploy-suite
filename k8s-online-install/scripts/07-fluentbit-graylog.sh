#!/usr/bin/env bash
# ============================================================================
# 06 —— Fluent Bit (Helm) → Graylog (GELF UDP)
# 用 Helm chart，对齐用户生产配置
# 参考: https://github.com/fluent/helm-charts (fluent-bit v0.52.0 / app v4.0.7)
#
# 关键配置（来自生产环境参考）:
#   - multiline.parser docker, cri   ← 处理 Java stacktrace 等多行日志
#   - systemd 读 kubelet.service    ← 主机日志
#   - grep filter 排除系统命名空间   ← 只关心产品服务
#   - Gelf_Short_Message_Key = log  ← Graylog 显示正确短消息
#   - Keep_Log On                   ← 保留原始 log 字段
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.env"
source "${SCRIPT_DIR}/../common.sh"

log_step "07. Fluent Bit → Graylog (Helm)"

# Graylog 地址仍是占位符 → 只生成 values 不部署（避免部署一个日志发不出去的 DaemonSet）
if [[ "$GRAYLOG_HOST" == *PLACEHOLDER* || -z "$GRAYLOG_HOST" ]]; then
    log_warn "GRAYLOG_HOST 仍为占位符（$GRAYLOG_HOST）"
    log_warn "请先在 config.env 填写真实 Graylog IP，再重跑本脚本"
    log_info "本跳仅生成/更新 helm-values/fluent-bit-values.yaml，不执行 helm install"
    ONLY_VALUES=true
else
    ONLY_VALUES=false
fi

helm repo add fluent https://fluent.github.io/helm-charts 2>/dev/null || true
helm repo update fluent 2>&1 | tail -2

# ── Helm Values 文件（写入 helm-values/ 便于版本控制）────────────────────────
VALUES_FILE="${SCRIPT_DIR}/../helm-values/fluent-bit-values.yaml"
mkdir -p "$(dirname "$VALUES_FILE")"

log_info "生成 Helm values: $VALUES_FILE"

cat > "$VALUES_FILE" <<EOF
# Helm values — Fluent Bit 日志采集 → Graylog
# 基于生产配置参考，适配本环境（fluent/fluent-bit chart）
kind: DaemonSet

# Fluent Bit 主配置（通过 extraFiles 覆盖 conf 目录）
extraFiles:
  custom_parsers.conf: |
    [PARSER]
        Name docker_no_time
        Format json
        Time_Keep Off
        Time_Key time
        Time_Format %Y-%m-%dT%H:%M:%S.%L

  fluent-bit.conf: |
    [SERVICE]
        Daemon Off
        Flush 1
        Log_Level info
        Parsers_File /fluent-bit/etc/parsers.conf
        Parsers_File /fluent-bit/etc/conf/custom_parsers.conf
        HTTP_Server On
        HTTP_Listen 0.0.0.0
        HTTP_Port 2020
        Health_Check On

    [INPUT]
        Name tail
        Path /var/log/containers/*.log
        multiline.parser docker, cri
        Tag kube.*
        Mem_Buf_Limit 10MB
        Skip_Long_Lines On

    [INPUT]
        Name systemd
        Tag host.*
        Systemd_Filter _SYSTEMD_UNIT=kubelet.service
        Read_From_Tail On

    [FILTER]
        Name kubernetes
        Match kube.*
        Merge_Log On
        Keep_Log On
        K8S-Logging.Parser On
        K8S-Logging.Exclude On

    # 排除系统命名空间（只关心产品服务日志）
    [FILTER]
        Name grep
        Match kube.*
        Exclude \$kubernetes['namespace_name'] ${LOG_EXCLUDE_NAMESPACES}

    [OUTPUT]
        Name gelf
        Match kube.*
        Host ${GRAYLOG_HOST}
        Port ${GRAYLOG_PORT}
        Mode ${GRAYLOG_PROTOCOL}
        Gelf_Short_Message_Key log

# 系统容器目录（containerd 场景：/var/log/containers 是指向 /var/log/pods 的软链，
# 挂 /var/log 即可覆盖；varLibDockerContainers 仅为 chart 默认卷占位）
hostPath:
  varLog: /var/log
  varLibDockerContainers: /var/lib/docker/containers
  etcMachineId: /etc/machine-id

# 资源（DaemonSet 每个节点 1 个）
resources:
  requests:
    cpu: 100m
    memory: 64Mi
  limits:
    cpu: 500m
    memory: 256Mi

# 容忍所有节点（包括 control-plane）
tolerations:
  - operator: Exists

hostNetwork: false

# 优先级（节点关键组件，资源紧张时最后被驱逐）
priorityClassName: system-node-critical
EOF

log_ok "Values 文件已生成"

if [[ "$ONLY_VALUES" == "true" ]]; then
    log_step "✅ Fluent Bit values 已生成（未部署 —— GRAYLOG_HOST 未配置）"
    exit 0
fi

# ── 部署 / 升级 ──────────────────────────────────────────────────────────────
if helm list -A 2>/dev/null | grep -q "^${FLUENTBIT_HELM_RELEASE}"; then
    log_info "Fluent Bit 已存在，helm upgrade..."
    helm upgrade "${FLUENTBIT_HELM_RELEASE}" fluent/fluent-bit \
        --namespace logging --create-namespace \
        --values "$VALUES_FILE"
else
    log_info "helm install..."
    helm install "${FLUENTBIT_HELM_RELEASE}" fluent/fluent-bit \
        --namespace logging --create-namespace \
        --values "$VALUES_FILE"
fi

sleep 10
wait_pods_ready logging app.kubernetes.io/name=fluent-bit 60

log_ok "✅ Fluent Bit 已部署"
echo ""
kubectl get pods -n logging
echo ""
log_info "ConfigMap:"
kubectl get cm -n logging fluent-bit -o yaml | head -5
echo ""
log_step "✅ Fluent Bit → Graylog 部署完成"
log_info "  DaemonSet: 每个节点一个"
log_info "  Graylog:   ${GRAYLOG_PROTOCOL}://${GRAYLOG_HOST}:${GRAYLOG_PORT}"
log_info "  排除命名空间: ${LOG_EXCLUDE_NAMESPACES}"
log_info "  资源:      requests 100m/64Mi, limits 500m/256Mi"
