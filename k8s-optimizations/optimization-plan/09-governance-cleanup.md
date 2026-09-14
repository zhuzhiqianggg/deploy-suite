# 09. 治理与卫生项汇总（P2，择机处理）

> 本文档收录不紧急但长期有价值的治理项。每项独立实施，互不依赖，按机会窗口逐个做。

---

## 9.1 StorageClass 收敛（存储手工化反模式）

| 属性 | 值 |
|------|-----|
| 现状 | 39 个 SC：35 个 `no-provisioner`+Retain（每业务 ns 手工一套），4 个 NFS CSI 动态供给 |
| 风险 | PV 只增不减（现 35 个 Retain PV），每次环境重建泄漏存储；新环境搭建依赖人工 |
| 目标 | 存储动态供给为主（NFS CSI），手工 SC 逐步退役 |

**原理（学习点）**：`no-provisioner` 的 SC 意味着 k8s 只做"撮合"（PVC 找现成 PV）不做"供给"（不会自动创建），PV 生命周期完全脱离 k8s 控制——PVC 删了 PV 还在（Retain），需要人工清理底层目录。NFS CSI 的 `Delete` 回收策略才能实现"删 PVC = 删目录"的闭环。

**实施步骤**：

```bash
# 1. 盘点：哪些手工 PV 底层目录已无 PVC 引用（泄漏统计）
kubectl get pv -o json | jq -r '.items[] | select(.status.phase=="Released" or .status.phase=="Available") | "\(.metadata.name) \(.status.phase)"' | head -n 20

# 2. 新环境一律走 NFS CSI 动态供给（已有现成 SC）：
kubectl get sc nfs-csi nfs-storage -o wide
# 新 PVC 直接 storageClassName: nfs-csi（Delete+Immediate，删 PVC 自动清目录）

# 3. 存量手工 SC：不主动迁移（有状态业务迁移 = 中断风险），采用"冻结+自然退役"：
#    - 冻结：通知所有业务 ns 不再新建 PVC 到手工 SC
#    - 退役：业务环境重建时顺手切到 nfs-csi，对应 SC+PV 随旧环境清理
# 4. 每季度跑一次泄漏盘点（步骤 1），Released/Available 的 PV 确认无用后：
kubectl delete pv <name>            # 释放 k8s 对象
# 手工清理 NFS 侧对应目录（路径看 pv.spec.nfs.path）
```

**生产注意**：DB 类有状态服务对 NFS 性能敏感（已踩过 stale file handle 坑），DB 建议继续本地盘/手工 PV；NFS CSI 适合配置/日志/前端类数据。

---

## 9.2 etcd 碎片整理巡检（defrag）

| 属性 | 值 |
|------|-----|
| 现状 | 无压缩/defrag 配置；db 444M 且只增不减 |
| 风险 | 碎片累积导致 db 膨胀（默认 quota 2G，触顶后集群只读！） |
| 目标 | 巡检脚本 + 碎片率 >50% 时低峰 defrag |

**原理（学习点）**：
- etcd 压缩（compaction）= 丢弃历史版本（默认保留 1h）——自动做，但**不会归还磁盘空间**（类似删文件不 shrink）
- defrag = 物理收缩 db 文件——**期间该 member 短暂阻塞写**（几百 ms 到几秒），所以只能逐 member 做、低峰做
- `db_total_size` vs `db_total_size_in_use` 的差值即碎片。**quota 默认 2G，超限触发 NOSPACE 告警 → 集群整体只读**（所有 kubectl 报 etcdserver: mvcc: database space exceeded）——这是 etcd 最著名的"全集群瘫痪"事故模式

**实施步骤**：

```bash
# 1. 部署巡检脚本（只读巡检 + 可选 --defrag 执行）
install -m 750 scripts/etcd-defrag-check.sh /root/scripts/

# 2. 每周巡检（crontab，周一 03:00，只读模式）
0 3 * * 1 /root/scripts/etcd-defrag-check.sh >> /var/log/etcd-defrag-check.log 2>&1

# 3. 巡检输出碎片率 >50% 时，低峰手工执行：
bash /root/scripts/etcd-defrag-check.sh --defrag
# 脚本内部：逐 member defrag（一个完成再下一个），全程 echo 命令

# 4. （可选加固）给 etcd manifest 显式加压缩参数（重启 etcd 生效，需逐台滚动）：
#    /etc/kubernetes/manifests/etcd.yaml command 追加：
#      --auto-compaction-mode=revision
#      --auto-compaction-retention=1000    # 保留最近 1000 个 revision（etcd 官方推荐做法）
```

---

## 9.3 内核版本统一（5.15.0-119 → 5.15.0-185）

| 属性 | 值 |
|------|-----|
| 现状 | 5 节点 119、3 节点 185 混跑 |
| 风险 | 排障变量（网络/内存问题时难以对照）；119 早期有已知 bug |
| 时机 | 借节点维护窗口（文档 05 迁移、后续升级）逐台做 |

**实施步骤**（单节点，drain 后操作）：

