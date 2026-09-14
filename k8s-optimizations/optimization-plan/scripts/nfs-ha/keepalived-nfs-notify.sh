#!/bin/bash
# ============================================================================
# keepalived-nfs-notify.sh — NFS-HA 状态切换动作脚本（keepalived notify 调用）
# ============================================================================
# 部署位置: /etc/keepalived/nfs-notify.sh（两台 NFS 节点相同）
# 调用方:   keepalived notify，参数 $1=GROUP|INSTANCE $2=实例名 $3=MASTER|BACKUP|FAULT
# 动作语义:
#   MASTER: 本机接管服务 → DRBD 提升 Primary → 挂载 → 启动 NFS
#   BACKUP/FAULT: 本机让出服务 → 停 NFS → 卸载 → DRBD 降级 Secondary
# 幂等性:   每步先查状态再动作（重复调用无害）
# 关键约束: 停 NFS 用 SIGTERM 优雅退出（给客户端 grace 宽限期），不用 kill -9
# 日志:     全部动作写入 /var/log/nfs-ha-notify.log（排障唯一依据，见 FAQ）
# 关联:     optimization-plan/10-nfs-ha-migration.md §3.6
# ============================================================================

DRBD_RES="nfs"
DRBD_DEV="/dev/drbd0"
MOUNT_POINT="/data/nfs"
NFS_SVC="nfs-kernel-server"
LOG="/var/log/nfs-ha-notify.log"

log() { echo "[$(date '+%F %T')] [$$] $*" >> "$LOG"; }

# DRBD 角色判断（DRBD 9.3.x /proc/drbd 无状态行，必须用 drbdadm status）
is_primary() {
    drbdadm status "$DRBD_RES" 2>/dev/null | head -n 1 | grep -q "role:Primary"
}

STATE="${3:-}"
log "=== notify 触发: state=$STATE (instance=${2:-}) ==="

become_master() {
    log "→ 接管流程开始（提升 DRBD Primary）"
    # 1. DRBD 提升（若已是 Primary 则跳过）
    if ! is_primary; then
        log "[CMD] drbdadm primary $DRBD_RES"
        if drbdadm primary "$DRBD_RES" 2>>"$LOG"; then
            log "[OK] DRBD 已提升 Primary"
        else
            log "[FATAL] DRBD 提升失败（对端还是 Primary？脑裂？）——放弃接管"
            return 1
        fi
    else
        log "[SKIP] 已是 Primary"
    fi

    # 2. 挂载（幂等）
    if ! mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        log "[CMD] mount $DRBD_DEV $MOUNT_POINT"
        if mount "$DRBD_DEV" "$MOUNT_POINT" 2>>"$LOG"; then
            log "[OK] 已挂载 $MOUNT_POINT"
        else
            log "[FATAL] 挂载失败——数据无法提供，放弃接管"
            return 1
        fi
    else
        log "[SKIP] 已挂载"
    fi

    # 3. 启动 NFS（幂等）
    if ! pgrep -x nfsd >/dev/null; then
        log "[CMD] systemctl start $NFS_SVC"
        if systemctl start "$NFS_SVC" 2>>"$LOG"; then
            log "[OK] NFS 服务已启动——本机正式提供服务"
        else
            log "[FATAL] NFS 启动失败"
            return 1
        fi
    else
        log "[SKIP] NFS 已在运行"
    fi
    log "→ 接管流程完成"
}

become_standby() {
    log "→ 让出流程开始（降级为备节点）"
    # 1. 优雅停 NFS（给客户端 grace 宽限）
    if pgrep -x nfsd >/dev/null; then
        log "[CMD] systemctl stop $NFS_SVC"
        systemctl stop "$NFS_SVC" 2>>"$LOG" && log "[OK] NFS 已停止" || log "[WARN] NFS 停止异常（继续流程）"
    else
        log "[SKIP] NFS 未运行"
    fi

    # 2. 卸载（可能有客户端 lsof 残留，重试 3 次）
    if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        for i in 1 2 3; do
            log "[CMD] umount $MOUNT_POINT (尝试 $i/3)"
            umount "$MOUNT_POINT" 2>>"$LOG" && break
            sleep 1
        done
        mountpoint -q "$MOUNT_POINT" 2>/dev/null && log "[WARN] 卸载失败（有进程占用？）" || log "[OK] 已卸载"
    else
        log "[SKIP] 未挂载"
    fi

    # 3. DRBD 降级（幂等；失败不打断——降级失败会在对端 promote 时暴露）
    if is_primary; then
        log "[CMD] drbdadm secondary $DRBD_RES"
        drbdadm secondary "$DRBD_RES" 2>>"$LOG" && log "[OK] DRBD 已降级 Secondary" || log "[WARN] DRBD 降级失败"
    else
        log "[SKIP] 已是 Secondary"
    fi
    log "→ 让出流程完成"
}

case "$STATE" in
    MASTER)  become_master  ;;
    BACKUP|FAULT) become_standby ;;
    STOP)    become_standby ;;
    *)       log "[WARN] 未知状态: $STATE" ;;
esac

exit 0
