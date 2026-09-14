# 05. Master 节点隔离：打 taint + 业务 Pod 迁移

| 属性 | 值 |
|------|-----|
| 优先级 | **P0**（控制面稳定性，master01 CPU 已 78%） |
| 风险等级 | **中**（涉及大量业务 Pod 迁移，需分批+低峰期） |
| 建议实施 | 第 3-4 周（建议在 07-PDB 铺开后执行） |
| 观察期 | 迁移完成后 7 天（API 延迟/etcd 指标对比） |
| 状态 | ⬜ 待实施 |

---

## 1. 背景与问题

**现状**：三个 master 节点**零 taint**，上面跑着 100+ 业务 Pod（master02 46 个 / master01 40 个 / master03 38 个），含 MySQL、Elasticsearch、trace 全家桶等重 IO 业务。master01 CPU 78%、内存 74%。

**原理（学习点）**：

- 控制面三件套（apiserver/etcd/controller-manager）中，**etcd 对延迟极端敏感**：它承诺写延迟 P99 < 10ms。etcd 是纯内存 + 磁盘 WAL 的架构，一次 fsync 慢了就会导致：
  - 心跳（默认 100ms）超时 → follower 认为 leader 挂了 → **发起选举**
  - 选举期间（通常 1-2s，极端 5-15s）**整个集群 API 冻结**：所有 kubectl/watch/调度/控制器全部停摆
- MySQL/ES 这类业务的 IO 模式（大量 fsync、页缓存刷脏、CPU 尖峰）正是 etcd 的天敌
- taint（污点）是"调度层的负面偏好"：`node-role.kubernetes.io/control-plane:NoSchedule` 让调度器不再把普通 Pod 放上来；系统组件（calico/kube-proxy/coredns 等）自带 toleration（容忍）不受影响
- **为什么 sealos 装出来没有 taint**：sealos 部署 k8s 默认会保留 kubeadm 的控制面 taint，但历史上（可能为了利用 master 资源）被手动移除了。kubeadm 默认 taint 是 `node-role.kubernetes.io/master:NoSchedule`（1.24+ 改名为 control-plane）

**收益**：控制面资源专用后，etcd 选举次数应归零，API P99 延迟显著下降，集群抗并发能力提升。

---

## 2. 实施前检查

```bash
# 2.1 确认当前 master 上业务 Pod 清单（迁移计划的输入）
kubectl get pods -A --field-selector status.phase=Running -o json | jq -r '
  .items[]
  | select(.spec.nodeName | test("master"))
  | select(.metadata.namespace | test("^(kube-system|calico|tigera|kuboard|logging|ingress|csi)" ) | not)
  | "\(.metadata.namespace)\t\(.metadata.name)"' | sort | head -n 60

# 2.2 确认 master 资源现状（基线，迁移后对比）
kubectl top nodes | grep master

# 2.3 确认 worker 侧容量充足（46+40+38=124 个 Pod 要落到 5 个 worker）
kubectl top nodes | grep worker
# 粗算：5 worker 目前 ~145 个 Pod，再接 124 个 → 平均每节点 +25。
# 若 worker 内存水位将 >85%，先扩容/清理（如 worker04 目前只有 9 个 Pod，有大量余量）

# 2.4 确认业务有 PDB（强烈建议先做文档 07，否则 drain 时单副本服务直接中断）
kubectl get pdb -A --no-headers | wc -l
# 现状仅 5 个系统 PDB → 迁移前至少给"单副本有状态服务"（mysql/es）人工确认可接受中断窗口

# 2.5 确认 worker 上有业务所需镜像（避免迁移卡镜像拉取，尤其 quay.io 源）
# （经验：alertmanager 曾因 master03 缺 quay.io 镜像卡 PDB。DNS 修复后此风险降低，仍建议预检）
# 抽查迁移目标节点镜像列表是否含 quay.io/registry 关键镜像
```

---

## 3. 实施步骤

**总体策略**：一次只处理一台 master → 打 taint（阻断新调度）→ drain（驱逐存量）→ 验证 → 下一台。从 master03 开始（承载业务相对最少），master01 最后（有 sealos.hub registry 和 lvscare 等额外角色，见 3.4 特殊处理）。

### 3.1 第一台：master03（192.168.10.105）

```bash
# 3.1.1 打 taint（立即阻止新 Pod 调度上来；存量 Pod 不受影响）
kubectl taint nodes k8s-test-master03 node-role.kubernetes.io/control-plane:NoSchedule
# 预期：node/k8s-test-master03 tainted

# 3.1.2 低峰期 drain（驱逐全部业务 Pod；--ignore-daemonsets 保留系统组件）
kubectl drain k8s-test-master03 --ignore-daemonsets --delete-emptydir-data --timeout=30m
# 注意：
#   - 若被 PDB 卡住（"Cannot evict pod as it would violate the pod's disruption budget"）
#     → 等待它自己重试（替换副本先在别处 Ready 后即可驱逐），或临时调低该 PDB minAvailable
#   - 若卡镜像拉取 → 参考文档 01 的经验：ctr export/import 手工搬镜像
#   - 单副本有状态 Pod（mysql 等）驱逐 = 直接中断，务必低峰 + 事先通知业务方

# 3.1.3 验证迁移结果
kubectl get pods -A --field-selector spec.nodeName=k8s-test-master03 --no-headers | wc -l
# 预期：只剩 DaemonSet（calico-node/kube-proxy/csi-node/fluent-bit/node-exporter 等 ~8 个）
kubectl get pods -A --field-selector spec.nodeName=k8s-test-master03 --no-headers | awk '{print $1,$2,$4}'

# 3.1.4 验证漂移后的 Pod 全部恢复
kubectl get pods -A | grep -vE "Running|Completed" | head
# 逐个确认无 Evicted 遗留 / 无 CrashLoopBackOff

# 3.1.5 验证 master03 资源回落
kubectl top node k8s-test-master03
# 预期：CPU 显著下降（控制面组件用量）

# 3.1.6 观察一天再进行下一台
```

