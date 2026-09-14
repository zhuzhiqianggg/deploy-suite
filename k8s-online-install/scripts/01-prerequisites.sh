#!/usr/bin/env bash
# ============================================================================
# 01 —— 系统前置准备（Swap / 内核 / 依赖 / 时间同步 / 主机名）
# 注：命令补全/别名在 08-usability.sh 配置（此时 kubectl 还没装）
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.env"
source "${SCRIPT_DIR}/../common.sh"

log_step "01. 系统环境前置准备"

# 架构检测
ARCH="$(detect_arch)"
log_info "检测架构: $ARCH"

# ── 1. 主机名和 hosts ────────────────────────────────────────────────────────
log_info "[1/8] 设置主机名: $CLUSTER_NAME"
hostnamectl set-hostname "$CLUSTER_NAME" 2>/dev/null || true
# Ubuntu 风格：把 127.0.1.1 行和真实 IP 行都指向新主机名
if ! grep -qE "(\s|^)${CLUSTER_NAME}(\s|$)" /etc/hosts; then
    log_info "更新 /etc/hosts..."
    if grep -q "^127.0.1.1" /etc/hosts; then
        sed -i "s/^127.0.1.1.*/127.0.1.1 ${CLUSTER_NAME}/" /etc/hosts
    else
        echo "127.0.1.1 ${CLUSTER_NAME}" >> /etc/hosts
    fi
    echo "${NODE_IP} ${CLUSTER_NAME}" >> /etc/hosts
fi
log_ok "主机名: $(hostname)"

# ── 2. 关闭 Swap ──────────────────────────────────────────────────────────────
log_info "[2/8] 关闭 Swap..."
swapoff -a 2>/dev/null || true
# 注释掉 /etc/fstab 中的 swap
sed -i.bak '/\sswap\s/s/^\(.*\)$/# \1/g' /etc/fstab 2>/dev/null || true
SWAP_SIZE=$(free -m | awk '/Swap:/{print $2}')
if [[ "$SWAP_SIZE" -eq 0 ]]; then
    log_ok "Swap 已禁用 (Swap: 0B)"
else
    log_warn "Swap 未完全禁用 (${SWAP_SIZE}MB) —— 可能需要重启"
fi

# ── 3. 关闭防火墙 ────────────────────────────────────────────────────────────
log_info "[3/8] 关闭 ufw 防火墙..."
ufw disable 2>/dev/null || true
systemctl stop ufw 2>/dev/null || true
systemctl disable ufw 2>/dev/null || true
log_ok "防火墙已禁用"

# ── 4. 内核模块 ──────────────────────────────────────────────────────────────
log_info "[4/8] 加载 K8s 需要的内核模块..."
tee /etc/modules-load.d/k8s-modules.conf <<EOF
overlay
br_netfilter
ip_vs
ip_vs_rr
ip_vs_wrr
ip_vs_sh
nf_conntrack
EOF
for mod in overlay br_netfilter ip_vs ip_vs_rr ip_vs_wrr ip_vs_sh nf_conntrack; do
    modprobe "$mod" 2>/dev/null || true
done
# 验证
for mod in overlay br_netfilter ip_vs; do
    if lsmod | grep -q "^${mod} "; then
        log_ok "模块 $mod 已加载"
    else
        log_warn "模块 $mod 未加载（可能需要重启）"
    fi
done

# ── 5. 内核参数 ──────────────────────────────────────────────────────────────
log_info "[5/8] 配置内核参数..."
tee /etc/sysctl.d/99-kubernetes.conf <<EOF
# K8s 网络必需
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1

# 网络性能
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_time = 600

# socket 缓冲区（NFS 大块读写 / 高吞吐场景）
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# conntrack 优化（高并发）
net.netfilter.nf_conntrack_max = 2621440
net.netfilter.nf_conntrack_buckets = 655360
net.ipv4.vs.conn_reuse_mode = 0
net.ipv4.vs.conntrack = 1

# 文件句柄 / inotify（大量 Pod 时 fsnotify 需要）
fs.file-max = 2097152
fs.inotify.max_user_watches = 1048576
fs.inotify.max_user_instances = 8192
vm.max_map_count = 2147483642

# 内存/交换
vm.swappiness = 0
vm.min_free_kbytes = 1048576
vm.watermark_scale_factor = 100
# ES/数据库必需：内存超售允许 + OOM 不 panic（选 kill 进程）
vm.overcommit_memory = 1
vm.panic_on_oom = 0

# 进程数上限（大规模容器场景默认 32768 不够）
kernel.pid_max = 4194304
EOF
sysctl --system >/dev/null 2>&1 || true
# 验证关键参数
for kv in "net.ipv4.ip_forward" "net.bridge.bridge-nf-call-iptables" "fs.inotify.max_user_watches"; do
    val=$(sysctl -n "$kv" 2>/dev/null || echo "N/A")
    log_info "  $kv = $val"
done
log_ok "内核参数已应用"

# ── 6. 安装系统依赖 ──────────────────────────────────────────────────────────
log_info "[6/8] 安装系统依赖..."
apt-get update -qq
apt-get install -y -qq \
    curl wget socat conntrack openssl ipset ipvsadm \
    chrony tar ca-certificates gnupg lsb-release jq dnsutils \
    python3-yaml \
    nfs-common nfs-kernel-server rpcbind \
    bash-completion \
    lvm2 xfsprogs xfsdump e2fsprogs 2>&1 | tail -3
log_ok "依赖安装完成（含 python3-yaml —— 04 调优脚本依赖）"

# ── 7. 时间同步 ──────────────────────────────────────────────────────────────
log_info "[7/8] 配置时间同步..."
timedatectl set-timezone Asia/Shanghai
systemctl enable --now chrony 2>/dev/null || systemctl enable --now chronyd 2>/dev/null || true
sleep 2
if chronyc tracking 2>/dev/null | grep -q "Reference ID"; then
    log_ok "chrony 时间同步正常"
else
    log_warn "chrony 可能有问题: $(chronyc tracking 2>&1 | head -3)"
fi
log_info "当前时间: $(date)"

# ── 8. 资源/端口检查 ─────────────────────────────────────────────────────────
log_info "[8/8] 端口/资源检查..."
log_info "IP 地址: $NODE_IP"
log_info "主机名: $(hostname)"
log_info "CPU 核数: $(nproc)"
log_info "总内存: $(detect_total_mem_gb) GB"
log_info "系统预留内存（自动计算）: $(calc_system_reserved)"

# K8s 常用端口
for port in 6443 2379 2380 10250 10256 10259 30000; do
    if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
        log_warn "端口 $port 已被占用！"
        ss -tlnp | grep ":${port} "
    fi
done

log_step "✅ 系统前置准备完成"
log_info "命令补全/别名/metrics-server 在 [08] 脚本配置（集群装好后才有意义）"
