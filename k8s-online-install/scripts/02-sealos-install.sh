#!/usr/bin/env bash
# ============================================================================
# 02 —— Sealos K8s 单节点集群安装
#
# 关键踩坑记录：
#   1. labring/kubernetes / calico / helm 镜像必须有 ARM64 manifest
#      推荐版本（本次验证通过）：K8s v1.29.9 + Calico v3.28.1 + Helm v3.12.0
#   2. 必须先清掉 /root/.sealos/default/Clusterfile 残留 —— 这是 #1 blocker
#   3. Sealos 会自动装 containerd、kubeadm、kubelet、etcd、registry
#   4. containerd 加速器 patch 必须幂等：TOML 里重复定义同名 table 会导致
#      containerd 起不来 —— 所以 patch 前先备份、重启后校验、失败回滚
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.env"
source "${SCRIPT_DIR}/../common.sh"

log_step "02. Sealos Kubernetes 集群安装"

ARCH="$(detect_arch)"

# 幂等：集群已在跑就直接跳过（重复执行 02 不再重装）
if kubectl get nodes 2>/dev/null | grep -q " Ready"; then
    log_warn "检测到集群已在运行（kubectl get nodes 有 Ready 节点）"
    log_info "跳过 sealos run，只做收尾（kubeconfig/加速器校验）"
    SKIP_RUN=true
else
    SKIP_RUN=false
fi

if [[ "$SKIP_RUN" == false ]]; then
    # ── 0. 确认干净 ──────────────────────────────────────────────────────────
    log_info "[0/5] 确认环境干净..."
    # 检查 /root/.sealos 残留 ← sealos "ClusterStatus is not ClusterSuccess" 的 #1 原因
    if [[ -d /root/.sealos ]]; then
        log_warn "检测到 /root/.sealos 残留 —— 可能导致 sealos 失败！"
        log_info "备份并删除..."
        mv /root/.sealos "/root/.sealos.bak.$(date +%s)" 2>/dev/null || true
    fi
    # 确认之前没装过 containerd（Docker 残留）
    if [[ -f /usr/bin/containerd ]] && ! command -v sealos >/dev/null 2>&1; then
        log_error "containerd 二进制仍在! 请先运行 00-cleanup-docker.sh"
        exit 1
    fi
    log_ok "环境已干净"

    # ── 1. 下载 Sealos CLI ──────────────────────────────────────────────────
    log_info "[1/5] 下载 Sealos $SEALOS_VERSION ($ARCH)..."
    SEALOS_BIN="/usr/local/bin/sealos"
    if [[ -x "$SEALOS_BIN" ]] && sealos version 2>/dev/null | grep -q "$SEALOS_VERSION"; then
        log_ok "Sealos 已安装: $(sealos version | head -1)"
    else
        SEALOS_TGZ="/tmp/sealos_${SEALOS_VERSION}_linux_${ARCH}.tar.gz"
        SEALOS_URL="https://github.com/labring/sealos/releases/download/${SEALOS_VERSION}/sealos_${SEALOS_VERSION}_linux_${ARCH}.tar.gz"
        PROXY_URL="${GITHUB_PROXY}${SEALOS_URL}"
        log_info "下载地址: $SEALOS_URL"

        # 先试代理，失败试直连
        if ! retry_download "$PROXY_URL" "$SEALOS_TGZ" 2; then
            log_warn "代理下载失败，尝试直连..."
            retry_download "$SEALOS_URL" "$SEALOS_TGZ" 3
        fi

        tar -zxf "$SEALOS_TGZ" -C /tmp sealos 2>/dev/null || tar -zxf "$SEALOS_TGZ" -C /tmp 2>/dev/null
        chmod +x /tmp/sealos 2>/dev/null || chmod +x "$(find /tmp -maxdepth 1 -name sealos -type f | head -1)"
        mv /tmp/sealos /usr/local/bin/ 2>/dev/null || mv "$(find /tmp -maxdepth 1 -name sealos -type f | head -1)" /usr/local/bin/sealos
        log_ok "Sealos 安装完成: $(sealos version | head -1)"
    fi

    # ── 2. sealos run —— 在线拉镜像 + 装集群 ────────────────────────────────
    log_info "[2/5] sealos run 安装集群..."
    log_info "镜像: labring/kubernetes:${K8S_VERSION} + labring/helm:${HELM_VERSION} + labring/calico:${CALICO_VERSION}"

    sealos run \
        "labring/kubernetes:${K8S_VERSION}" \
        "labring/helm:${HELM_VERSION}" \
        "labring/calico:${CALICO_VERSION}" \
        --single 2>&1 | tee "${LOG_DIR}/sealos-run.log"

    RC=${PIPESTATUS[0]}
    if [[ $RC -ne 0 ]]; then
        log_error "sealos run 失败 (exit=$RC)，查看日志: ${LOG_DIR}/sealos-run.log"
        log_error "常见原因："
        log_error "  1. /root/.sealos 有残留 —— 再跑一遍 00-cleanup-docker.sh"
        log_error "  2. Docker Hub 不通 —— 需要配置 containerd 加速器"
        log_error "  3. 镜像没有 ARM64 manifest —— 换个版本"
        exit 1
    fi
    log_ok "sealos run 成功！"
