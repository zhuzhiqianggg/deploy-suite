# 08. Kubernetes 版本升级路线：v1.29.9 → v1.30.x

| 属性 | 值 |
|------|-----|
| 优先级 | P0（安全债）但**执行排最后** |
| 风险等级 | **高**（全集群滚动变更，前置条件最多） |
| 前置条件 | 文档 01 etcd 备份稳定运行 ≥ 2 周；02/03/05 全部完成并稳定；测试集群完整升级演练 1 次 |
| 建议实施 | 前置项全部稳定后单独立项（预计 1-2 个月后） |
| 状态 | ⬜ 规划中（本文档为预研方案） |

---

## 1. 背景与问题

**现状**：v1.29.9。1.29 上游维护已于 2025-02 结束，当前（2026-08）**超一年半无安全补丁**，期间披露的 API server/scheduler 等 CVE 均未修复。

**原理（学习点）**：

- k8s 版本生命周期：每个 minor 版本支持约 14 个月；补丁版（1.29.9→1.29.x）只修 bug，minor 升级（1.29→1.30）才带安全修复与 API 变化
- **严禁跳版本**（1.29→1.33）：每次 minor 升级都可能废弃 API（如 1.29→1.30 变化较小，1.32 大量 policy API 变化），跨版本叠加无法预判影响。官方支持路径是逐 minor：1.29→1.30→1.31
- sealos 集群升级机制：`sealos run labring/kubernetes:<target> --upgrade` 内部做的是：
  1. 滚动升级控制面（master 逐台：拉新版本静态 pod 镜像 → etcd 不动 → apiserver/cm/scheduler 切新版本）
  2. 滚动升级 worker（kubelet 二进制 + 配置，节点逐台 drain → 升级 → uncordon）
  3. 升级 kube-proxy/calico 等 addon 的兼容性由各自镜像 tag 决定
- **1.30 的关键内部变化**：etcd 默认 3.5（本集群 manifest 未显式锁版本则跟随镜像）、API 变化较小（1.30 是"平稳版"），适合作为 1.29 的后继

---

## 2. 实施前检查（全部满足才可开工）

```bash
# 2.1 前置项确认
ls /data/etcd-backup/snap-*.db | wc -l           # ≥3（备份体系稳定运行的证据）
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints   # master 已隔离（文档05）

# 2.2 目标版本调研（实施当周执行）
# 查 1.30 最新补丁版：https://github.com/labring-io/Sealos 支持的镜像 tag
# 镜像名格式：registry.cn-shanghai.aliyuncs.com/labring/kubernetes:v1.30.x
# 原则：选 1.30 的最新补丁版（x 取当期最大）

# 2.3 API 废弃预检（1.29→1.30 的废弃项扫描）
# 列出集群内使用的将被 1.30 拒绝的 API（重点：policy/v1beta1 系已在 1.25 死亡，1.30 无新增死亡项，
# 但仍需扫描存量对象有无早该迁移的遗留）
kubectl get apiservices | grep -E "v1beta1" | head    # 预期：仅 CRD 自带的，无核心组 v1beta1
kubectl get ingress -A -o jsonpath='{range .items[*]}{.apiVersion}{"\n"}{end}' | sort -u
# 预期：networking.k8s.io/v1（若有 extensions/v1beta1 networking.k8s.io/v1beta1 遗留 → 先迁移业务）

# 2.4 第三方组件兼容性核对
kubectl get ds,deploy -A -o json | jq -r '.items[] | "\(.spec.template.spec.containers[0].image)"' | grep -oE "^[^ ]+:[^ ]+$" | sort -u | head -n 30
# 核对清单（对照各组件官方支持矩阵）：
#   - calico v3.27.4：支持 k8s ≤1.30 ✅（3.27 支持到 1.30）
#   - csi-driver-nfs v4.9.0：✅
#   - ingress-nginx v1.11.3：✅（1.11 支持 1.28-1.30）
#   - metrics-server / coredns（1.29 镜像）：kube-proxy 与 apiserver 有 skew 窗口，可后置升级
# ⚠️ k8s 组件版本 skew 规则：kubelet 不得高于 apiserver 超过 3 个 minor；coredns/kube-proxy 允许落后 apiserver 一个 minor 内

# 2.5 磁盘与镜像预拉
df -h /var/lib/containerd    # 预期：剩余 >20%（新版本组件镜像每个数百 M）
# sealos 会自动拉镜像，DNS（文档02）修复后此步风险已低
```

---

## 3. 实施步骤（测试集群完整演练一次）

### 3.1 升级日准备（当日 09:00）

```bash
# 3.1.1 手工触发 etcd 快照并校验（回滚点！）
bash /root/scripts/etcd-backup.sh && etcdctl snapshot status /data/etcd-backup/$(ls /data/etcd-backup | grep snap | tail -n1) -w table

# 3.1.2 记录升级前状态基线
kubectl get nodes -o wide > /tmp/nodes-before.txt
kubectl get pods -A | grep -vE "Running|Completed" > /tmp/unhealthy-before.txt
```

### 3.2 执行升级（sealos 一键滚动）

