#!/bin/bash
# ============================================================================
# 集群节点 chrony 时间同步部署脚本(在"每台"节点上执行一次)
# 用法:   bash setup-chrony.sh        (要求同目录下有 chrony.conf)
# 作用:   安装 chrony → 备份旧配置 → 写入国内源配置 → 停用 timesyncd
#         → 重启 chrony → 自检同步状态
# 回滚:   cp /etc/chrony/chrony.conf.bak.* /etc/chrony/chrony.conf \
#         && systemctl restart chrony
# 批量:   for ip in <节点IP列表>; do
#             scp chrony.conf setup-chrony.sh root@$ip:/tmp/ntp-setup/
#             ssh root@$ip 'bash /tmp/ntp-setup/setup-chrony.sh'
#         done
# ============================================================================
set -e
cd "$(dirname "$0")"

echo "==> [1/7] 安装 chrony(Ubuntu, 走 cn.archive 国内镜像)..."
if dpkg -s chrony >/dev/null 2>&1; then
    echo "    chrony 已安装, 跳过"
else
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y chrony || { apt-get update && apt-get install -y chrony; }
fi

echo "==> [2/7] 备份原配置..."
if [ -f /etc/chrony/chrony.conf ]; then
    BAK="/etc/chrony/chrony.conf.bak.$(date +%Y%m%d-%H%M%S)"
    cp /etc/chrony/chrony.conf "$BAK"
    echo "    已备份到 $BAK"
else
    echo "    (无原配置)"
fi

echo "==> [3/7] 写入新配置(国内 NTP 直连 + makestep 快速校正)..."
cp chrony.conf /etc/chrony/chrony.conf

echo "==> [4/7] 禁用 VMware Tools 时间同步(关键! 见下方说明)..."
# ⚠ 血的教训(2026-08-20): 若 vmtools timesync 为 Enabled, chrony 每次步进校正后
# vmtoolsd 都会把时钟拉回 ESXi 宿主机时间(宿主机偏差可达数百秒), 形成拉锯,
# 导致节点时钟反复大幅跳动。必须让 chrony 独占时钟控制权!
if command -v vmware-toolbox-cmd >/dev/null 2>&1; then
    vmware-toolbox-cmd timesync disable >/dev/null 2>&1 \
        && echo "    已禁用: $(vmware-toolbox-cmd timesync status)" \
        || echo "    ⚠ 禁用失败, 请手动检查!"
else
    echo "    (非 VMware 虚机, 跳过)"
fi

echo "==> [5/7] 清理可能被污染的 driftfile(时钟拉锯会写入异常频率值)..."
rm -f /var/lib/chrony/chrony.drift && echo "    已清理(chrony 重启后重新学习)"

echo "==> [6/7] 停用 systemd-timesyncd(避免与 chrony 抢占时间同步)..."
systemctl disable --now systemd-timesyncd 2>/dev/null && echo "    已停用" || echo "    (本就未运行)"

echo "==> [7/7] 启动 chrony..."
systemctl enable chrony >/dev/null 2>&1
systemctl restart chrony

echo "==> 等待首次同步(10s)并自检..."
sleep 10
echo "--- chronyc sources (^* 开头 = 已同步的源) ---"
chronyc sources
echo "--- chronyc tracking 关键项 ---"
chronyc tracking | grep -E "Stratum|System time|Frequency|Reference" || true

if chronyc sources | grep -q '\^\*'; then
    echo "✅ 本节点 NTP 同步正常"
else
    echo "⚠️ 暂未锁定同步源(网络慢或刚启动), 请 30s 后执行 chronyc sources 复查"
    exit 1
fi
