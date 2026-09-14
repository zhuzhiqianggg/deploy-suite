#!/usr/bin/env bash
# ============================================================================
# 03 —— NFS 存储类（含服务端调优）
# 单机场景：本机既是 NFS server（nfs-kernel-server 导出 /data/nfs）
#           又是 provisioner client
#
# 优化点：
#   1. nfsd 线程数调优（默认 8 → NFSD_THREADS，NFS 并发卡顿的常见根因）
#   2. StorageClass 加 mountOptions（rsize/wsize=1MiB、hard、nfsvers=3——v4 idmap 会坑 mysqld）
#   3. 默认 StorageClass 去重（防止 local-path 和 nfs-client 同时是 default）
#   4. 自适应：已用 Helm 装过 provisioner 时走 patch 模式，不重复部署
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.env"
source "${SCRIPT_DIR}/../common.sh"

log_step "03. NFS 存储类 (根目录: ${NFS_DIR})"

ARCH="$(detect_arch)"

# ── 1. 创建 NFS 根目录 + 所有 DB 子目录 ────────────────────────────────────────
log_info "[1/6] 创建 NFS 根目录结构..."
mkdir -p \
    "${NFS_DIR}" \
    "${NFS_MYSQL_DIR}" \
    "${NFS_REDIS_DIR}" \
    "${NFS_ES_DIR}/node1" \
    "${NFS_ES_DIR}/node2" \
    "${NFS_ES_DIR}/node3" \
    "${NFS_KAFKA_DIR}" \
    "${NFS_DORIS_DIR}"

# 所有目录权限：容器 UID/GID 运行都能写
chown -R nobody:nogroup "${NFS_DIR}"
chmod -R 755 "${NFS_DIR}"
# Doris 需要更高权限（BE 进程 UID 不确定）
chmod 777 "${NFS_DORIS_DIR}"

# etcd 快照目录（04 脚本的 cron 备份用）
mkdir -p "${NFS_DIR}/backup/etcd" 2>/dev/null || true

echo ""
log_ok "NFS 目录结构:"
find "${NFS_DIR}" -maxdepth 3 -type d | sort
echo ""

# ── 2. 装 NFS server + 客户端工具 + 服务端调优 ────────────────────────────────
# K8s 节点挂 NFS PVC 必须有客户端工具：Ubuntu 是 nfs-common（RHEL 系叫 nfs-utils），
# 本机同时是 server（nfs-kernel-server），两者都装；扩容的 worker 节点也要装 nfs-common
log_info "[2/6] 安装 NFS server/客户端工具并调优..."
NEED_NFS_INSTALL=0
dpkg -l nfs-kernel-server 2>/dev/null | grep -q "^ii" || NEED_NFS_INSTALL=1
dpkg -l nfs-common 2>/dev/null | grep -q "^ii" || NEED_NFS_INSTALL=1
if (( NEED_NFS_INSTALL )); then
    apt-get update -qq && apt-get install -y -qq nfs-kernel-server nfs-common rpcbind 2>&1 | tail -3
fi
systemctl enable rpcbind nfs-kernel-server >/dev/null 2>&1
systemctl start rpcbind nfs-kernel-server >/dev/null 2>&1

# nfsd 线程数（Ubuntu 22.04 走 /etc/nfs.conf，同时兼容 /etc/default 的老配置）
if grep -qE "^\[nfsd\]" /etc/nfs.conf 2>/dev/null; then
    sed -i "/^\[nfsd\]/,/^\[/{s/^#\?threads.*/threads=${NFSD_THREADS}/; t; s/^threads.*/threads=${NFSD_THREADS}/}" /etc/nfs.conf 2>/dev/null || true
    if ! grep -qE "^threads=${NFSD_THREADS}" /etc/nfs.conf; then
        sed -i "/^\[nfsd\]/a threads=${NFSD_THREADS}" /etc/nfs.conf
    fi
else
    echo "[nfsd]" >> /etc/nfs.conf
    echo "threads=${NFSD_THREADS}" >> /etc/nfs.conf
fi
sed -i "s/^RPCNFSDCOUNT=.*/RPCNFSDCOUNT=${NFSD_THREADS}/" /etc/default/nfs-kernel-server 2>/dev/null || true
log_ok "nfsd 线程数: ${NFSD_THREADS}（cat /proc/fs/nfsd/threads 可查实际值）"

systemctl enable rpcbind nfs-kernel-server

