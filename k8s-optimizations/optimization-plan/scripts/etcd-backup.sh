#!/bin/bash
# ============================================================================
# etcd-backup.sh — etcd 每日快照备份脚本
# ============================================================================
# 用途:    etcd 一致性快照 + 完整性校验 + 过期清理
# 用法:    bash etcd-backup.sh            （手工/crontab 均可）
# 部署:    install -m 750 etcd-backup.sh /root/scripts/etcd-backup.sh
# crontab: 0 2 * * * /root/scripts/etcd-backup.sh >> /var/log/etcd-backup.log 2>&1
# 关联:    optimization-plan/01-etcd-backup.md
# 约定:    脚本 echo 所有执行命令（便于审计与学习）
# 退出码:  0=成功  1=快照失败  2=校验失败  3=清理失败
# ============================================================================

set -u  # 引用未定义变量即报错（不用 -e：需按阶段精细控制错误处理）

# ----------------------------- 可调参数 -------------------------------------
BACKUP_DIR="/data/etcd-backup"                # 备份目录（建议 NFS/独立盘）
RETAIN_DAYS=7                                 # 快照保留天数
ETCDCTL="${ETCDCTL:-/usr/bin/etcdctl}"        # etcdctl 路径（可用环境变量覆盖）
ENDPOINT="https://127.0.0.1:2379"
CERT_DIR="/etc/kubernetes/pki/etcd"
# ----------------------------------------------------------------------------
CERT_ARGS="--cacert=${CERT_DIR}/ca.crt --cert=${CERT_DIR}/server.crt --key=${CERT_DIR}/server.key"

log()  { echo "[$(date '+%F %T')] $*"; }
die()  { log "[FATAL] $*"; exit "${2:-1}"; }

# ----------------------------- 前置检查 -------------------------------------
[ -x "$ETCDCTL" ] || ETCDCTL="$(command -v etcdctl || true)"
[ -n "$ETCDCTL" ] || die "etcdctl 未找到，请安装或设置 ETCDCTL 环境变量" 1
for f in "${CERT_DIR}/ca.crt" "${CERT_DIR}/server.crt" "${CERT_DIR}/server.key"; do
    [ -f "$f" ] || die "证书缺失: $f（路径以 /etc/kubernetes/manifests/etcd.yaml 实际挂载为准）" 1
done

mkdir -p "$BACKUP_DIR" || die "备份目录创建失败: $BACKUP_DIR" 1
chmod 700 "$BACKUP_DIR"

# ----------------------------- 1. 快照 --------------------------------------
SNAP_FILE="${BACKUP_DIR}/snap-$(date +%Y%m%d-%H%M%S).db"

log "===== [1/3] 执行 etcd 快照 ====="
log "[CMD] ETCDCTL_API=3 $ETCDCTL snapshot save $SNAP_FILE --endpoints=$ENDPOINT $CERT_ARGS"
if ETCDCTL_API=3 "$ETCDCTL" snapshot save "$SNAP_FILE" \
        --endpoints="$ENDPOINT" $CERT_ARGS 2>&1 | sed 's/^/    /'; then
    [ -s "$SNAP_FILE" ] || die "快照文件为空: $SNAP_FILE" 1
    SIZE=$(du -h "$SNAP_FILE" | awk '{print $1}')
    log "[OK] 快照完成: $SNAP_FILE ($SIZE)"
else
    die "快照命令执行失败" 1
fi

# ----------------------------- 2. 校验 --------------------------------------
log "===== [2/3] 校验快照完整性 ====="
log "[CMD] $ETCDCTL snapshot status $SNAP_FILE -w table"
if "$ETCDCTL" snapshot status "$SNAP_FILE" -w table 2>&1 | sed 's/^/    /'; then
    log "[OK] 快照校验通过（坏快照 = 没备份，此步不可省）"
else
    rm -f "$SNAP_FILE"                       # 删除坏快照，避免占用保留名额
    die "快照校验失败，已删除坏文件" 2
fi

# ----------------------------- 3. 清理过期 ----------------------------------
log "===== [3/3] 清理 ${RETAIN_DAYS} 天前的旧快照 ====="
log "[CMD] find $BACKUP_DIR -name 'snap-*.db' -mtime +$RETAIN_DAYS -delete"
if find "$BACKUP_DIR" -name 'snap-*.db' -mtime +"$RETAIN_DAYS" -delete 2>&1; then
    COUNT=$(find "$BACKUP_DIR" -name 'snap-*.db' | wc -l)
    log "[OK] 清理完成，当前保留 ${COUNT} 份快照"
else
    die "过期快照清理失败（不影响本次备份）" 3
fi

# ----------------------------- 汇总 ------------------------------------------
log "===== 备份链路正常: $SNAP_FILE ($SIZE) ====="
exit 0
