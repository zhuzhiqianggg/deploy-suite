#!/usr/bin/env bash
# ============================================================================
# deploy.sh —— 一键 K8s 集群部署入口
# 用法：
#   sudo ./deploy.sh                # 部署全部（跳过确认）
#   sudo ./deploy.sh cleanup        # 只跑清理
#   sudo ./deploy.sh skip-cleanup   # 跳过清理直接部署
#   sudo ./deploy.sh 02 03 05       # 只跑指定编号的脚本
#   sudo ./deploy.sh --dry-run      # 只列出会跑什么，不执行
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SCRIPT_DIR}/scripts"
source "${SCRIPT_DIR}/config.env"
source "${SCRIPT_DIR}/common.sh"

mkdir -p "$LOG_DIR"

# ── 参数解析 ────────────────────────────────────────────────────────────────
RUN_CLEANUP=true
SPECIFIC=()
DRY_RUN=false

for arg in "$@"; do
    case "$arg" in
        cleanup)       RUN_CLEANUP=true;;
        skip-cleanup)  RUN_CLEANUP=false;;
        --dry-run)     DRY_RUN=true;;
        -h|--help)
            cat <<EOF
K8s 单节点集群一键部署
=====================
用法: sudo $0 [选项] [脚本编号...]

选项:
  cleanup          先跑清理（默认）
  skip-cleanup     跳过清理直接部署
  --dry-run        列出要执行的脚本，不实际执行
  --help           显示帮助

脚本编号:
  00  彻底清理 Docker/containerd/sealos 残留
  01  系统前置准备（Swap/内核/依赖/时间）
  02  Sealos K8s 集群安装
  03  NFS 存储类（/data/nfs + provisioner）
  04  集群稳定性与性能调优（kubelet/静态Pod/Calico/etcd快照）
  05  Kuboard v4 Web UI（内置 MySQL，NodePort 30080）
  06  ingress-nginx（hostNetwork 80/443，JSON 日志/安全优化）
  07  Fluent Bit → Graylog (Helm)
  08  验证 + 诊断
  09  易用性（命令补全/别名/metrics-server/k8s-diagnose CLI）

不指定编号 = 全部按顺序执行（00 → 09）

注: 数据库（MySQL/Redis/ES/Kafka）与 Doris 部署在 databases/ 目录，另行执行
注: Kuboard/ingress 镜像需先在海外服务器同步: images-manager.sh sync，再 load2k8s 注入
EOF
            exit 0
            ;;
        *) SPECIFIC+=("$arg");;
    esac
done

# ── 构建执行列表 ─────────────────────────────────────────────────────────────
declare -a EXEC_LIST
if [[ ${#SPECIFIC[@]} -gt 0 ]]; then
    EXEC_LIST=("${SPECIFIC[@]}")
else
    [[ "$RUN_CLEANUP" == true ]] && EXEC_LIST+=("00")
    EXEC_LIST+=("01" "02" "03" "04" "05" "06" "07" "08" "09")
fi

# ── 确认 ─────────────────────────────────────────────────────────────────────
declare -A DESC_MAP=(
    ["00"]="彻底清理 Docker/containerd/sealos 残留"
    ["01"]="系统前置准备（Swap/内核/依赖/时间）"
    ["02"]="Sealos K8s 集群安装"
    ["03"]="NFS 存储类（/data/nfs + provisioner + 调优）"
    ["04"]="集群稳定性与性能调优（kubelet/静态Pod/Calico/etcd快照）"
    ["05"]="Kuboard v4 部署（内置 MySQL，NodePort 30080）"
    ["06"]="ingress-nginx 部署（hostNetwork 80/443 + JSON 日志/安全优化）"
    ["07"]="Fluent Bit 日志采集 → Graylog (Helm)"
    ["08"]="集群最终验证 & 诊断"
    ["09"]="易用性（命令补全/别名/metrics-server/k8s-diagnose CLI）"
    ["10"]="Prometheus 监控套件（kube-prometheus-stack 90.0.0，NodePort 30300/30900/30903）"
)

echo ""
echo "============================================"
echo "  Sealos K8s 单节点集群一键部署"
echo "============================================"
echo "  架构:    $(detect_arch)"
echo "  K8s:     ${K8S_VERSION}"
echo "  Calico:  ${CALICO_VERSION}"
echo "  Helm:    ${HELM_VERSION}"
echo "  Sealos:  ${SEALOS_VERSION}"
echo "  存储:    NFS (${NFS_SERVER_IP}:${NFS_DIR})"
echo "  Graylog: ${GRAYLOG_HOST}:${GRAYLOG_PORT}"
echo "============================================"

echo ""
echo "将按顺序执行:"
for n in "${EXEC_LIST[@]}"; do
    desc="${DESC_MAP[$n]:-$(ls "$SCRIPTS_DIR"/${n}-*.sh 2>/dev/null | head -1 | xargs basename)}"
    echo "  [${n}] ${desc}"
done

if [[ "$DRY_RUN" == true ]]; then
    echo ""; echo "⚠️  --dry-run 模式，不实际执行"
    exit 0
fi

if [[ "${SKIP_CONFIRM:-}" != "1" ]]; then
    echo ""
    log_warn "继续部署？(y/N)"
    read -r ans
    [[ "$ans" =~ ^[Yy]$ ]] || { log_warn "已取消"; exit 0; }
fi

# ── 执行 ──────────────────────────────────────────────────────────────────────
TOTAL=${#EXEC_LIST[@]}
CURRENT=0
FAILURES=()

for num in "${EXEC_LIST[@]}"; do
    CURRENT=$((CURRENT + 1))
    shname=$(ls "$SCRIPTS_DIR"/${num}-*.sh 2>/dev/null | head -1)
    if [[ ! -f "$shname" ]]; then
        log_warn "[$CURRENT/$TOTAL] 跳过: ${num}-*.sh 不存在"
        continue
    fi

    log_info "[$CURRENT/$TOTAL] 执行: $(basename "$shname")"

    set +e
    bash "$shname" 2>&1 | tee -a "$LOG_FILE"
    RC=${PIPESTATUS[0]}
    set -e

    if [[ $RC -eq 0 ]]; then
        log_ok "[$CURRENT/$TOTAL] ✅ $(basename "$shname")"
    else
        log_error "[$CURRENT/$TOTAL] ❌ $(basename "$shname") 失败 (exit=$RC)"
        FAILURES+=("$(basename "$shname")")
        if [[ "${SKIP_CONFIRM:-}" != "1" ]]; then
            log_warn "继续执行后续脚本吗？(y/N)"
            read -r ans
            [[ "$ans" =~ ^[Yy]$ ]] || { log_warn "已停止"; break; }
        fi
    fi
done

# ── 汇总 ──────────────────────────────────────────────────────────────────────
echo ""
echo "============================================"
echo "  部署汇总"
echo "============================================"

kubectl get nodes 2>/dev/null || true
echo ""
kubectl get pods -A 2>/dev/null || true
echo ""
kubectl get sc 2>/dev/null || true

if [[ ${#FAILURES[@]} -eq 0 ]]; then
    log_ok "🎉 全部成功！"
    log_info "新终端生效: kubectl 补全 / 别名 (k, kgp...) 已配置；执行 source ~/.bashrc 立即生效"
else
    log_warn "有 ${#FAILURES[@]} 个脚本失败: ${FAILURES[*]}"
fi

log_info "完整日志: $LOG_FILE"
