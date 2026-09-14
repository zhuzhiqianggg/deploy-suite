# 03. kubelet 集群级 ConfigMap 合入优化配置

| 属性 | 值 |
|------|-----|
| 优先级 | **P0**（配置漂移，新节点必踩坑） |
| 风险等级 | 低（不影响存量节点，只改"新节点的配置来源"） |
| 建议实施 | 第 2 周 |
| 观察期 | 一个完整节点生命周期（建议：验证后删除重建一个测试节点） |
| 状态 | ⬜ 待实施 |

---

## 1. 背景与问题

**现状：kubelet 配置两层不一致（配置漂移）**

| 层 | 位置 | 现状 |
|----|------|------|
| 集群层（新节点的配置来源） | ConfigMap `kube-system/kubelet-config` | ❌ 旧危险配置 |
| 节点层（存量节点实际运行） | `/var/lib/kubelet/config.yaml` | ✅ 已手动铺优化版 |

集群 ConfigMap 中的危险项：

```yaml
evictionHard:
  memory.available: 100Mi     # 内存剩 100Mi 才驱逐 → 内核 OOM 先动手（已实际导致节点崩溃）
shutdownGracePeriod: 0s       # 节点关机时 Pod 立即被杀，无优雅退出
# 缺失：evictionSoft / evictionMinimumReclaim / mergeDefaultEvictionSettings
#       / systemReserved / kubeReserved
```

**已实际发生的坑**：worker04 重装重新 join 后，自动从 ConfigMap 拿到 100Mi 危险配置，必须手动替换。**任何新节点 join、节点 reset 重装，都会再次踩坑。**

**原理（学习点）**：

- kubeadm 体系的 kubelet 配置下发机制：`kubelet --config=/var/lib/kubelet/config.yaml`，该文件在**节点 join 时由 kubeadm 从集群 ConfigMap 拉取生成**，之后不再自动同步
- 因此：改 ConfigMap ≠ 改存量节点（它们用本地文件），但 = 决定**未来所有新节点**的初始配置
- 要让存量节点也更新，需在每台节点上重新拉取：`kubeadm upgrade node phase kubelet-config` 或手动替换文件后 `systemctl restart kubelet`（我们已有优化文件，走手动更简单）
- `mergeDefaultEvictionSettings: true`（v1.27+）：显式写的 eviction 配置**覆盖**内置默认，未写的**保留**内置（磁盘/inode 驱逐规则）——不开启它，自定义 evictionHard 会把内置磁盘驱逐规则整个顶掉

---

## 2. 实施前检查

```bash
# 2.1 确认 ConfigMap 当前危险项仍在
kubectl -n kube-system get cm kubelet-config -o jsonpath='{.data.kubelet}' | grep -E "memory.available|shutdownGracePeriod"
# 预期：memory.available: 100Mi / shutdownGracePeriod: 0s

# 2.2 确认优化配置文件就绪（节点层标准答案）
ls -l /root/k8s-optimizations/node-tuning/kubelet-config-optimized.yaml
# 该文件已在 8 节点全部落地（worker04 于 2026-08-25 最后一个完成）

# 2.3 记录 ConfigMap 中的"必须保留字段"（合入时不能丢）
kubectl -n kube-system get cm kubelet-config -o jsonpath='{.data.kubelet}' > /tmp/kubelet-config-current.yaml
grep -E "^(apiVersion|kind|address|authentication|authorization|cgroupDriver|healthzBindAddress|kind|port|rotateCertificates|staticPodPath|volumePluginDir)" /tmp/kubelet-config-current.yaml
# 预期：能看到 authentication/authentication/authorization/cgroupDriver 等基础字段
```

---

## 3. 实施步骤

### 3.1 生成合并后的新配置（关键：合并而非整替）

**原则**：以当前 ConfigMap 为底板（保留认证/证书/静态 pod 等基础字段），只把优化项的字段值替换进去。

```bash
# 3.1.1 备份当前 ConfigMap
kubectl -n kube-system get cm kubelet-config -o yaml > /root/k8s-optimizations/optimization-plan/backups/kubelet-config-cm-backup-$(date +%Y%m%d).yaml

# 3.1.2 用优化文件生成新的 kubelet 配置段
#      注意：优化文件里已含完整基础字段（与 ConfigMap 同源），但为安全起见仍做 diff 确认
diff <(grep -vE "^\s*#|^\s*$" /tmp/kubelet-config-current.yaml) \
     <(grep -vE "^\s*#|^\s*$" /root/k8s-optimizations/node-tuning/kubelet-config-optimized.yaml) | head -n 60
# 逐行审阅 diff：
#   - 预期出现：evictionHard 值变化、新增 evictionSoft/evictionMinimumReclaim/
#     mergeDefaultEvictionSettings/systemReserved/kubeReserved、shutdownGracePeriod 变 30s
#   - 若出现 authentication/cgroupDriver/staticPodPath 等基础字段差异 → 停下分析，
#     保留 ConfigMap 现值（优化文件生成时基于 worker05，个别路径字段可能因节点而异）
```

