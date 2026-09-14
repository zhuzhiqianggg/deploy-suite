#!/bin/bash
# ============================================================================
# nfs-data-sync.sh — NFS 迁移期数据同步（master01 → nfs01）
# ============================================================================
# 运行位置: master01（192.168.10.100）
# 用法:
#   bash nfs-data-sync.sh --full         # 全量同步（P2 首次，59G）
#   bash nfs-data-sync.sh --incremental  # 增量同步（P2 crontab 每 5 分钟）
#   bash nfs-data-sync.sh --final <dir>  # 最终切换同步（P4，带 --delete，可指定目录）
#   bash nfs-data-sync.sh --verify       # 差量校验（dry-run，只统计不传输）
# 传输参数:
#   -a  归档（权限/属主/时间戳/符号链接）
#   -H  硬链接保持
#   -A  ACL 保持
#   -X  xattr 保持（容器场景某些应用依赖）
#   --numeric-ids  按 uid/gid 数字同步（两端用户名可能不一致）
# 安全设计: --full/--incremental 不带 --delete（镜像侧只增不删，误删源时镜像有缓冲）
#           --final 带 --delete（切换时刻需要与源完全一致），仅限单业务目录
# 关联:     optimization-plan/10-nfs-ha-migration.md §4/§5/§6
# ============================================================================

set -u

SRC="/data/nfs/"
DST_HOST="192.168.10.131"          # 数据同步目标 = nfs01（DRBD Primary 侧）
DST="root@${DST_HOST}:/data/nfs/"
LOG_TAG="[nfs-sync]"

MODE="${1:---incremental}"
TARGET_DIR="${2:-}"

log() { echo "$(date '+%F %T') $LOG_TAG $*"; }

case "$MODE" in
    --full)
        log "全量同步开始（不带 --delete，首次大传输）"
        log "[CMD] rsync -aHAX --numeric-ids --info=progress2 $SRC $DST"
        rsync -aHAX --numeric-ids --info=progress2 "$SRC" "$DST"
        RC=$?
        ;;
    --incremental)
        log "增量同步开始（crontab 调用，静默模式）"
        log "[CMD] rsync -aHAX --numeric-ids --quiet $SRC $DST"
        rsync -aHAX --numeric-ids --quiet "$SRC" "$DST"
        RC=$?
        ;;
    --final)
        # 最终切换同步：带 --delete，可只同步指定业务目录
        if [ -n "$TARGET_DIR" ]; then
            SRC_ONE="/data/nfs/${TARGET_DIR#/}"        # 去掉开头斜杠防双斜杠
            DST_ONE="root@${DST_HOST}:/data/nfs/${TARGET_DIR#/}"
            [ -d "$SRC_ONE" ] || { log "[FATAL] 源目录不存在: $SRC_ONE"; exit 1; }
            log "最终切换同步（带 --delete）: $SRC_ONE"
            log "[CMD] rsync -aHAX --delete --numeric-ids $SRC_ONE/ $DST_ONE"
            rsync -aHAX --delete --numeric-ids "$SRC_ONE/" "$DST_ONE"
            RC=$?
        else
            log "最终全量切换同步（带 --delete）⚠️ 全目录模式"
            log "[CMD] rsync -aHAX --delete --numeric-ids $SRC $DST"
            rsync -aHAX --delete --numeric-ids "$SRC" "$DST"
            RC=$?
        fi
        # 切换同步后立即校验（dry-run 应无输出）
        if [ $RC -eq 0 ]; then
            log "[CMD] 校验: rsync --dry-run（无输出=完全一致）"
            if [ -n "${DST_ONE:-}" ]; then
                VERIFY_OUT=$(rsync -aHAX --delete --numeric-ids --dry-run "$SRC_ONE/" "$DST_ONE" 2>&1)
            else
                VERIFY_OUT=$(rsync -aHAX --delete --numeric-ids --dry-run "$SRC" "$DST" 2>&1)
            fi
            if [ -z "$VERIFY_OUT" ]; then
                log "[OK] 校验通过：源与镜像完全一致，可以执行切换"
            else
                log "[WARN] 校验仍有差量（同步期间有新写入）："
                echo "$VERIFY_OUT" | head -n 10 | sed 's/^/    /'
                log "如为持续写入的业务，属正常；再跑一次 --final 即可收敛"
                RC=2
            fi
        fi
        ;;
    --verify)
        log "差量校验（dry-run 只读）"
        log "[CMD] rsync -aHAX --numeric-ids --dry-run --itemize-changes $SRC $DST"
        OUT=$(rsync -aHAX --numeric-ids --dry-run --itemize-changes "$SRC" "$DST" 2>&1)
        COUNT=$(echo "$OUT" | grep -c "^<f\|^cd\|^>f" || true)
        log "差量文件数: $COUNT"
        [ "$COUNT" -gt 0 ] && echo "$OUT" | head -n 20 | sed 's/^/    /'
        RC=0
        ;;
    *)
        echo "用法: $0 --full | --incremental | --final [目录名] | --verify"
        exit 1
        ;;
esac

if [ "${RC:-1}" -eq 0 ]; then
    log "[OK] 同步成功"
elif [ "${RC:-1}" -eq 2 ]; then
    log "[DONE] 同步完成但存在活跃写入差量（见上方）"
else
    log "[FAIL] rsync 失败（exit=$RC），检查网络/ssh/磁盘"
fi
exit "${RC:-1}"