fi

# ── 3. 配置 kubectl（root + 发起 sudo 的用户）────────────────────────────────
log_info "[3/5] 配置 kubeconfig..."
mkdir -p /root/.kube
cp /etc/kubernetes/admin.conf /root/.kube/config
chmod 600 /root/.kube/config
# 真实用户（sudo 调用者）也放一份
REAL_USER="${SUDO_USER:-}"
if [[ -n "$REAL_USER" && "$REAL_USER" != "root" ]]; then
    REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
    mkdir -p "$REAL_HOME/.kube"
    cp /etc/kubernetes/admin.conf "$REAL_HOME/.kube/config"
    chown -R "$REAL_USER:" "$REAL_HOME/.kube"
    log_ok "kubeconfig 已配置: /root/.kube/config + $REAL_HOME/.kube/config"
else
    log_ok "kubeconfig 已配置: /root/.kube/config"
fi

# ── 4. containerd 加速器（幂等 + 失败回滚）────────────────────────────────────
log_info "[4/5] 确保 containerd 镜像加速器配置..."
CONTAINERD_CONF="/etc/containerd/config.toml"
if [[ -f "$CONTAINERD_CONF" ]]; then
    MIRRORS_CSV=$(printf '"%s",' "${REGISTRY_MIRRORS[@]}"); MIRRORS_CSV="${MIRRORS_CSV%,}"
    DOCKER_IO_HEADER='registry.mirrors."docker.io"'

    if grep -qF "$DOCKER_IO_HEADER" "$CONTAINERD_CONF"; then
        # header 已存在：检查 endpoint 是否已包含加速器，缺就替换该 endpoint 行
        if ! grep -qF "${REGISTRY_MIRRORS[0]}" "$CONTAINERD_CONF"; then
            cp "$CONTAINERD_CONF" "${CONTAINERD_CONF}.bak.$$"
            log_info "更新 docker.io endpoint 为加速器列表..."
            sed -i "/mirrors.\"docker.io\"/,/endpoint =/ s|endpoint = .*|endpoint = [${MIRRORS_CSV}]|" "$CONTAINERD_CONF"
            if ! restart_containerd_healthy; then
                log_warn "containerd 重启失败，回滚配置..."
                cp "${CONTAINERD_CONF}.bak.$$" "$CONTAINERD_CONF"
                restart_containerd_healthy || true
            fi
        else
            log_ok "加速器已配置，无需修改"
        fi
    else
        # header 不存在：只追加子表（不追加父表 [..registry.mirrors]，
        # 避免 TOML table 重定义导致 containerd 起不来）
        cp "$CONTAINERD_CONF" "${CONTAINERD_CONF}.bak.$$"
        log_info "追加 docker.io 加速器..."
        cat >> "$CONTAINERD_CONF" <<TOML
      [plugins."io.containerd.grpc.v1.cri".registry.mirrors."docker.io"]
        endpoint = [${MIRRORS_CSV}]
      [plugins."io.containerd.grpc.v1.cri".registry.mirrors."registry-1.docker.io"]
        endpoint = [${MIRRORS_CSV}]
TOML
        if ! restart_containerd_healthy; then
            log_warn "containerd 重启失败，回滚配置..."
            cp "${CONTAINERD_CONF}.bak.$$" "$CONTAINERD_CONF"
            restart_containerd_healthy || true
        fi
    fi
fi

# ── 5. 验证集群 ───────────────────────────────────────────────────────────────
log_info "[5/5] 验证集群..."
sleep 5
wait_for "node Ready" 300 5 bash -c 'kubectl get nodes 2>/dev/null | grep -q " Ready"'
kubectl get pods -n kube-system -o wide
sealos status 2>/dev/null | head -15 || true

log_step "✅ K8s 集群安装完成！"
log_info "  kubectl get nodes  —— 查看节点"
log_info "  kubectl get pods -A —— 查看所有 Pod"
log_info "  sealos status       —— sealos 集群状态"
log_info "  命令补全会在 [08] 脚本统一配置"