### 3.2 第二台：master02（192.168.10.104）

重复 3.1 的全部步骤（taint → drain → 验证）。

### 3.3 第三台：master01（192.168.10.100，特殊处理）

master01 额外承载：sealos.hub registry（`192.168.10.100 sealos.hub`）、集群 VIP 后端等。**注意：sealos.hub 是 registry 容器（非 k8s Pod），drain 不会动它**，可正常 drain。但迁移后需确认：

```bash
# drain 前确认 sealos.hub registry 进程与 drain 无关
crictl ps | grep -i registry || docker ps 2>/dev/null | grep -i registry
# 预期：registry 以独立容器运行（host 网络），drain 不影响

# 然后执行同 3.1 流程
kubectl taint nodes k8s-test-master01 node-role.kubernetes.io/control-plane:NoSchedule
kubectl drain k8s-test-master01 --ignore-daemonsets --delete-emptydir-data --timeout=30m
```

### 3.4 补充：防止系统 ns 的 Deployment 漂移后失控

CoreDNS 目前有 2 副本跑在 master01/02 上（自带 control-plane toleration）。drain 后它们会自动重建到 master（有 toleration）——这是**正确行为**（CoreDNS 属于系统组件，留在 master 上没问题）。无需干预，验证 4 副本都在即可：

```bash
kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide
# 预期：4 副本全部 Running（分布不限 master/worker）
```

---

## 4. 验证方法（观察期 7 天）

```bash
# 4.1 taint 持久化确认（三台都有）
kubectl get nodes -o custom-columns="NAME:.metadata.name,TAINTS:.spec.taints"

# 4.2 业务 Pod 无残留 master
kubectl get pods -A --field-selector spec.nodeName=k8s-test-master01 -o name | wc -l   # 只剩 DS
kubectl get pods -A --field-selector spec.nodeName=k8s-test-master02 -o name | wc -l
kubectl get pods -A --field-selector spec.nodeName=k8s-test-master03 -o name | wc -l

# 4.3 master 资源对比（与 2.2 基线）
kubectl top nodes | grep master
# 预期：CPU/内存显著回落（目标：CPU < 30%）

# 4.4 API 延迟对比（迁移前后）
kubectl get --raw='/metrics' | grep -E 'apiserver_request_duration_seconds_bucket\{.*verb="LIST".*resource="pods"' | tail -n 5
# （若已接 Prometheus/kuboard，直接看 apiserver 请求延迟图更直观）

# 4.5 etcd 健康与选举指标（核心验证目标）
ssh root@192.168.10.100 'curl -s http://127.0.0.1:2381/metrics 2>/dev/null | grep -E "^etcd_server_leader_changes_seen_total|^etcd_disk_wal_fsync_duration_seconds_bucket" | head -n 6'
# etcd metrics 端口 2381 已在 manifest 开放（http://0.0.0.0:2381）
# 预期：leader_changes_seen_total 迁移后 7 天内不再增长

# 4.6 全集群 Pod 健康总检
kubectl get pods -A | grep -vE "Running|Completed" | wc -l
# 预期：接近 0（仅已知的 ImagePullBackOff 业务问题项）
```

---

## 5. 回滚方案

```bash
# 任一阶段异常（业务大面积异常/漂移失败），移除 taint 并让业务回流：
kubectl taint nodes k8s-test-master03 node-role.kubernetes.io/control-plane:NoSchedule-
# （末尾减号 = 删除该 taint）
# 已驱逐的 Pod 会经调度器重新均衡（部分可能回到 master），业务恢复

# 更保守的回滚（只恢复调度、不主动迁移）：
# 仅移除 taint 即可，无需其他操作
```

---

## 6. 生产环境实施注意

1. **生产执行前必须**：测试集群完整跑过三台迁移 + 7 天观察期
2. 生产 drain 窗口：每台单独安排低峰期（如周五 22:00 后），间隔 ≥1 天
3. 生产 master 上的单副本有状态服务（MySQL/ES 等）迁移 = 有计划中断，需提前与业务方确认窗口与影响
4. 迁移完成后，把"master 不跑业务"写入集群规范（新业务 ns 不得手工调度到 master）
5. 若生产 master 配置高于测试环境（如 16C+），迁完后 master 资源利用率会很低——这是**预期行为**（控制面专用），不是浪费

---

## 7. 关联文件

- 无独立脚本（全程 kubectl 命令，按本文档执行）
- 依赖：文档 07（PDB）建议先行；文档 02（DNS）应已完成（降低漂移后镜像拉取失败率）
