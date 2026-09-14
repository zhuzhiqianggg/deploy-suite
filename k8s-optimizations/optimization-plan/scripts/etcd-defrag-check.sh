#!/bin/bash
# ============================================================================
# etcd-defrag-check.sh — etcd 健康巡检 + 碎片率判断 + 可选碎片整理
# ============================================================================
# 用途:    巡检 etcd member 健康/db 大小/碎片率；碎片率超阈值时（--defrag）逐 member 整理
# 用法:    bash etcd-defrag-check.sh            # 只读巡检（crontab 用这个）
#          bash etcd-defrag-check.sh --defrag   # 低峰期手工执行碎片整理
# 部署:    install -m 750 etcd-defrag-check.sh /root/scripts/
# crontab: 0 3 * * 1 /root/scripts/etcd-defrag-check.sh >> /var/log/etcd-defrag-check.log 2>&1
# 关联:    optimization-plan/01-etcd-backup.md / 09-governance-cleanup.md
# 原理:    db_total_size vs db_total_size_in_use 差值 = 碎片；
#          defrag 期间该 member 短暂阻塞写 → 只能逐个 member 做，间隔等待
# 退出码:  0=正常  1=巡检失败  2=碎片率超标（未 --defrag 时）
# ============================================================================

set -u

# ----------------------------- 可调参数 -------------------------------------
MEMBERS="192.168.10.100 192.168.10.104 192.168.10.105"   # 三个 etcd member 的 IP
ETCDCTL="${ETCDCTL:-/usr/bin/etcdctl}"
CERT_DIR="/etc/kubernetes/pki/etcd"
FRAG_THRESHOLD=50          # 碎片率阈值（%），超过才提示/执行 defrag
DEFRAG_INTERVAL=30         # 逐 member defrag 的间隔秒数（给集群恢复窗口）
DO_DEFRAG=false
# ----------------------------------------------------------------------------
[ "${1:-}" = "--defrag" ] && DO_DEFRAG=true
CERT_ARGS="--cacert=${CERT_DIR}/ca.crt --cert=${CERT_DIR}/server.crt --key=${CERT_DIR}/server.key"

log() { echo "[$(date '+%F %T')] $*"; }

[ -x "$ETCDCTL" ] || ETCDCTL="$(command -v etcdctl || true)"
[ -n "$ETCDCTL" ] || { log "[FATAL] etcdctl 未找到"; exit 1; }

log "===== etcd 巡检开始（defrag=${DO_DEFRAG}） ====="

OVERALL_FRAG=0
FAILED=0

for M in $MEMBERS; do
    log "----- member: $M -----"
    EP="https://${M}:2379"

    # ---- 1. member 状态（term/leader/raft index/db size）----
    log "[CMD] $ETCDCTL --endpoints=$EP endpoint status -w table $CERT_ARGS"
    if ! STATUS=$(ETCDCTL_API=3 "$ETCDCTL" --endpoints="$EP" endpoint status -w table $CERT_ARGS 2>&1); then
        log "[FAIL] member $M 状态获取失败: $STATUS"
        FAILED=1
        continue
    fi
    echo "$STATUS" | sed 's/^/    /'

    # ---- 2. 告警检查（NOSPACE 是最致命告警：集群只读）----
    log "[CMD] $ETCDCTL --endpoints=$EP alarm list $CERT_ARGS"
    ALARMS=$(ETCDCTL_API=3 "$ETCDCTL" --endpoints="$EP" alarm list $CERT_ARGS 2>&1)
    if [ -n "$ALARMS" ] && ! echo "$ALARMS" | grep -q "^$"; then
        log "[WARN] 存在告警: $ALARMS"
        # NOSPACE 告警处理：先压缩+defrag，再 disarm
        if echo "$ALARMS" | grep -q NOSPACE; then
            log "[CRITICAL] NOSPACE 告警！db 超配额，集群已只读。应急流程："
            log "  ETCDCTL_API=3 $ETCDCTL --endpoints=$EP compact \$(etcdctl endpoint status -w json | jq .[0].status.header.revision)"
            log "  $ETCDCTL --endpoints=$EP defrag $CERT_ARGS && $ETCDCTL --endpoints=$EP alarm disarm $CERT_ARGS"
        fi
    else
        log "[OK] 无告警"
    fi

    # ---- 3. 碎片率计算（JSON 输出解析）----
    log "[CMD] $ETCDCTL --endpoints=$EP endpoint status -w json $CERT_ARGS"
    JSON=$(ETCDCTL_API=3 "$ETCDCTL" --endpoints="$EP" endpoint status -w json $CERT_ARGS 2>/dev/null)
    TOTAL=$(echo "$JSON" | jq -r '.[0].status.dbTotalSize // .[0].Status.dbTotalSize // 0' 2>/dev/null)
    INUSE=$(echo "$JSON" | jq -r '.[0].status.dbTotalSizeInUse // .[0].Status.dbTotalSizeInUse // 0' 2>/dev/null)
    if [ -n "$TOTAL" ] && [ "$TOTAL" -gt 0 ] 2>/dev/null; then
        FRAG=$(( (TOTAL - INUSE) * 100 / TOTAL ))
        log "[INFO] db 总量: $((TOTAL/1024/1024))M, 在用: $((INUSE/1024/1024))M, 碎片率: ${FRAG}%"
        [ "$FRAG" -gt "$OVERALL_FRAG" ] && OVERALL_FRAG=$FRAG
    else
        log "[WARN] 碎片率解析失败（jq 缺失或输出异常），跳过该项"
    fi

    # ---- 4. 按需 defrag（逐 member，间隔等待）----
    if $DO_DEFRAG && [ "${FRAG:-0}" -gt "$FRAG_THRESHOLD" ]; then
        log "[CMD] $ETCDCTL --endpoints=$EP defrag $CERT_ARGS"
        if ETCDCTL_API=3 "$ETCDCTL" --endpoints="$EP" defrag $CERT_ARGS 2>&1 | sed 's/^/    /'; then
            log "[OK] member $M defrag 完成（期间该 member 写阻塞属预期）"
            log "[INFO] 等待 ${DEFRAG_INTERVAL}s 后处理下一个 member..."
            sleep "$DEFRAG_INTERVAL"
        else
            log "[FAIL] member $M defrag 失败，停止后续 member（安全第一）"
            FAILED=1
            break
        fi
    fi
done

# ----------------------------- 汇总 ------------------------------------------
log "===== 巡检汇总 ====="
log "最大碎片率: ${OVERALL_FRAG}%（阈值 ${FRAG_THRESHOLD}%）"

if [ "$FAILED" -ne 0 ]; then
    log "[FAIL] 巡检存在失败项，请人工检查"
    exit 1
elif [ "$OVERALL_FRAG" -gt "$FRAG_THRESHOLD" ]; then
    if $DO_DEFRAG; then
        log "[DONE] 碎片整理已执行，建议次日巡检确认碎片率回落"
    else
        log "[WARN] 碎片率超标！低峰期执行: bash $0 --defrag"
        exit 2
    fi
else
    log "[OK] etcd 健康，碎片率正常，无需 defrag"
fi
exit 0
