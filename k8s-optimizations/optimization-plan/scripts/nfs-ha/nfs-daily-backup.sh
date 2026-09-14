#!/bin/bash
# ============================================================================
# nfs-daily-backup.sh — NFS 每日备份（硬链接轮转，P5 后上线，误删保护核心）
# ============================================================================
# 运行位置: master01（退役后的旧 NFS 节点，转为备份机）
# 用法:    bash nfs-daily-backup.sh     （crontab 每日 03:00）
# 原理（学习点）:
#   rsync --link-dest 指向上次备份目录：未变化的文件在新备份中以硬链接出现
#   （零空间占用），只有变化的文件才真正拷贝。效果 = 每天一个"全量视图"，
#   实际磁盘只存增量。误删恢复 = 直接从任意历史目录 cp 回来。
# 保留策略: RETAIN_DAYS 天，超期自动删除
# 拉取源:   NFS-HA 的 VIP（无论当前谁是 Primary 都能拉到数据）
# 关联:     optimization-plan/10-nfs-ha-migration.md §7
# 退出码:   0=成功  1=拉取失败  2=磁盘空间不足
# ============================================================================

set -u

# ----------------------------- 可调参数 -------------------------------------
SRC_HOST="192.168.10.130"              # VIP（nfs-ha.lianan.local）
SRC_PATH="/data/nfs/"
BACKUP_ROOT="/data/nfs-backup"
RETAIN_DAYS=7
MIN_FREE_GB=10                          # 备份前检查 master01 本地剩余空间
# ----------------------------------------------------------------------------

log() { echo "[$(date '+%F %T')] [nfs-backup] $*"; }
TODAY=$(date +%Y%m%d)
TODAY_DIR="${BACKUP_ROOT}/${TODAY}"
LAST_DIR="${BACKUP_ROOT}/latest"

# 1. 磁盘空间预检（备份失败事小，撑爆系统盘事大）
FREE_GB=$(df --output=avail -BG /data | tail -n 1 | tr -dc '0-9')
if [ "${FREE_GB:-0}" -lt "$MIN_FREE_GB" ]; then
    log "[FAIL] 磁盘剩余 ${FREE_GB}G 低于阈值 ${MIN_FREE_GB}G，跳过备份（防撑爆）"
    exit 2
fi

# 2. 拉取备份（--link-dest 硬链接轮转；--delete 保证每日视图与源一致）
mkdir -p "$TODAY_DIR"
LINK_ARG=""
[ -d "$LAST_DIR" ] && LINK_ARG="--link-dest=${LAST_DIR}/"

log "===== 每日备份开始: ${SRC_HOST}:${SRC_PATH} → ${TODAY_DIR} ====="
log "[CMD] rsync -aHAX --delete --numeric-ids ${LINK_ARG} root@${SRC_HOST}:${SRC_PATH} ${TODAY_DIR}/"
if rsync -aHAX --delete --numeric-ids $LINK_ARG "root@${SRC_HOST}:${SRC_PATH}" "${TODAY_DIR}/"; then
    log "[OK] 备份完成"
else
    log "[FAIL] rsync 拉取失败（NFS-HA 不可达？网络？）"
    exit 1
fi

# 3. 更新 latest 指针（指向今天）
ln -sfn "$TODAY_DIR" "$LAST_DIR"

# 4. 统计今日实际占用（硬链接机制下，第二天起只有增量）
SIZE=$(du -sh "$TODAY_DIR" | awk '{print $1}')
log "[INFO] 今日备份视图大小: $SIZE（含硬链接共享部分）"

# 5. 清理过期备份
log "[CMD] find $BACKUP_ROOT -maxdepth 1 -type d -name '20*' -mtime +$RETAIN_DAYS -exec rm -rf {} +"
find "$BACKUP_ROOT" -maxdepth 1 -type d -name "20*" -mtime +"$RETAIN_DAYS" -exec rm -rf {} + 2>/dev/null
REMAIN=$(ls -1 "$BACKUP_ROOT" | grep -c "^20" || true)
log "[OK] 保留 ${REMAIN} 份历史备份（策略: ${RETAIN_DAYS} 天）"
log "===== 备份链路正常 ====="
exit 0
