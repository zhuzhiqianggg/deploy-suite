#!/bin/bash
# ============================================================================
# keepalived-nfs-check.sh — NFS-HA 节点健康检查（keepalived track_script 调用）
# ============================================================================
# 部署位置: /etc/keepalived/nfs-check.sh（两台 NFS 节点相同）
# 调用方:   keepalived vrrp_script，每 2 秒一次
# 判定逻辑（主动-被动集群标准模式）:
#   1. 本机无 VIP → BACKUP 合法状态 → exit 0（不判死）
#      （否则 BACKUP 节点必然缺 Primary/挂载/NFS 三件套，会被误判 FAULT
#        —— 部署当天踩过的坑，见 10-nfs-ha-migration.md 实施记录）
#   2. 本机有 VIP → 严格检查三件套：
#      DRBD Primary + /data/nfs 已挂载 + nfsd 进程存活
#      任一不满足 → 退出非零 → 连续 2 次失败 → keepalived 撤 VIP → 漂到对端
# 注意:     本脚本只做"判死"，修复动作是 notify 脚本的职责
# 关联:     optimization-plan/10-nfs-ha-migration.md §3.6
# ============================================================================

VIP="192.168.10.130"
DRBD_RES="nfs"
MOUNT_POINT="/data/nfs"

# 1. 无 VIP = BACKUP 状态，本节点不需要提供服务 → 直接通过
if ! ip -4 addr show | grep -q "${VIP}/"; then
    exit 0
fi

# --- 以下检查仅在持有 VIP（MASTER）时执行 ---

# 2. DRBD 资源：本侧必须是 Primary
#    ⚠️ DRBD 9.3.x 的 /proc/drbd 不再输出资源状态行（只有 version 头），
#    角色判断必须用 drbdadm status（第一行是本机 role）
drbdadm status "$DRBD_RES" 2>/dev/null | head -n 1 | grep -q "role:Primary" || exit 1

# 3. 挂载点存在且为 drbd 设备
mountpoint -q "$MOUNT_POINT" 2>/dev/null || exit 1
mount | grep -q "drbd0 on $MOUNT_POINT" || exit 1

# 4. NFS 服务存活（rpc.nfsd 进程在）
pgrep -x "nfsd" >/dev/null 2>&1 || exit 1

exit 0
