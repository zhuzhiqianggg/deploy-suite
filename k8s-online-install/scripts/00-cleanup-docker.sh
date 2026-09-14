#!/usr/bin/env bash
#  彻底清理 Docker/containerd/sealos 残留
# ============================================================================
#
# 00 —— 彻底清理 Docker / containerd / sealos 残留
# 这个脚本是所有脚本中最关键的
# 不清理干净，sealos 会报: "Error: cluster status is not ClusterSuccess"
#
# 踩过的坑：
#   1. Docker 的 deb 包会在 /var/lib/systemd/deb-systemd-helper-masked/ mask 掉 containerd
#   2. /opt/containerd/bin/ 里有 Docker 留下的旧二进制
#   3. /var/lib/containers/storage/overlay/ 有 podman/cri-o 的 busy mount
#   4. /root/.sealos/default/Clusterfile 有上次失败的集群状态 ← 最关键！
#   5. sealos 自己装的 containerd 二进制会被残留文件掩盖
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"

log_step "00. 彻底清理所有容器运行时残留"

# ── 0. 安全检查 ──────────────────────────────────────────────────────────────
log_info "警告：本脚本会删除所有容器运行时和集群数据！"
log_warn "确认继续吗？(y/N)"
if [[ "${SKIP_CONFIRM:-}" != "1" ]]; then
    read -r ans
    [[ "$ans" =~ ^[Yy]$ ]] || { log_warn "已取消"; exit 0; }
fi

# ── 1. 停掉所有服务 ──────────────────────────────────────────────────────────
log_info "[1/7] 停掉所有容器相关服务..."
for svc in docker docker.socket containerd kubelet cri-dockerd registry image-cri-shim; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}.service"; then
        systemctl stop "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
        log_ok "已停止: $svc"
    fi
done
# 停所有 containerd 相关进程
pkill -f containerd 2>/dev/null || true
pkill -f kubelet 2>/dev/null || true
sleep 2

# ── 2. 卸载所有 deb 包 ───────────────────────────────────────────────────────
log_info "[2/7] 卸载所有容器相关 deb 包..."
PKGS_TO_PURGE=(
    docker-ce docker-ce-cli docker-ce-rootless-extras
    docker-buildx-plugin docker-compose-plugin
    containerd.io
    podman cri-o-runtime
    pigz   # Docker 装的依赖
)
for pkg in "${PKGS_TO_PURGE[@]}"; do
    if dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
        log_info "purge: $pkg"
        apt-get purge -y "$pkg" 2>&1 | tail -2 || true
    fi
done
apt-get autoremove --purge -y 2>&1 | tail -2 || true
log_ok "deb 包清理完成"

# ── 3. 卸载 busy overlay mounts ───────────────────────────────────────────────
log_info "[3/7] 卸载 busy overlay mounts..."
# podman 的 storage
while IFS= read -r mp; do
    [[ -z "$mp" ]] && continue
    log_info "umount -l: $mp"
    umount -l "$mp" 2>/dev/null || true
done < <(findmnt -nrn -t overlay 2>/dev/null | awk '{print $2}')

# Docker 的 overlay
for d in /var/lib/docker/overlay/*/merged /var/lib/containers/storage/overlay/*/merged; do
    [[ -d "$d" ]] && umount -l "$d" 2>/dev/null || true
done
log_ok "overlay mounts 清理完成"

