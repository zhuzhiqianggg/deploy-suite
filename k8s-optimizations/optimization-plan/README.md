# Kubernetes 集群优化实施方案（optimization-plan）

> 创建时间：2026-08-25
> 适用集群：k8s-test（测试，先实施验证）→ 生产集群（测试验证通过后推广）
> 部署方式：sealos v5.0.1 / k8s v1.29.9 / containerd 1.7.27 / Calico 3.27.4 (IPIP+IPVS)
> 原则：**所有变更先在测试集群验证，验证周期结束后才允许上生产**

---

## 一、集群现状快照（2026-08-25 采集）

审查时的基线状态，后续实施后可对照：

| 项目 | 现状 | 结论 |
|------|------|------|
| 节点 | 3 master (100/104/105) + 5 worker (101/102/103/106/107) | master 无 taint，业务 Pod 挤占控制面 |
| etcd | 444M 数据，**无任何备份**，无压缩/defrag 配置 | P0 风险 |
| kubelet 集群 ConfigMap | `memory.available: 100Mi`、`shutdownGracePeriod: 0s`（旧危险配置） | 新节点 join 即中招（worker04 已实际踩坑） |
| 节点本地 kubelet 配置 | 已手动铺优化版（/root/k8s-optimizations/node-tuning/kubelet-config-optimized.yaml） | 与 ConfigMap 不一致，存在漂移 |
| 节点 DNS | systemd-resolved 单上游 223.5.5.5，实测阵发 ~40% 超时 | 集群性镜像 pull 报错的根因之一 |
| CoreDNS | 4 副本，forward 上游含 8.8.8.8（国内不可达） | ~1/3 外部解析白等 2s 超时 |
| Calico IPPool | `ipipMode: Always` | 全节点同子网(192.168.10.0/24)，白交封装税 |
| 资源治理 | 115 业务 ns，**零 ResourceQuota / 零 LimitRange** | 无爆炸半径控制 |
| 业务 PDB | 无（仅系统组件有） | 节点维护时单副本服务直接中断 |
| 存储治理 | 39 个 StorageClass（35 个 no-provisioner+Retain） | 存储手工化反模式，PV 泄漏累积 |
| K8s 版本 | v1.29.9，上游支持已于 2025-02 结束 | 超一年半无安全补丁 |
| 内核版本 | 5.15.0-119 与 5.15.0-185 混跑 | 排障变量，建议统一 |
| 证书 | 99 年有效期（sealos 默认） | 权衡项，需收紧 pki 权限 |
| API server 审计日志 | 已配置（json/7天/100M轮转） | ✅ 良好，保持 |
| kube-proxy | IPVS 模式 | ✅ 285 service 规模下正确 |
| 业务 requests/limits | 普遍已配置 | ✅ 良好，保持 |

---

## 二、文档索引（编号 = 建议执行顺序）

| 编号 | 文档 | 优先级 | 风险 | 一句话说明 | 状态 |
|------|------|--------|------|-----------|------|
| 01 | [etcd 备份与恢复体系](./01-etcd-backup.md) | **P0** | 无（纯增量） | 每日快照+保留策略+恢复演练，集群唯一兜底 | ⬜ 待实施 |
| 02 | [DNS 链路修复](./02-dns-optimization.md) | **P1** | 低 | 节点多上游 + CoreDNS 去 8.8.8.8 | ⬜ 待实施 |
| 03 | [kubelet 集群 ConfigMap 合入](./03-kubelet-configmap.md) | **P0** | 低 | 修复新节点 join 拿到危险配置的漂移问题 | ⬜ 待实施 |
| 04 | [Calico IPIP Always→CrossSubnet](./04-calico-crosssubnet.md) | **P1** | 低 | 同子网免封装，免费性能提升 10-20% | ⬜ 待实施 |
| 05 | [Master 节点隔离（taint+迁移）](./05-master-taint-isolation.md) | **P0** | 中 | 控制面专用，防 etcd 选举抖动 | ⬜ 待实施 |
| 06 | [ResourceQuota + LimitRange 铺设](./06-resource-quota-limitrange.md) | **P1** | 低 | ns 级爆炸半径控制 | ⬜ 待实施 |
| 07 | [业务 PDB 保护](./07-pdb-protection.md) | **P1** | 低 | 节点维护时不中断服务 | ⬜ 待实施 |
| 08 | [K8s 版本升级 1.29→1.30](./08-version-upgrade-1.30.md) | **P0** | 高 | 补安全补丁，需前置项全部稳定 | ⬜ 规划中 |
| 09 | [治理与卫生项汇总](./09-governance-cleanup.md) | **P2** | 各项不同 | SC 收敛/etcd defrag/内核统一/PSA/证书/HPA | ⬜ 择机 |
| 10 | [NFS 高可用搭建与迁移](./10-nfs-ha-migration.md) | **P0** | 分阶段 | DRBD+Keepalived+NFS 双机，逐业务平滑迁移，含华为云生产差异清单 | 🔄 **P1 完成**（2026-08-25，failover 演练通过）；P2 数据同步待启动 |

