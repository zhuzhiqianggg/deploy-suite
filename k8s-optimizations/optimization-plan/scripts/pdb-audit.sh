#!/bin/bash
# ============================================================================
# pdb-audit.sh — 业务 PDB 覆盖审计 + 批量生成
# ============================================================================
# 用途:    扫描所有业务 ns，列出"多副本无 PDB"的 Deployment（需补 PDB）
#          和"单副本"高危清单（建议扩副本+反亲和，不强制）
# 用法:    bash pdb-audit.sh                    # 审计（只读）
#          bash pdb-audit.sh --generate-yaml    # 生成多副本业务的 PDB 清单（stdout 输出，自行重定向 apply）
# 关联:    optimization-plan/07-pdb-protection.md
# 依赖:    kubectl + jq
# PDB 策略: 多副本 Deployment → minAvailable = max(1, replicas-1)
#           （replicas=3 时 minAvailable=2：允许逐个维护，永不全灭）
# 排除:    系统命名空间（kube-* / calico-* / tigera / ingress / csi / logging / kuboard）
# 退出码:  0=审计完成（是否有缺漏看输出）  1=依赖缺失
# ============================================================================

set -u

GEN_YAML=false
[ "${1:-}" = "--generate-yaml" ] && GEN_YAML=true

# ----------------------------- 依赖检查 -------------------------------------
command -v kubectl >/dev/null || { echo "[FATAL] 缺少 kubectl"; exit 1; }
command -v jq      >/dev/null || { echo "[FATAL] 缺少 jq"; exit 1; }

# 排除的系统命名空间（正则）
SYS_NS_RE='^(kube-.*|calico.*|tigera.*|ingress-nginx|csi-driver.*|logging|kuboard|default)$'

log() { echo "[$(date '+%F %T')] $*"; }

log "===== PDB 覆盖审计开始 ====="

# 取全部业务 Deployment: ns/name/replicas/selector-label
DEPLOYS=$(kubectl get deploy -A -o json | jq -r --arg re "$SYS_NS_RE" '
    .items[]
    | select(.metadata.namespace | test($re) | not)
    | select(.spec.replicas != null and .spec.replicas >= 1)
    | [
        .metadata.namespace,
        .metadata.name,
        (.spec.replicas | tostring),
        (.spec.selector.matchLabels | to_entries[0] | "\(.key)=\(.value)")
      ] | @tsv')

# 取全部已存在 PDB 的 (ns, selector) 集合
PDB_SET=$(kubectl get pdb -A -o json | jq -r '.items[] | "\(.metadata.namespace)\t\(.spec.selector.matchLabels | to_entries | map("\(.key)=\(.value)") | join(","))"')

MISSING_MULTI=()   # 多副本无 PDB（需补）
SINGLE=()          # 单副本（高危清单，仅提示）

while IFS=$'\t' read -r NS NAME REPLICAS SEL; do
    [ -z "${NS:-}" ] && continue
    # 该 Deployment 是否已有匹配 selector 的 PDB
    if echo "$PDB_SET" | grep -q "^${NS}	.*${SEL}"; then
        continue    # 已有 PDB 覆盖
    fi
    if [ "$REPLICAS" -ge 2 ]; then
        MISSING_MULTI+=("${NS}|${NAME}|${REPLICAS}|${SEL}")
    else
        SINGLE+=("${NS}|${NAME}|1|${SEL}")
    fi
done <<< "$DEPLOYS"

# ----------------------------- 输出: 审计报告 --------------------------------
echo
echo "========== [需补 PDB - 多副本] =========="
if [ ${#MISSING_MULTI[@]} -eq 0 ]; then
    echo "（无：多副本 Deployment 均有 PDB 覆盖 ✅）"
else
    printf "%-40s %-35s %-8s %s\n" "NAMESPACE" "DEPLOYMENT" "REPLICAS" "SELECTOR"
    for item in "${MISSING_MULTI[@]}"; do
        IFS='|' read -r ns name rep sel <<< "$item"
        printf "%-40s %-35s %-8s %s\n" "$ns" "$name" "$rep" "$sel"
    done
    echo "→ 共 ${#MISSING_MULTI[@]} 个，使用 --generate-yaml 生成 PDB 清单"
fi

echo
echo "========== [高危清单 - 单副本无 PDB（建议业务侧评估扩副本+反亲和）] =========="
if [ ${#SINGLE[@]} -eq 0 ]; then
    echo "（无单副本业务 Deployment ✅）"
else
    printf "%-40s %-35s %s\n" "NAMESPACE" "DEPLOYMENT" "SELECTOR"
    for item in "${SINGLE[@]}"; do
        IFS='|' read -r ns name rep sel <<< "$item"
        printf "%-40s %-35s %s\n" "$ns" "$name" "$sel"
    done
    echo "→ 共 ${#SINGLE[@]} 个单副本（drain/节点故障即中断，登记到维护检查单）"
fi

# ----------------------------- 输出: YAML 生成 -------------------------------
if $GEN_YAML; then
    echo
    echo "# ===== 以下为生成的 PDB 清单（redirect 到文件后 kubectl apply -f） =====" >&2
    if [ ${#MISSING_MULTI[@]} -gt 0 ]; then
        for item in "${MISSING_MULTI[@]}"; do
            IFS='|' read -r ns name rep sel <<< "$item"
            SEL_KEY="${sel%%=*}"; SEL_VAL="${sel#*=}"
            MINAV=$(( rep - 1 )); [ "$MINAV" -lt 1 ] && MINAV=1
            cat <<EOF
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: ${name}-pdb
  namespace: ${ns}
spec:
  # 副本数 ${rep} → minAvailable ${MINAV}：维护时保证至少 ${MINAV} 个存活
  minAvailable: ${MINAV}
  selector:
    matchLabels:
      ${SEL_KEY}: "${SEL_VAL}"
EOF
        done
    else
        echo "# （无需要生成的 PDB）" >&2
    fi
fi

log "===== 审计完成 ====="
exit 0
