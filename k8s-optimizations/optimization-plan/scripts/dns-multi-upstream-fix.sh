#!/bin/bash
# ============================================================================
# dns-multi-upstream-fix.sh — 节点 DNS 多上游批量修复
# ============================================================================
# 用途:    批量将所有节点的 systemd-resolved 单上游改为多上游（容错+择优）
#          并检查 netplan 是否有覆盖配置
# 用法:    在 master01（可免密 ssh 全部节点）上执行: bash dns-multi-upstream-fix.sh
# 参数:    --check  仅巡检不修改（先跑这个看现状）
# 关联:    optimization-plan/02-dns-optimization.md
# 行为:    本机直接执行、其余节点 ssh 执行（沿用 ntp-sync-manager.sh 的 is_local 约定）
# 幂等:    已是目标配置则跳过；修改前自动备份
# 退出码:  0=全部成功  1=存在失败节点
# ============================================================================

set -u

# ----------------------------- 可调参数 -------------------------------------
NODES="192.168.10.100 192.168.10.104 192.168.10.105 \
       192.168.10.101 192.168.10.102 192.168.10.103 192.168.10.106 192.168.10.107"
LOCAL_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1)
DNS_LINE="DNS=223.5.5.5 114.114.114.114 119.29.29.29"    # 目标多上游（生产改内网 DNS 优先）
TEST_DOMAIN="swr.cn-east-3.myhuaweicloud.com"
CHECK_ONLY=false
[ "${1:-}" = "--check" ] && CHECK_ONLY=true
# ----------------------------------------------------------------------------

log() { echo "[$(date '+%F %T')] $*"; }

# 单节点修复函数（在目标节点上执行，支持本机/远端两种调用方式）
fix_node() {
    echo "----- 节点: $1 -----"

    # --- 1. 备份（幂等：每天最多一份）---
    BAK="/etc/systemd/resolved.conf.bak-$(date +%Y%m%d)"
    [ -f "$BAK" ] || { echo "[CMD] cp /etc/systemd/resolved.conf $BAK"; cp /etc/systemd/resolved.conf "$BAK"; }

    # --- 2. 检查是否已是目标配置 ---
    if grep -q "^${DNS_LINE}$" /etc/systemd/resolved.conf; then
        echo "[SKIP] 已是目标配置"
    elif $CHECK_ONLY; then
        echo "[CHECK] 当前上游: $(grep -E '^#\s*DNS=|^DNS=' /etc/systemd/resolved.conf | head -n 1)"
    else
        # --- 3. 修改 DNS= 行（兼容注释状态 #DNS= 与未写两种情况）---
        echo "[CMD] sed -i 's/^#\?DNS=.*/${DNS_LINE}/' /etc/systemd/resolved.conf"
        sed -i "s/^#\?DNS=.*/${DNS_LINE}/" /etc/systemd/resolved.conf
        # resolved.conf 里原本没有 DNS= 行时（被 sed 落空）追加到 [Resolve] 段后
        grep -q "^${DNS_LINE}$" /etc/systemd/resolved.conf || {
            echo "[CMD] 追加 ${DNS_LINE} 到 [Resolve] 段"
            sed -i "/^\[Resolve\]/a ${DNS_LINE}" /etc/systemd/resolved.conf
        }
        echo "[OK] resolved.conf 已更新: $(grep '^DNS=' /etc/systemd/resolved.conf)"

        # --- 4. netplan 覆盖检查（网卡级 nameservers 会压过全局 DNS=）---
        if grep -rA 2 "nameservers:" /etc/netplan/*.yaml 2>/dev/null | grep -q "addresses"; then
            echo "[WARN] netplan 存在网卡级 DNS 配置（会覆盖全局），请手工核对:"
            grep -rB 2 -A 3 "nameservers:" /etc/netplan/*.yaml | sed 's/^/    /'
        fi

        # --- 5. 重启服务 ---
        echo "[CMD] systemctl restart systemd-resolved"
        systemctl restart systemd-resolved
        sleep 2
        systemctl is-active systemd-resolved >/dev/null || { echo "[FAIL] systemd-resolved 启动失败"; return 1; }
    fi

    # --- 6. 验证：上游列表 + 10 次解析成功率 ---
    echo "[CMD] resolvectl status | 提取 DNS Servers"
    resolvectl status 2>/dev/null | grep "DNS Servers" | head -n 2 | sed 's/^/    /'
    OK=0
    for i in $(seq 1 10); do
        dig +time=2 +tries=1 @127.0.0.53 "$TEST_DOMAIN" +short >/dev/null 2>&1 && OK=$((OK+1))
    done
    echo "[INFO] stub 解析成功率: ${OK}/10"
    [ "$OK" -ge 9 ] || { echo "[WARN] 成功率偏低，关注上游质量"; return 2; }
    return 0
}

log "===== DNS 多上游批量修复开始（check-only=${CHECK_ONLY}） ====="
log "目标配置: ${DNS_LINE}"

FAIL_NODES=""
for NODE in $NODES; do
    if [ "$NODE" = "$LOCAL_IP" ]; then
        # 本机：直接执行
        fix_node "$NODE(local)" || FAIL_NODES="$FAIL_NODES $NODE"
    else
        # 远端：脚本函数体通过 ssh 执行（传函数+调用）
        if ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=no "root@${NODE}" \
            "$(declare -f fix_node); DNS_LINE='${DNS_LINE}'; TEST_DOMAIN='${TEST_DOMAIN}'; CHECK_ONLY=${CHECK_ONLY}; fix_node '${NODE}'"; then
            :
        else
            FAIL_NODES="$FAIL_NODES $NODE"
        fi
    fi
done

log "===== 完成 ====="
if [ -n "$FAIL_NODES" ]; then
    log "[WARN] 以下节点需人工复核: $FAIL_NODES"
    exit 1
fi
log "[OK] 全部节点处理完毕（观察 48h 镜像 pull 报错率，见文档 02 验证章节）"
exit 0