# 导出 /data/nfs 整个根目录，所有子服务自动继承
NFS_EXPORT_LINE="${NFS_DIR} *(rw,sync,no_subtree_check,no_root_squash,fsid=1)"
if ! grep -qF "${NFS_DIR} " /etc/exports 2>/dev/null; then
    echo "$NFS_EXPORT_LINE" >> /etc/exports
    log_ok "写入 /etc/exports"
else
    log_ok "/etc/exports 已有 ${NFS_DIR} 导出配置"
fi

exportfs -ra 2>/dev/null || true
systemctl restart nfs-kernel-server rpcbind
sleep 3

if systemctl is-active --quiet nfs-kernel-server; then
    log_ok "✅ NFS server 运行中"
else
    log_error "NFS server 启动失败"
    systemctl status nfs-kernel-server --no-pager | tail -10
    exit 1
fi
log_info "showmount 验证:"
showmount -e localhost 2>/dev/null || showmount -e "${NFS_SERVER_IP}" 2>/dev/null || true

# 客户端全链路自检：回环挂载 + 写删文件（缺客户端工具/防火墙拦截会在这里暴露）
SELFTEST_DIR="/mnt/nfs-selftest"
mkdir -p "${SELFTEST_DIR}"
if mount -t nfs -o vers=4.2 "127.0.0.1:${NFS_DIR}" "${SELFTEST_DIR}" 2>/dev/null || mount -t nfs -o vers=3 "127.0.0.1:${NFS_DIR}" "${SELFTEST_DIR}" 2>/dev/null; then
    if echo "ok-$(date +%s)" > "${SELFTEST_DIR}/.selftest" 2>/dev/null && rm -f "${SELFTEST_DIR}/.selftest"; then
        log_ok "✅ NFS 客户端全链路自检通过（127.0.0.1:${NFS_DIR} 读写正常）"
    else
        log_warn "NFS 能挂载但写入失败（检查 exports 权限/no_root_squash）"
    fi
    umount "${SELFTEST_DIR}" 2>/dev/null; rmdir "${SELFTEST_DIR}" 2>/dev/null || true
else
    log_error "❌ NFS 客户端挂载失败（确认 nfs-common 已装、rpcbind/mountd 端口未拦截）"
    exit 1
fi

# ── 3. 判定 provisioner 部署模式（helm 已装 → patch 模式）─────────────────────
log_info "[3/6] 检测现有 provisioner..."
SC_NAME="nfs-client"
HELM_MANAGED=false
if helm status nfs-subdir-external-provisioner -n kube-system &>/dev/null; then
    HELM_MANAGED=true
    log_ok "检测到 Helm release: nfs-subdir-external-provisioner (kube-system) —— 走 patch 模式"
elif kubectl get storageclass "$SC_NAME" &>/dev/null; then
    log_ok "StorageClass ${SC_NAME} 已存在（raw 模式，apply 幂等覆盖）"
else
    log_info "未发现现有部署 —— 走全新 raw 部署"
fi

# ── 4. 默认 StorageClass 去重 ──────────────────────────────────────────────────
log_info "[4/6] 默认 StorageClass 去重..."
# 把其他所有 SC 的 is-default-class 摘掉（双 default 会导致调度行为不可预测）
for sc in $(kubectl get sc -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null); do
    [[ "$sc" == "$SC_NAME" ]] && continue
    HAS_DEFAULT=$(kubectl get sc "$sc" -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}' 2>/dev/null || echo "")
    if [[ "$HAS_DEFAULT" == "true" ]]; then
        log_info "  摘除默认标记: $sc"
        kubectl annotate sc "$sc" storageclass.kubernetes.io/is-default-class- --overwrite 2>/dev/null || true
    fi
done
log_ok "默认 StorageClass 去重完成（只保留 ${SC_NAME}）"

# ── 5. 部署 / 更新 provisioner + SC ───────────────────────────────────────────
log_info "[5/6] 配置 StorageClass ${SC_NAME} (mountOptions + default)..."

MOUNT_OPTIONS_YAML=$(cat <<'OPTS'
mountOptions:
  - hard
  # ★ 必须 nfsvers=3：v4.x 走 idmap，本机域名与客户端不匹配时客户端内核把文件属主
  #   解析成 nobody(65534)，mysqld(999) 写 redo 报 EACCES(13) CrashLoop（实测踩坑）；
  #   v3 AUTH_SYS 纯数字权限检查无此问题。alertmanager/grafana 以 root 跑不受影响
  - nfsvers=3
  - rsize=1048576
  - wsize=1048576
  - timeo=600
  - retrans=2
OPTS
)