# ── 4. 删除所有残留文件目录 ──────────────────────────────────────────────────
log_info "[4/7] 删除所有残留文件/目录..."
RESIDUE_PATHS=(
    # Docker
    /var/lib/docker /etc/docker /run/docker
    # containerd（Docker 装的 + sealos 装的）
    /var/lib/containerd /etc/containerd /run/containerd
    /opt/containerd
    /usr/bin/containerd /usr/bin/ctr
    /usr/sbin/containerd /usr/local/bin/containerd /usr/local/bin/ctr
    # podman/cri-o
    /var/lib/containers
    # sealos
    /root/.sealos /home/*/.sealos
    /var/lib/sealos
    # k8s
    /etc/kubernetes /var/lib/kubelet /var/lib/etcd
    /etc/cni /var/lib/cni /var/log/pods /var/log/containers
    # systemd masked files（Docker deb 包 mask 掉 containerd 的关键！）
    /var/lib/systemd/deb-systemd-helper-masked/containerd.service
    /var/lib/systemd/deb-systemd-helper-masked/docker.service
    /var/lib/systemd/deb-systemd-helper-enabled/multi-user.target.wants/containerd.service
    /var/lib/systemd/deb-systemd-helper-enabled/containerd.service.dsh-also
    # Sealos 装的 systemd services
    /etc/systemd/system/containerd.service
    /etc/systemd/system/kubelet.service
    /etc/systemd/system/registry.service
    /etc/systemd/system/image-cri-shim.service
    /etc/systemd/system/multi-user.target.wants/containerd.service
    /etc/systemd/system/multi-user.target.wants/kubelet.service
    /etc/systemd/system/multi-user.target.wants/registry.service
    /etc/systemd/system/multi-user.target.wants/image-cri-shim.service
    # 其他
    /etc/systemd/system/kubelet.service.d
)
for p in "${RESIDUE_PATHS[@]}"; do
    # 通配符
    for real in $p; do
        [[ -e "$real" ]] || continue
        rm -rf "$real" 2>/dev/null && log_ok "删除: $real" || true
    done
done

# ── 5. containerd / Docker 的 systemd unit 原始文件 ────────────────────────────
log_info "[5/7] 清理 systemd unit 文件..."
for unit in containerd.service docker.service docker.socket cri-docker.service kubelet.service; do
    for dir in /lib/systemd/system /usr/lib/systemd/system; do
        [[ -f "${dir}/${unit}" ]] && rm -f "${dir}/${unit}" && log_info "删除: ${dir}/${unit}"
    done
done
systemctl daemon-reload
systemctl reset-failed 2>/dev/null || true
log_ok "systemd 清理完成"

# ── 6. dpkg info 残留 ────────────────────────────────────────────────────────
log_info "[6/7] 清理 dpkg info 残留..."
find /var/lib/dpkg/info -name 'containerd.io.*' -delete 2>/dev/null || true
find /var/lib/dpkg/info -name 'docker-ce*' -delete 2>/dev/null || true
find /var/lib/dpkg/info -name 'docker-compose*' -delete 2>/dev/null || true
find /var/lib/dpkg/info -name 'docker-buildx*' -delete 2>/dev/null || true

# ── 7. 验证干净 ───────────────────────────────────────────────────────────────
log_info "[7/7] 验证系统已干净..."
IS_CLEAN=true

# 没有 containerd 二进制
if command -v containerd &>/dev/null; then
    log_warn "containerd 二进制仍存在: $(which containerd)"
    IS_CLEAN=false
fi
# 没有 docker 二进制
if command -v docker &>/dev/null; then
    log_warn "docker 二进制仍存在: $(which docker)"
    IS_CLEAN=false
fi
# 没有 containerd.io / docker-ce deb
for pkg in containerd.io docker-ce; do
    if dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
        log_warn "deb 包仍存在: $pkg"
        IS_CLEAN=false
    fi
done
# 没有 containerd 进程
if pgrep -x containerd &>/dev/null; then
    log_warn "containerd 进程仍在运行"
    IS_CLEAN=false
fi
# 没有 sealos 残留状态
if [[ -d /root/.sealos ]]; then
    log_warn "/root/.sealos 目录仍存在"
    IS_CLEAN=false
fi

if [[ "$IS_CLEAN" == true ]]; then
    log_ok "✅ 系统已完全干净，可以继续部署"
else
    log_warn "⚠️ 有残留，请手动检查后再继续"
    log_info "可以运行: sudo find / -name containerd -o -name docker 2>/dev/null | grep -v proc"
    exit 1
fi
