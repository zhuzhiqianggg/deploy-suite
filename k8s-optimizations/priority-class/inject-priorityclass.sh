# ============================================================================
# 按命名空间自动注入 priorityClassName 的脚本
# ============================================================================
# 原理：遍历所有 Deployment/StatefulSet，根据命名空间后缀匹配规则，
#       自动 patch spec.template.spec.priorityClassName
#
# 匹配规则（可自行调整）：
#   *-temp / db-verify-*  → temp-priority (100)
#   *-pre                 → pre-priority (5000)   ★ 优先驱逐
#   *-test                → test-priority (1000)
#   *-prod / *-release    → prod-priority (100000)
#   其他                   → default-priority (10000)
#
# 系统命名空间（kube-system, calico-system 等）跳过，不修改
# ============================================================================

#!/bin/bash
set -e

# 系统命名空间白名单（不修改这些命名空间）
SYSTEM_NS="kube-system kube-public kube-node-lease calico-system tigera-operator csi-driver-nfs ingress-nginx"

# 根据命名空间名称返回对应的 priorityClass
get_priority_for_ns() {
    local ns="$1"
    # 生产环境
    if [[ "$ns" =~ -prod$ ]] || [[ "$ns" =~ -release$ ]]; then
        echo "prod-priority"
    # 预发环境（优先驱逐）
    elif [[ "$ns" =~ -pre$ ]]; then
        echo "pre-priority"
    # 临时环境
    elif [[ "$ns" =~ -temp$ ]] || [[ "$ns" =~ ^db-verify- ]]; then
        echo "temp-priority"
    # 测试环境
    elif [[ "$ns" =~ -test$ ]]; then
        echo "test-priority"
    # 其他
    else
        echo "default-priority"
    fi
}

# 判断是否为系统命名空间
is_system_ns() {
    local ns="$1"
    for sys in $SYSTEM_NS; do
        [[ "$ns" == "$sys" ]] && return 0
    done
    return 1
}

echo "=========================================="
echo "  批量注入 priorityClassName"
echo "=========================================="
echo ""

# 处理所有命名空间
for ns in $(kubectl get ns -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
    if is_system_ns "$ns"; then
        echo "[跳过] $ns (系统命名空间)"
        continue
    fi

    pc=$(get_priority_for_ns "$ns")
    echo "[处理] $ns → $pc"

    # 处理 Deployment
    for deploy in $(kubectl get deploy -n "$ns" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
        current_pc=$(kubectl get deploy "$deploy" -n "$ns" -o jsonpath='{.spec.template.spec.priorityClassName}' 2>/dev/null)
        if [[ "$current_pc" != "$pc" ]]; then
            kubectl patch deploy "$deploy" -n "$ns" --type=strategic -p "{\"spec\":{\"template\":{\"spec\":{\"priorityClassName\":\"$pc\"}}}}" >/dev/null 2>&1
            echo "  ✓ Deployment/$deploy: $current_pc → $pc"
        fi
    done

    # 处理 StatefulSet
    for sts in $(kubectl get sts -n "$ns" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
        current_pc=$(kubectl get sts "$sts" -n "$ns" -o jsonpath='{.spec.template.spec.priorityClassName}' 2>/dev/null)
        if [[ "$current_pc" != "$pc" ]]; then
            kubectl patch sts "$sts" -n "$ns" --type=strategic -p "{\"spec\":{\"template\":{\"spec\":{\"priorityClassName\":\"$pc\"}}}}" >/dev/null 2>&1
            echo "  ✓ StatefulSet/$sts: $current_pc → $pc"
        fi
    done
done

echo ""
echo "=========================================="
echo "  注入完成"
echo "=========================================="
echo ""
echo "查看各命名空间 Pod 优先级分布:"
kubectl get pods -A -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,PRIORITYCLASS:.spec.priorityClassName --no-headers 2>/dev/null | awk '{print $1, $3}' | sort | uniq -c | sort -rn | head -20