if [[ "$HELM_MANAGED" == true ]]; then
    # Helm 模式：只调整 SC（不动 provisioner Deployment）
    if kubectl get storageclass "$SC_NAME" &>/dev/null; then
        DESIRED_PATTERN='${.PVC.namespace}/${.PVC.name}'
        CURRENT_PATTERN=$(kubectl get sc "$SC_NAME" -o jsonpath='{.parameters.pathPattern}' 2>/dev/null || echo "")
        if [[ "$CURRENT_PATTERN" != "$DESIRED_PATTERN" ]]; then
            # SC parameters 不可变 → 删了重建（不影响已绑定 PV/PVC，只改新 PVC 的目录布局）
            # pathPattern: PVC 数据落 /data/nfs/{命名空间}/{PVC名}/（替代默认扁平 ns-pvcname-pvuid）
            # 注意：日后 helm upgrade provisioner 需带 --set storageClass.pathPattern="${DESIRED_PATTERN}"，
            #       否则 helm 渲染 diff 会再次尝试改 parameters 被 API 拒绝
            log_info "重建 SC ${SC_NAME}（pathPattern → \${ns}/\${pvc} 嵌套目录）"
            kubectl delete storageclass "$SC_NAME"
            kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${SC_NAME}
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
    meta.helm.sh/release-name: nfs-subdir-external-provisioner
    meta.helm.sh/release-namespace: kube-system
  labels:
    app: nfs-subdir-external-provisioner
    app.kubernetes.io/managed-by: Helm
    heritage: Helm
    release: nfs-subdir-external-provisioner
provisioner: cluster.local/nfs-subdir-external-provisioner
parameters:
  pathPattern: "\${.PVC.namespace}/\${.PVC.name}"
  archiveOnDelete: "true"
  onDelete: retain
reclaimPolicy: Retain
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
${MOUNT_OPTIONS_YAML}
EOF
        else
            # pathPattern 已符合 → 只同步 mountOptions/default 标记（均可变，patch 幂等）
            kubectl patch storageclass "$SC_NAME" --type=json -p='[{"op":"remove","path":"/mountOptions"}]' 2>/dev/null || true
            kubectl patch storageclass "$SC_NAME" -p "${MOUNT_OPTIONS_YAML/ mountOptions:/mountOptions:}"
            kubectl annotate sc "$SC_NAME" storageclass.kubernetes.io/is-default-class=true --overwrite
        fi
        log_ok "SC ${SC_NAME} 已就绪（mountOptions + pathPattern 嵌套目录 + default）"
    else
        log_warn "Helm release 存在但 SC ${SC_NAME} 不存在，跳过 patch"
    fi
else
    # Raw 模式：完整部署（幂等 apply）
    NFS_PROV_VERSION="v4.0.2"

    # SC 已存在且 provisioner 字段不同 → provisioner 不可变，只 patch 不 apply
    if kubectl get storageclass "$SC_NAME" &>/dev/null; then
        EXISTING_PROV=$(kubectl get sc "$SC_NAME" -o jsonpath='{.provisioner}')
        if [[ "$EXISTING_PROV" != "k8s-sigs.io/nfs-subdir-external-provisioner" ]]; then
            log_warn "SC ${SC_NAME} 已存在且 provisioner=${EXISTING_PROV}（provisioner 字段不可变）"
            log_warn "跳过 Deployment 重建，只 patch mountOptions/default 标记（异构 SC 不动 parameters）"
            kubectl patch storageclass "$SC_NAME" --type=json -p='[{"op":"remove","path":"/mountOptions"}]' 2>/dev/null || true
            kubectl patch storageclass "$SC_NAME" -p "${MOUNT_OPTIONS_YAML/ mountOptions:/mountOptions:}"
            kubectl annotate sc "$SC_NAME" storageclass.kubernetes.io/is-default-class=true --overwrite
            kubectl get sc
            log_step "✅ NFS 存储配置完成（patch 模式）"
            exit 0
        fi
    fi

    PULL_SRC=""
    for img in \
        "docker.m.daocloud.io/sig-storage/nfs-subdir-external-provisioner:${NFS_PROV_VERSION}" \
        "docker.1panel.live/sig-storage/nfs-subdir-external-provisioner:${NFS_PROV_VERSION}" \
        "registry.k8s.io/sig-storage/nfs-subdir-external-provisioner:${NFS_PROV_VERSION}"; do
        log_info "  尝试拉取: $img"
        if ctr images pull --platform "linux/${ARCH}" "$img" 2>&1 | tail -3; then
            PULL_SRC="$img"; break
        fi
    done
    [[ -z "$PULL_SRC" ]] && { log_error "所有源无法拉取 nfs provisioner 镜像"; exit 1; }

    NATIVE_TAG="sealos.hub:5000/sig-storage/nfs-subdir-external-provisioner:${NFS_PROV_VERSION}"
    ctr images tag "$PULL_SRC" "$NATIVE_TAG" 2>/dev/null || true

    kubectl create namespace nfs-storage --dry-run=client -o yaml | kubectl apply -f -

    MANIFEST="${SCRIPT_DIR}/../helm-values/nfs-subdir-external-provisioner.yaml"
    mkdir -p "$(dirname "$MANIFEST")"
    cat > "$MANIFEST" <<EOF