配套脚本（`scripts/`，均按"echo 所有执行命令"惯例编写）：

| 脚本 | 用途 | 关联文档 |
|------|------|---------|
| [etcd-backup.sh](./scripts/etcd-backup.sh) | 每日 etcd 快照+清理过期备份 | 01 |
| [etcd-defrag-check.sh](./scripts/etcd-defrag-check.sh) | etcd 健康巡检+碎片率判断+可选 defrag | 01/09 |
| [dns-multi-upstream-fix.sh](./scripts/dns-multi-upstream-fix.sh) | 批量修复所有节点 resolved.conf 多上游 | 02 |
| [quota-template.yaml](./scripts/quota-template.yaml) | ns 配额模板（小/中/大三档） | 06 |
| [pdb-audit.sh](./scripts/pdb-audit.sh) | 审计无 PDB 的多副本 Deployment | 07 |
| [nfs-ha/keepalived-nfs-check.sh](./scripts/nfs-ha/keepalived-nfs-check.sh) | NFS-HA 节点健康检查（keepalived 调用） | 10 |
| [nfs-ha/keepalived-nfs-notify.sh](./scripts/nfs-ha/keepalived-nfs-notify.sh) | MASTER/BACKUP 切换动作（DRBD/挂载/NFS 联动） | 10 |
| [nfs-ha/nfs-data-sync.sh](./scripts/nfs-ha/nfs-data-sync.sh) | 迁移期数据同步（全量/增量/最终/校验） | 10 |
| [nfs-ha/nfs-daily-backup.sh](./scripts/nfs-ha/nfs-daily-backup.sh) | 迁移后每日备份轮转（误删保护） | 10 |

---

## 三、执行路线图

```
第 1 周   ──► 01 etcd 备份（无风险纯加分） + 02 DNS 修复（低风险）
第 1-2 周 ──► 10 NFS 高可用（P1 搭建+P2 预同步零风险；P3 演练后逐业务切换）
              ⚠️ 10 应在 05 之前完成——NFS 搬离 master01 是 master 隔离的前置条件
第 2 周   ──► 03 kubelet ConfigMap（低风险，不动存量节点）
第 2-3 周 ──► 04 Calico CrossSubnet（低风险，观察 48h 路由收敛）
第 3-4 周 ──► 05 master taint + 业务迁移（中风险，业务低峰期，drain 分批）
持续迭代 ──► 06 Quota / 07 PDB（随业务逐 ns 铺开，新 ns 建立时强制带上）
前置稳定 ──► 08 版本升级 1.30（大工程，01-05/10 全部稳定后再启动）
择机处理 ──► 09 治理项（StorageClass 收敛 / etcd defrag / 内核统一 / PSA）
```

**依赖关系**：
- 08（升级）强依赖 01（备份）——升级前必须有 etcd 快照回滚点
- **10（NFS HA）强依赖前置：05 的硬前置**——NFS 不搬走，master01 无法真正隔离
- 05（迁移）建议在 07（PDB）铺开后做——迁移时 drain 依赖 PDB 保护业务
- 06/07 无顺序依赖，可与 01-05 并行推进

---

## 四、进度跟踪

| 日期 | 事项 | 集群 | 结果 | 备注 |
|------|------|------|------|------|
| 2026-08-25 | 方案文档创建 | - | - | 全部待实施 |
| | | | | |

> 每完成一项，在上表追加一行，并将"文档索引"中对应状态改为 ✅（测试）/ 🏭（已上生产）/ ❌（回滚）。

---

## 五、通用实施纪律（每个文档都必须遵守）

1. **变更前**：确认对应文档"实施前检查"全部通过；涉及 etcd/节点的操作先做快照
2. **变更中**：命令逐条执行，每步观察"预期输出"，不符立即停下排查，不带病推进
3. **变更后**：执行"验证方法"全项；观察期（文档标注）内无异常才算完成
4. **回滚**：任何异常超出文档预期，立即按"回滚方案"操作，事后复盘再重试
5. **生产上线**：测试集群验证满观察期（一般 1-2 周）+ 输出验证记录，才允许生产执行
6. **文档同步**：实施中如发现文档命令与实际不符（版本差异等），先改文档再继续，保持文档始终可执行

---

## 六、学习路径（配合本方案）

| 顺序 | 主题 | 与方案的关联 |
|------|------|-------------|
| 1 | etcd：raft 选举、snapshot vs defrag、endpoint status 各列含义 | 直接对应 01/09，实施前吃透 |
| 2 | 调度：taint/toleration、affinity、topologySpread | 直接对应 05，迁移时观察调度行为 |
| 3 | 官方文档《Resource Quotas》《Taints and Tolerations》两章 | 对应 06/05，带着问题读 |
| 4 | K8s the Hard Way（手工搭建一次单节点） | 理解 sealos 封装的证书/bootstrap 机制 |
| 5 | kubelet 驱逐机制（evictionHard/Soft/Reclaim 三件套） | 对应 03，理解之前 OOM 事故的原理 |

---

## 变更记录

- 2026-08-25 初版创建（基于全集群配置审查）
