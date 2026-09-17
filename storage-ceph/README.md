# storage-ceph — Rook-Ceph 分布式存储套件（K8s 一键部署）

> 适用前提：**≥3 台 K8s worker 节点**。单节点集群无 HA 意义，请继续用 NFS（databases/ 体系）。
> 本套件是"未来扩容到多节点后的存储升级方案"，与现有 NFS 可共存、可渐进迁移。

## 1. 架构

```text
K8s 集群（≥3 worker，ARM64 OK）
├── rook-ceph operator        ← Helm 安装，托管下方所有组件的生命周期
├── mon × 3                   ← 仲裁，容忍 1 节点故障
├── mgr × 2                   ← 主备，dashboard 所在
├── OSD × 每空闲盘1个          ← 真正存数据，replica3，节点挂1台自动补齐副本
├── MDS × 2                   ← CephFS 元数据服务（RWX 用）
└── CSI 驱动 (rbd/cephfs)     ← 把 Ceph 变成 StorageClass 的桥梁

宿主机要求:
- 每节点 ≥1 块空闲裸盘（无分区/无文件系统/未挂载），10G 内网更佳
- dataDirHostPath=/var/lib/rook（mon/osd 元数据，重装必须清）
- 内核模块 rbd/libceph/ceph（Ubuntu 22.04 自带）
```

## 2. K8s 里怎么引用 Ceph？和 NFS 一样吗？——几乎一样，就一个字段之差

**对应用/Pod 来说引用方式完全没变：都是 StorageClass + PVC + volumeMount。** 唯一变化是 `storageClassName` 的值：

| 场景 | 现在（NFS） | 切换后（Ceph） |
|---|---|---|
| 数据库数据盘（单挂载） | `nfs-client`（RWX 但其实单用） | `rook-ceph-block`（RBD，RWO，性能最好） |
| 多 Pod 共享目录 | `nfs-client` | `rook-cephfs`（RWX） |
| PVC 写法 | accessModes RWX + storage | RBD 用 RWO / CephFS 用 RWX，其余一字不改 |
| 在线扩容 | ✗（nfs provisioner 不支持，你们踩过 Forbidden） | ✓ 两类都支持，`kubectl patch pvc` 即扩 |
| 快照/克隆 | ✗ | ✓（需装 snapshot CRD，见下文） |
| 后端 | 单台 NFS server，单点 | 3 副本分布式，节点级容灾 |

Pod 挂载示例（与现有写法唯一区别是 storageClassName / accessModes）：

```yaml
# 数据库类（RBD 块）
volumes:
- name: data
  persistentVolumeClaim:
    claimName: mysql-data
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: mysql-data }
spec:
  accessModes: [ReadWriteOnce]          # RBD 只能 RWO
  storageClassName: rook-ceph-block     # ← 唯一要改的字段
  resources: { requests: { storage: 100Gi } }
```

```yaml
# 共享目录类（CephFS）
spec:
  accessModes: [ReadWriteMany]          # 多 Pod 共读写
  storageClassName: rook-cephfs
  resources: { requests: { storage: 120Gi } }
```

> 注意 RBD 的 RWO 不是缺陷：数据库/单写场景正是块设备的优势（性能约为 CephFS 的数倍）。
> CephFS 也能单 Pod 挂（RWO 写法一样支持），拿不准就用 rook-cephfs。

## 3. 一键部署

```bash
cd storage-ceph

# ① 前置检查（只读）：节点数/空闲盘/内核模块
./deploy.sh check

# ② 安装（operator → cluster → cephfs → 双 SC，全幂等可重跑）
./deploy.sh install
# 可选参数:
#   DEVICE_FILTER=nvme ./deploy.sh install     # 指定只吞 nvme 盘，防误伤系统盘
#   SWR_REPO=swr.cn-east-3.myhuaweicloud.com/xxx ./deploy.sh install  # SWR 离线镜像

# ③ 读写实测（RWO 写读 / RWX 双 Pod 互写 / RBD 在线扩容 1Gi→2Gi）
./deploy.sh verify

# ④ 状态与运维
./deploy.sh status        # ceph -s 健康总览
```