# nfs-subdir-external-provisioner —— raw 部署清单（版本控制）
# StorageClass: ${SC_NAME} (default) | mountOptions 已调优
apiVersion: v1
kind: ServiceAccount
metadata:
  name: nfs-client-provisioner
  namespace: nfs-storage
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: nfs-client-provisioner-runner
rules:
  - apiGroups: [""]
    resources: ["persistentvolumes"]
    verbs: ["get","list","watch","create","delete"]
  - apiGroups: [""]
    resources: ["persistentvolumeclaims"]
    verbs: ["get","list","watch","update"]
  - apiGroups: ["storage.k8s.io"]
    resources: ["storageclasses"]
    verbs: ["get","list","watch"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["create","patch"]
  - apiGroups: ["coordination.k8s.io"]
    resources: ["leases"]
    verbs: ["get","watch","list","delete","update","create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: run-nfs-client-provisioner
subjects:
  - kind: ServiceAccount
    name: nfs-client-provisioner
    namespace: nfs-storage
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: nfs-client-provisioner-runner
---
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: ${SC_NAME}
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: k8s-sigs.io/nfs-subdir-external-provisioner
parameters:
  # 目录结构: /data/nfs/{PVC命名空间}/{PVC名}/（替代默认的扁平 ns-pvcname-pvuid）
  pathPattern: "\${.PVC.namespace}/\${.PVC.name}"
  archiveOnDelete: "false"
reclaimPolicy: Retain
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
${MOUNT_OPTIONS_YAML}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nfs-client-provisioner
  namespace: nfs-storage
spec:
  replicas: 1
  strategy: { type: Recreate }
  selector: { matchLabels: { app: nfs-client-provisioner } }
  template:
    metadata:
      labels: { app: nfs-client-provisioner }
    spec:
      serviceAccountName: nfs-client-provisioner
      containers:
      - name: nfs-client-provisioner
        image: ${NATIVE_TAG}
        imagePullPolicy: IfNotPresent
        resources:
          requests:
            cpu: 100m
            memory: 64Mi
          limits:
            cpu: 500m
            memory: 256Mi
        env:
        - name: PROVISIONER_NAME
          value: k8s-sigs.io/nfs-subdir-external-provisioner
        - name: NFS_SERVER
          value: ${NFS_SERVER_IP}
        - name: NFS_PATH
          value: ${NFS_DIR}
        volumeMounts:
        - name: nfs-client-root
          mountPath: /persistentvolumes
      volumes:
      - name: nfs-client-root
        nfs:
          server: ${NFS_SERVER_IP}
          path: ${NFS_DIR}
EOF

    kubectl apply -f "$MANIFEST"
    log_ok "Provisioner raw 部署完成（清单已存 helm-values/ 便于版本控制）"

    log_info "等待 provisioner 就绪..."
    wait_pods_ready nfs-storage app=nfs-client-provisioner 120
fi

# ── 6. 验证 ────────────────────────────────────────────────────────────────────
log_info "[6/6] 验证..."
kubectl get sc
DEFAULT_COUNT=$(kubectl get sc -o jsonpath='{range .items[*]}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}{end}' | grep -c "true" || true)
if [[ "$DEFAULT_COUNT" == "1" ]]; then
    log_ok "✅ 默认 StorageClass 唯一: ${SC_NAME}"
else
    log_warn "⚠️ 默认 StorageClass 数量异常: ${DEFAULT_COUNT}（应为 1）"
fi

log_step "✅ NFS 存储类配置完成"
log_info "  NFS Root:     ${NFS_SERVER_IP}:${NFS_DIR}"
log_info "  nfsd 线程:    ${NFSD_THREADS}"
log_info "  StorageClass: ${SC_NAME} (default, Retain, rsize/wsize=1MiB, hard, nfs4.1)"
log_info "  mountOptions 生效范围: 之后新建的 PV（存量 PV 需重建 PVC 才会应用）"