```bash
# 1. drain + 确认镜像源正确（jammy，见项目记忆：曾有 focal 源污染坑）
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
ssh root@<node> 'grep -c jammy /etc/apt/sources.list'   # 预期非 0

# 2. 安装目标内核并设默认启动
ssh root@<node> 'apt-get install -y linux-image-5.15.0-185-generic && grub-set-default "Advanced options for Ubuntu>Ubuntu, with Linux 5.15.0-185-generic"'

# 3. 重启 + 验证 + uncordon
ssh root@<node> 'reboot'
# 等 Ready 后：
kubectl uncordon <node>
ssh root@<node> 'uname -r'   # 预期 5.15.0-185-generic

# 4. 每台间隔 ≥1 天，全部完成后统一在 README 记录
```

**注意**：worker04（刚重装，已是 119）也纳入统一计划；升级内核后确认 ring buffer/sysctl 调优仍在（nic-ringbuffer.service 自启 + `sysctl --system`）。

---

## 9.4 Pod Security Admission（PSA）启用

| 属性 | 值 |
|------|-----|
| 现状 | 所有业务 ns 无 `pod-security.kubernetes.io/enforce` label |
| 风险 | 业务可随意 hostPath/hostNetwork/privileged，容器逃逸面大 |
| 目标 | 业务 ns `baseline` 级别强制 |

**原理（学习点）**：PSA 是 1.23+ 内置的 Pod 安全基线（取代已废弃的 PodSecurityPolicy），三级策略：
- `privileged`：不限制（现状默认）
- `baseline`：禁 hostPath/hostNetwork/hostPID/privileged 等高危项，**不影响绝大多数普通业务**
- `restricted`：还要求 runAsNonRoot/seccomp 等（业务改造量大，暂不上）

**实施步骤**：

```bash
# 1. 先 warn 模式试运行（不拒绝，只告警）——拿一个业务 ns 实验
kubectl label ns trace-beosin-saas-test pod-security.kubernetes.io/warn=baseline --overwrite
# 观察 1 周事件：
kubectl get events -n trace-beosin-saas-test --sort-by=.lastTimestamp | grep -i "would violate" | head
# 预期：无输出（业务无高危配置才能切 enforce）

# 2. 无告警的 ns 逐个切 enforce
kubectl label ns trace-beosin-saas-test pod-security.kubernetes.io/enforce=baseline --overwrite

# 3. 有告警的 ns：列出违规工作负载（事件里有 Pod 名），业务侧改造后再切
# 4. 新 ns 建立时直接打 label（并入文档 06 的 ns 创建三件套）

# 回滚：kubectl label ns <ns> pod-security.kubernetes.io/enforce- （删 label 即回 privileged）
```

---

## 9.5 证书与 pki 权限收紧

| 属性 | 值 |
|------|-----|
| 现状 | 证书 99 年（sealos 默认），pki 目录含多套 CA 私钥 |
| 风险 | 密钥泄露后 99 年有效；pki 若被普通用户读到 = 集群控制权外泄 |
| 目标 | 权限收紧（低成本高收益）；证书长效作为已接受的权衡 |

**实施步骤**：

```bash
# 1. 收紧 master 的 pki 目录（三台 master + sealos 本地副本）
chmod -R 600 /etc/kubernetes/pki && chmod 700 /etc/kubernetes/pki
chmod -R 600 /root/.sealos/default/pki 2>/dev/null

# 2. 验证：非 root 不可读
sudo -u nobody cat /etc/kubernetes/pki/ca.key 2>&1 | head -n 1
# 预期：Permission denied

# 3. 备份 pki 到安全位置（etcd 备份目录之外单独一份，权限同样 600）
tar czf /data/pki-backup-$(date +%Y%m%d).tar.gz /etc/kubernetes/pki && chmod 600 /data/pki-backup-*.tar.gz

# 4.（可选长期项）如未来重建集群，评估 1 年期证书 + cert-manager/kubeadm 自动轮换
```

---

## 9.6 HPA 引入评估（生产）

| 属性 | 值 |
|------|-----|
| 现状 | 全集群 0 个 HPA |
| 适用 | 生产对外 web/front 类服务（CPU 型负载） |
| 前置 | 生产需 metrics-server 数据可靠（测试集群已有 metrics-scraper） |

**示例（生产某 front 服务）**：

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata: {name: bms-front-hpa, namespace: bms-lianantech-saas-test}
spec:
  scaleTargetRef: {apiVersion: apps/v1, kind: Deployment, name: bms-front}
  minReplicas: 2
  maxReplicas: 6
  metrics:
  - type: Resource
    resource: {name: cpu, target: {type: Utilization, averageUtilization: 70}}
  behavior:
    scaleDown: {stabilizationWindowSeconds: 300}   # 缩容慢一点，避免抖动
# 验证：kubectl get hpa -w 观察扩缩行为；压测触发扩容一次
```

**注意**：HPA 依赖 Deployment 的 requests 配置准确（Utilization 按 requests 百分比算），配合文档 06 的 Quota 一起食用效果最佳。测试环境负载不真实，HPA 验证建议在生产灰度一个服务。

---

## 实施顺序建议

```
立即可做（零风险）：9.5 pki 权限收紧
季度例行：9.2 etcd defrag 巡检（先部署脚本）
随维护窗口：9.3 内核统一（搭 05/08 的车）
随业务迭代：9.1 SC 收敛（新环境全走 NFS CSI）、9.4 PSA（warn→enforce 渐进）
生产专项：9.6 HPA（灰度一个服务验证）
```

---

## 关联文件

- 脚本：`scripts/etcd-defrag-check.sh`（9.2）