### 3.2 更新 ConfigMap

```bash
# 3.2.1 将优化配置作为 kubelet 键写入（--dry-run 先验证 YAML 合法）
kubectl -n kube-system create cm kubelet-config \
  --from-file=kubelet=/root/k8s-optimizations/node-tuning/kubelet-config-optimized.yaml \
  --dry-run=client -o yaml > /tmp/kubelet-config-new-cm.yaml

# 3.2.2 检查生成的 CM（确认 apiVersion/kind/data 键名正确）
grep -E "^kind:|^  name:|kubelet:" /tmp/kubelet-config-new-cm.yaml

# 3.2.3 应用（server 端校验后真正写入）
kubectl apply -f /tmp/kubelet-config-new-cm.yaml
# 预期：configmap/kubelet-config configured

# 3.2.4 验证 ConfigMap 已更新
kubectl -n kube-system get cm kubelet-config -o jsonpath='{.data.kubelet}' | grep -E "memory.available:|mergeDefaultEvictionSettings:|shutdownGracePeriod:"
# 预期：
#   memory.available: 1Gi
#   mergeDefaultEvictionSettings: true
#   shutdownGracePeriod: 30s
```

> ⚠️ `kubectl apply` 会把 `kubeadm.kubernetes.io/kubelet-config` 等注解保留在 CM 上吗？
> 注意：直接 create cm --from-file 生成的新对象**会丢失原有 CM 的 annotations/labels**。
> 若 diff 检查发现原 CM 有重要注解（如 `kubeadm.kubernetes.io/component-config` 相关），改用：
> ```bash
> # 编辑而非替换（保留元数据）：
> kubectl -n kube-system edit cm kubelet-config
> # 手工把 data.kubelet 的值整体替换为优化文件内容
> ```
> 实施时先 `kubectl -n kube-system get cm kubelet-config -o jsonpath='{.metadata.annotations}'` 确认。

### 3.3 存量节点无需操作（说明）

存量 8 节点本地 `/var/lib/kubelet/config.yaml` 已是优化版，kubelet 只读本地文件，不受 CM 变更影响。**本步骤只影响未来新节点。**

> 可选增强（不强制）：让存量节点重新从 CM 同步一次，统一"来源"，命令：
> `kubeadm upgrade node phase kubelet-config && systemctl restart kubelet`
> 逐节点做并验证（有 30s 的 kubelet 重启窗口，DaemonSet Pod 不受影响，业务 Pod 无感知）。
> 若采用，务必逐节点进行并检查 `kubectl get node <name>` Ready 状态。

---

## 4. 验证方法

```bash
# 4.1 终极验证：测试集群删除并重新加入一个节点，确认拿到新配置
#      （用 worker04 或任一可牺牲节点；以下是完整流程）

# 在 master01：
kubectl drain k8s-test-worker04 --ignore-daemonsets --delete-emptydir-data
kubectl delete node k8s-test-worker04

# 在 worker04：
kubeadm reset -f && rm -rf /etc/kubernetes/ /var/lib/kubelet/
# 重新 join（token 过期则 master01 上 kubeadm token create --print-join-command）
kubeadm join apiserver.cluster.local:6443 --token <token> --discovery-token-ca-cert-hash <hash>

# 回到 master01 验证新节点的 kubelet 配置：
kubectl get node k8s-test-worker04   # 预期 Ready
ssh root@192.168.10.106 'grep -E "memory.available:|mergeDefaultEvictionSettings:" /var/lib/kubelet/config.yaml'
# 预期：memory.available: 1Gi / mergeDefaultEvictionSettings: true
# ✅ 到这里说明 ConfigMap 是新节点的唯一配置来源且已修正，本项完成

# 4.2 重新加入后按《node-tuning runbook》补节点级调优
#     （sysctl / chrony / ring buffer / vmtools timesync disable——项目记忆中有完整清单）
```

---

## 5. 回滚方案

```bash
kubectl apply -f /root/k8s-optimizations/optimization-plan/backups/kubelet-config-cm-backup-YYYYMMDD.yaml
kubectl -n kube-system get cm kubelet-config -o jsonpath='{.data.kubelet}' | grep memory.available
# 预期：100Mi（回到旧配置——仅影响之后 join 的新节点）
```

---

## 6. 生产环境实施注意

1. 生产实施前，在测试集群完成 4.1 的"删节点重 join"全流程验证
2. 生产集群的 ConfigMap 操作同 3.2，但**先 `kubectl get cm -o yaml` 备份到运维仓库**
3. 若生产近期有节点扩容计划，本项应排在扩容之前完成（否则新节点还会拿到危险配置）
4. 未来 k8s 升级（文档 08）时，`kubeadm upgrade` 会重新生成该 CM——**升级后必须复查** CM 是否被 kubeadm 重置回默认值（这是本配置漂移问题的长效风险点）

---

## 7. 关联文件

- 优化配置源：`/root/k8s-optimizations/node-tuning/kubelet-config-optimized.yaml`
- 备份：`backups/kubelet-config-cm-backup-YYYYMMDD.yaml`