```bash
# 在 master01 上执行（--upgrade 模式：滚动升级不重建集群）
sealos run registry.cn-shanghai.aliyuncs.com/labring/kubernetes:v1.30.<x> --upgrade
# 预期日志流程：
#   Preflight → 逐台 master：pull 镜像 → 更新静态 pod → 等待 Ready
#   → 逐台 worker：drain → 升级 kubelet → uncordon
# 全程 30-60 分钟（取决于镜像拉取速度）

# ⚠️ 若中途卡住（常见卡点：某 worker drain 被 PDB 挡/镜像拉取超时）：
#   - sealos 可安全重跑（幂等）：解决卡点后重新执行同一条命令
#   - 切勿在卡住时重启节点或手工改 manifests
```

### 3.3 升级后立即检查

```bash
# 3.3.1 版本一致性（所有节点同版本）
kubectl get nodes -o custom-columns=NAME:.metadata.name,VER:.status.nodeInfo.kubeletVersion
# 预期：全部 v1.30.x

# 3.3.2 控制面健康
kubectl get cs 2>/dev/null || kubectl get --raw='/readyz?verbose' | grep -v "ok" | head
# 预期：全部 ok（无异常行）

# 3.3.3 系统组件镜像已切新版本
kubectl -n kube-system get pods -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}' | grep -E "kube-apiserver|kubelet|kube-proxy" | sort -u

# 3.3.4 与升级前异常清单对比（不应新增异常）
kubectl get pods -A | grep -vE "Running|Completed" > /tmp/unhealthy-after.txt
diff /tmp/unhealthy-before.txt /tmp/unhealthy-after.txt
# 预期：无新增（原有已知问题项不变）

# 3.3.5 功能抽测
kubectl run smoke --image=busybox:1.36 --restart=Never -n default -- sh -c 'wget -qO- kubernetes.default.svc && echo DNS-OK'
kubectl delete pod smoke -n default --force --grace-period=0
# 预期：DNS-OK（新 kubelet + 新 apiserver 下网络/DNS 正常）
```

### 3.4 kubelet ConfigMap 复查（关键后续动作！）

**这是文档 03 遗留的长效风险点**：`kubeadm/sealos upgrade` 过程会重新生成 kubelet-config ConfigMap，可能把优化配置重置回默认。

```bash
kubectl -n kube-system get cm kubelet-config -o jsonpath='{.data.kubelet}' | grep -E "memory.available:|mergeDefaultEvictionSettings:"
# 若变回 100Mi / 缺失 → 按文档 03 重新合入优化配置，并逐节点确认本地文件未被覆盖
ssh root@<任一节点> 'grep memory.available /var/lib/kubelet/config.yaml'
```

---

## 4. 验证方法（观察期 2 周）

```bash
# 每日巡检（升级后 14 天）
kubectl get nodes | grep -v Ready | wc -l                 # 预期 0
kubectl get pods -A | grep -vE "Running|Completed" | wc -l # 与基线持平
kubectl top nodes                                          # 无异常倾斜
# etcd 指标（升级后 apiserver 写模式可能变化，观察 db 增长）
ssh root@192.168.10.100 'curl -s http://127.0.0.1:2381/metrics | grep "^etcd_mvcc_db_total_size_in_bytes"'
# 业务侧：各团队反馈功能回归（重点：调度行为、storage、网络策略如有使用）
```

---

## 5. 回滚方案

> ⚠️ k8s **没有原地降级**。回滚 = 灾难恢复，成本极高，所以前置条件（备份+演练）才是核心保障。

```bash
# 5.1 轻度回滚（升级后 24h 内发现局部问题）：
#   通常不回滚集群，而是修复局部（如某 addon 镜像不兼容 → 单独回滚该 addon 镜像 tag）

# 5.2 完全回滚（apiserver/etcd 层面故障，极少见）：
#   1. 停三台 master 的 apiserver/etcd/controller-manager/scheduler 静态 pod（manifests 移出）
#   2. 三台 etcd 全部按文档 01 的"恢复演练"流程从升级前快照恢复（成员信息用原集群参数）
#   3. manifests 移回（升级前版本的 manifest 需提前备份：升级前 cp -r /etc/kubernetes/manifests /root/manifests-backup-pre130/）
#   4. worker kubelet 二进制回退：apt install kubeadm/kubelet=1.29.9-* 后 systemctl restart kubelet
#   （worker 不回退也能跑：kubelet 1.30 对 apiserver 1.29 属于合法 skew，仅功能受限）
```

---

## 6. 生产环境实施注意

1. 生产升级 = 单独变更工单 + 业务方通告（全集群滚动，每台 master/worker 有秒-分钟级组件重启窗口）
2. 生产升级前**必须**在测试集群完整演练一次（含 3.4 的 CM 复查），并把差异记录进本档
3. 升级窗口避开业务高峰，预留 3 倍预计时长（镜像拉取慢/PDB 卡 drain 都会拖时间）
4. 升级后 30 天内不做其他架构变更（便于归因）
5. 1.30 稳定后规划 1.31（节奏建议：每年追 1-2 个 minor，不再出现"落后一年半"的技术债）

---

## 7. 关联文件

- 强依赖：文档 01（etcd 备份 = 回滚点）、文档 03（升级后 CM 复查）
- manifests 备份目录（升级前手工做）：`/root/manifests-backup-pre130/`
