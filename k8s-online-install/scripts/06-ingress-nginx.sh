#!/usr/bin/env bash
# ============================================================================
# 06 —— ingress-nginx 部署（hostNetwork 模式，占用宿主机 80/443）
#
# 特性：
#   - hostNetwork: true + dnsPolicy: ClusterFirstWithHostNet
#     控制器直接绑定宿主机 80/443（流量路径: 用户 → ELB → 节点:80/443）
#   - 整合 k8s-optimizations/ingress-nginx 的生产优化配置（见 manifests/ingress-nginx.yaml）：
#       · JSON 结构化访问日志（23 字段，含 request_id/upstream 耗时/真实 IP）
#       · 安全响应头（custom-headers CM: HSTS/X-Frame-Options/...）
#       · gzip + brotli 双压缩 / TLS1.2+1.3 / 弱套件禁用
#       · upstream keepalive 连接池 / 限定重试防雪崩
#   - admission webhook（certgen Job 自动签证书，拦截非法 ingress）
#
# 注：containerd 已配置 registry.k8s.io → k8s.m.daocloud.io 加速（02 脚本）
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.env"
source "${SCRIPT_DIR}/../common.sh"

log_step "06. ingress-nginx 部署（hostNetwork 80/443）"

CONTROLLER_IMG="registry.k8s.io/ingress-nginx/controller:${INGRESS_NGINX_VERSION}"
CERTGEN_IMG="registry.k8s.io/ingress-nginx/kube-webhook-certgen:${WEBHOOK_CERTGEN_VERSION}"
MANIFEST="${SCRIPT_DIR}/../manifests/ingress-nginx.yaml"

check_root

# ── 1. 预拉镜像 ──────────────────────────────────────────────────────────────
# 注意: ctr 裸客户端不走 containerd certs.d 配置（那是 CRI 插件的），
#       必须显式 --hosts-dir，否则直连 registry.k8s.io 被墙
log_info "[1/4] 预拉镜像（走 mirror 加速）..."
for img in "$CONTROLLER_IMG" "$CERTGEN_IMG"; do
    if ! sudo ctr -n k8s.io images ls -q 2>/dev/null | grep -q "^${img}$"; then
        sudo ctr -n k8s.io images pull --hosts-dir /etc/containerd/certs.d \
            --platform "linux/$(detect_arch)" "$img" >/dev/null 2>&1 \
            || log_warn "  预拉失败（不阻塞，apply 时 kubelet 会再拉）: $img"
    fi
done
log_ok "镜像就绪: ${CONTROLLER_IMG}"

# ── 2. 应用清单（替换镜像版本变量）────────────────────────────────────────────
log_info "[2/4] 应用 ingress-nginx 清单..."
# 清理旧 certgen Job（幂等重跑需重新 patch webhook CA）
kubectl delete job -n ingress-nginx ingress-nginx-admission-create ingress-nginx-admission-patch --ignore-not-found=true

sed -e "s|\${CONTROLLER_IMG}|${CONTROLLER_IMG}|g" \
    -e "s|\${CERTGEN_IMG}|${CERTGEN_IMG}|g" "$MANIFEST" | kubectl apply -f -

# ── 3. 等待就绪 ──────────────────────────────────────────────────────────────
log_info "[3/4] 等待 controller 就绪（hostNetwork 绑定宿主机 80/443）..."
wait_for "controller Deployment Available" 180 5 \
    bash -c "kubectl -n ingress-nginx get deployment ingress-nginx-controller -o jsonpath='{.status.conditions[?(@.type==\"Available\")].status}' | grep -q True"

# certgen patch Job 完成（webhook CA 注入）
kubectl wait --for=condition=complete job/ingress-nginx-admission-patch -n ingress-nginx --timeout=120s 2>/dev/null \
    || log_warn "admission patch Job 未按时完成（不影响 controller 运行，检查: kubectl get jobs -n ingress-nginx）"

# ── 4. 验证宿主机 80/443 ─────────────────────────────────────────────────────
log_info "[4/4] 验证宿主机端口监听..."
sleep 3
for port in 80 443; do
    if ss -tlnp 2>/dev/null | grep -qE ":${port}\s"; then
        log_ok "宿主机端口 ${port} 已监听"
    else
        log_warn "宿主机端口 ${port} 未监听（检查: kubectl logs -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx）"
    fi
done
# 默认后端应返回 404（nginx 默认 server）
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 http://127.0.0.1/ || echo "FAIL")
if [[ "$HTTP_CODE" == "404" ]]; then
    log_ok "默认后端验证通过 (HTTP 404 = nginx 默认 server 正常)"
else
    log_warn "curl http://127.0.0.1/ 返回: $HTTP_CODE"
fi

log_step "✅ ingress-nginx 部署完成"
log_info "访问入口: http://${NODE_IP}:80 / https://${NODE_IP}:443（hostNetwork，无需 NodePort）"
log_info "IngressClass: nginx（kubectl get ingressclass）"
log_info "JSON 访问日志: kubectl logs -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx | head -1"
log_info "业务使用: Ingress 指定 ingressClassName: nginx 即可"
