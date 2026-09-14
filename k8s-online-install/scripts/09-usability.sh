#!/usr/bin/env bash
# ============================================================================
# 09 —— 易用性增强
#
# 1. 命令补全：kubectl / helm / crictl / kubeadm / sealos（系统级，root+普通用户）
#    老方案失败的原因：01 脚本在 kubectl 还没装时就尝试配补全，且往 bashrc
#    盲目 append 造成重复行 + source 不存在的文件。本脚本幂等 + 带标记块。
# 2. kubectl 常用别名（k / kgp / kgd / kl ...）
# 3. metrics-server（kubectl top 可用）
# 4. crictl 默认 runtime endpoint
# 5. 故障诊断 CLI：k8s-diagnose 安装到 /usr/local/bin（任意目录直接执行）
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.env"
source "${SCRIPT_DIR}/../common.sh"

log_step "09. 易用性增强（补全 / 别名 / metrics-server / 诊断CLI）"

check_root

# 目标用户列表：root + sudo 发起者
TARGET_USERS=(root)
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    TARGET_USERS+=("${SUDO_USER}")
fi

# ── 1. 系统级补全文件 ─────────────────────────────────────────────────────────
log_info "[1/5] 生成系统级补全文件 (/etc/bash_completion.d/)..."
dpkg -l bash-completion 2>/dev/null | grep -q "^ii" || apt-get install -y -qq bash-completion

gen_completion() {
    local tool="$1" cmd="${2:-$1}"
    if ! command -v "$cmd" &>/dev/null; then
        log_warn "  $cmd 未安装，跳过补全"
        return 0
    fi
    if "$cmd" completion bash > "/etc/bash_completion.d/${tool}" 2>/dev/null; then
        log_ok "  ${tool} 补全已写入 /etc/bash_completion.d/${tool}"
    else
        log_warn "  ${tool} 不支持 completion bash，跳过"
        rm -f "/etc/bash_completion.d/${tool}"
    fi
}

gen_completion kubectl
gen_completion helm
gen_completion crictl
gen_completion kubeadm
# sealos 部分版本无 completion 子命令
touch /etc/bash_completion.d/sealos
sealos completion bash > /etc/bash_completion.d/sealos 2>/dev/null || \
    { rm -f /etc/bash_completion.d/sealos; log_info "  sealos 无 completion 子命令，跳过"; }

# ── 2. bashrc 标记块（root + 普通用户，幂等）──────────────────────────────────
log_info "[2/5] 写入 bashrc 配置块（幂等，自动清理历史遗留重复行）..."

for user in "${TARGET_USERS[@]}"; do
    uhome=$(getent passwd "$user" | cut -d: -f6)
    [[ -z "$uhome" ]] && continue
    uownership="${user}:"

    BLOCK="# >>> k8s-sealos usability block >>>
# 命令补全（kubectl/helm/crictl/kubeadm/sealos）
if [ -f /usr/share/bash-completion/bash_completion ]; then
    . /usr/share/bash-completion/bash_completion
elif [ -f /etc/bash_completion ]; then
    . /etc/bash_completion