首次部署约 10~20 分钟（拉镜像 + OSD 格式化）。`HEALTH_OK` 后即可建 PVC。

## 4. 从 NFS 迁移现有业务（指引）

PVC 不能改类型，迁移 = 新建 Ceph PVC → 拷数据 → 切换。以 MySQL 为例：

```bash
# 1) 新 PVC（rook-ceph-block）挂到业务 Pod 的临时 sidecar 挂载点
# 2) 用 job/pod 做数据拷贝（两个 PVC 同时挂）
kubectl -n <ns> run migrate --rm -it --image=docker.m.daocloud.io/library/busybox \
  --overrides='...' -- sh -c 'cp -a /old/. /new/'    # old=旧NFS PVC卷, new=新Ceph PVC卷
# 3) 停写窗口内做最终同步（rsync -a --delete）
# 4) 改业务 yaml 的 storageClassName + claimName，滚动重建
# 5) 验证无误后再删旧 PVC（NFS 数据仍在 /data/nfs/<ns>/，天然留底）
```

存量 PV/PVC 不动也能共存——Ceph 装好后两套 SC 并存，新业务用新 SC，老的按需逐步迁。

## 5. 日常运维

```bash
# 工具箱进 ceph 命令行
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- bash
ceph -s                        # 健康/容量/OSD
ceph osd tree                  # 盘的分布
ceph df                        # 池用量

# Dashboard（默认 ClusterIP）
kubectl -n rook-ceph get svc rook-ceph-mgr-dashboard
kubectl -n rook-ceph port-forward svc/rook-ceph-mgr-dashboard 7000:7000
# 取初始 admin 密码: kubectl -n rook-ceph get secret rook-ceph-dashboard-password \
#   -o jsonpath='{.data.password}' | base64 -d

# 加盘扩容：新盘插上后无需配置，operator 自动发现并建 OSD（useAllDevices=true）
# 扩 PVC：kubectl patch pvc <name> -p '{"spec":{"resources":{"requests":{"storage":"200Gi"}}}}'
#         RBD/CephFS 均支持在线扩；文件系统层 ext4/xfs 需 Pod 内 resize2fs/xfs_growfs（CSI 一般自动）

# 重要数据防误删：把 SC reclaimPolicy 改 Retain，或对 PVC 打快照（需 snapshot CRD:
#   kubectl apply -f github.com/kubernetes-csi/external-snapshotter/client/config/crd + deploy）
```

## 6. 镜像同步（离线/弱网）

```bash
cd scripts && cp ../delivery-tools/.swr-credentials .   # 复用现有 SWR 凭据
./sync-images.sh        # 8 个 ARM64 镜像（rook/ceph/cephcsi/csi-*）→ SWR
SWR_REPO=<swr前缀> ../deploy.sh install
# csi-* 辅助镜像版本以 chart 实际默认为准，装完用 operator 日志核对补差
```

## 7. 卸载（会清数据，重装前必读）

```bash
./deploy.sh uninstall          # 按引导：删 SC → CephFS → CephCluster → ns/CRD
# 每节点手动:
rm -rf /var/lib/rook                        # 不清则 mon 无法重新选主，装不起来
dd if=/dev/zero of=/dev/<osd盘> bs=1M count=100   # 不清则 OSD 重装直接失败
# docker/containerd 残留镜像按需清理
```

## 8. 故障排查速查

| 现象 | 处理 |
|---|---|
| OSD 不出现 | 盘不是"空闲裸盘"（有分区/swap/挂载）→ wipe 或换 DEVICE_FILTER |
| PVC 一直 Pending | `kubectl -n rook-ceph logs -l app=rook-ceph-csi-*`；多为 secret/clusterID 不匹配 |
| Pod 卡 ContainerCreating | 节点缺 rbd/ceph 内核模块，或 cephfs 网络不通 |
| mon 崩选不出主 | dataDirHostPath 残留旧数据 → 彻底清 /var/lib/rook |
| 集群 HEALTH_WARN 容量 | osd 占用 >75% 会警告，>85% 拒写 → 加盘/清数据 |