fi
for f in /etc/bash_completion.d/kubectl /etc/bash_completion.d/helm \\
         /etc/bash_completion.d/crictl /etc/bash_completion.d/kubeadm \\
         /etc/bash_completion.d/sealos; do
    [ -f \"\$f\" ] && . \"\$f\"
done

# 别名
alias k=kubectl
alias kgp='kubectl get pods'
alias kgpa='kubectl get pods -A'
alias kgd='kubectl get deployment'
alias kgs='kubectl get svc'
alias kgn='kubectl get nodes'
alias kdel='kubectl delete'
alias kl='kubectl logs -f'
alias kex='kubectl exec -it'
alias kdesc='kubectl describe'
alias kdiag='k8s-diagnose'
# 别名 k 也带补全
complete -o default -F __start_kubectl k 2>/dev/null
# <<< k8s-sealos usability block <<<"

    write_bashrc_block "$uhome/.bashrc" "k8s-sealos usability" "$BLOCK"
    chown "$uownership" "$uhome/.bashrc" 2>/dev/null || true
    log_ok "  $user ($uhome/.bashrc) 已写入标记块"
done

# 校验补全函数真实可用
if bash -ic 'type __start_kubectl' &>/dev/null; then
    log_ok "✅ kubectl 补全函数校验通过（新终端即生效）"
else
    log_warn "补全函数未检测到 —— 请确认 bash-completion 已安装并重开终端"
fi

# ── 3. crictl 默认 endpoint ───────────────────────────────────────────────────
log_info "[3/5] 配置 crictl 默认 runtime endpoint..."
if [[ ! -f /etc/crictl.yaml ]] || ! grep -q "runtime-endpoint" /etc/crictl.yaml; then
    cat > /etc/crictl.yaml <<EOF
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
EOF
    log_ok "/etc/crictl.yaml 已写入"
else
    log_ok "crictl 配置已存在"
fi

# ── 4. metrics-server（kubectl top 需要）─────────────────────────────────────
if [[ "${INSTALL_METRICS_SERVER}" == "true" ]]; then
    log_info "[4/5] 部署 metrics-server ${METRICS_SERVER_VERSION}..."
    if kubectl get deployment -n kube-system metrics-server &>/dev/null; then
        log_ok "metrics-server 已存在，跳过"
    else
        MANIFEST="${SCRIPT_DIR}/../helm-values/metrics-server.yaml"
        mkdir -p "$(dirname "$MANIFEST")"

        DL_OK=false
        for url in \
            "${GITHUB_PROXY}https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_SERVER_VERSION}/components.yaml" \
            "https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_SERVER_VERSION}/components.yaml"; do
            if retry_download "$url" "$MANIFEST" 2; then DL_OK=true; break; fi
        done
        if [[ "$DL_OK" != "true" ]]; then
            log_error "metrics-server manifest 下载失败（GitHub 不通？），跳过 —— kubectl top 将不可用"
        else
            # 镜像走 k8s.m.daocloud.io（registry.k8s.io 加速）
            for mirror in "${K8S_REGISTRY_MIRRORS[@]}"; do
                sed -i "s|registry.k8s.io/metrics-server|${mirror}/metrics-server|g" "$MANIFEST"
            done
            # 自签 kubelet 证书场景必须 --kubelet-insecure-tls（幂等插入 args）
            python3 - "$MANIFEST" <<'PYEOF'
import sys, yaml
path = sys.argv[1]
docs = list(yaml.safe_load_all(open(path)))
for doc in docs:
    if doc and doc.get('kind') == 'Deployment' and doc.get('metadata', {}).get('name') == 'metrics-server':
        for c in doc['spec']['template']['spec']['containers']:
            if c.get('name') == 'metrics-server' and '--kubelet-insecure-tls' not in c.get('args', []):
                c.setdefault('args', []).append('--kubelet-insecure-tls')
yaml.dump_all(docs, open(path, 'w'), default_flow_style=False, sort_keys=False)
PYEOF
            kubectl apply -f "$MANIFEST"

            log_info "等待 metrics-server 就绪..."
            wait_pods_ready kube-system k8s-app=metrics-server 180 || \
                log_warn "metrics-server Pod 未就绪，kubectl top 可能暂不可用（镜像拉取慢时属正常，稍后自查）"
        fi
    fi

    # 验证 top
    sleep 5
    if kubectl top nodes &>/dev/null; then
        log_ok "✅ kubectl top 可用:"
        kubectl top nodes || true
    else
        log_warn "kubectl top 暂不可用（metrics-server 需要约 1 分钟采集首批数据，稍后再试）"
    fi
else
    log_info "[4/5] INSTALL_METRICS_SERVER=false，跳过"
fi

# ── 5. 故障诊断 CLI（k8s-diagnose → /usr/local/bin）──────────────────────────
log_info "[5/5] 安装 k8s-diagnose 诊断 CLI 到 /usr/local/bin..."
# 源文件优先级: k8s-online-install/diagnostics/（本目录自带） → k8s-optimizations/diagnostics/（运维配置库）
DIAG_SRC=""
for cand in "${SCRIPT_DIR}/../diagnostics/k8s-diagnose.sh" \
            "/home/ubuntu/deploy/k8s-optimizations/diagnostics/k8s-diagnose.sh"; do
    [[ -f "$cand" ]] && { DIAG_SRC="$cand"; break; }
done
if [[ -n "$DIAG_SRC" ]]; then
    install -m 0755 "$DIAG_SRC" /usr/local/bin/k8s-diagnose
    # 补全: k8s-diagnose --<TAB>
    cat > /etc/bash_completion.d/k8s-diagnose <<'COMPEOF'
_k8s_diagnose() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    COMPREPLY=( $(compgen -W "--fix --verbose --help" -- "$cur") )
}
complete -F _k8s_diagnose k8s-diagnose
COMPEOF
    log_ok "k8s-diagnose 已安装（源: $DIAG_SRC）"
else
    log_warn "未找到 k8s-diagnose.sh 源文件，跳过（请确认 diagnostics/ 目录存在）"
fi

log_step "✅ 易用性增强完成"
log_info "  补全:  kubectl / helm / crictl / kubeadm（sealos 视版本支持）"
log_info "  别名:  k kgp kgpa kgd kgs kgn kdel kl kex kdesc kdiag"
log_info "  诊断:  k8s-diagnose [--fix] [--verbose]（任意目录可用，--fix 自动修复异常 Pod）"
log_info "  立即生效: source ~/.bashrc 或重开终端"
log_info "  资源监控: kubectl top nodes / kubectl top pods -A"
