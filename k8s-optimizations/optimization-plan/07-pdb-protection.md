# 07. 业务 PDB（PodDisruptionBudget）保护

| 属性 | 值 |
|------|-----|
| 优先级 | P1（节点运维的"安全带"，是文档 05 迁移的前置建议项） |
| 风险等级 | 低（纯保护性对象，配错最多是"挡住 drain"，不会伤害业务） |
| 建议实施 | 持续迭代（建议在 05-master-taint 之前完成核心业务铺设） |
| 观察期 | 与下次 drain 操作联动验证 |
| 状态 | ⬜ 待实施 |

> **2026-08-25 审计基线**（`pdb-audit.sh` 实测）：需补 PDB 的多副本 Deployment 仅 1 个（`data-lianantech-saas-release/llm-mcp-server-web-bj`，2 副本）；单副本业务 Deployment 约 40+ 个（api/bms/common 全系列 front/web 都是单副本）——单副本清单是后续扩副本+反亲和的主要改造对象。

---

## 1. 背景与问题

**现状**：PDB 仅系统组件有（calico-typha/metrics-server/alertmanager/prometheus 等 5 个），**全部业务 Deployment 无 PDB**。

**原理（学习点）**：

- PDB 防的不是崩溃，是**主动运维操作**（`kubectl drain` / 节点升级 / 集群升级）时的副本同时下线：
  - drain 要驱逐 Pod 前会先问 PDB："如果驱逐这个 Pod，可用副本数还满足 minAvailable 吗？"
  - 不满足 → 驱逐被**阻塞重试**，直到该 Deployment 在其他节点补齐副本
  - 这就是 2026-08-24 drain worker04 时 alertmanager 没有中断的原因（它有 PDB）
- 两种写法的选择：
  - `minAvailable: 1`：多副本服务用（任何时候至少 1 个活着）
  - `maxUnavailable: 1`：单副本服务用（允许逐个替换，配合滚动更新）
- **单副本服务 + PDB 的正确姿势**：单副本 Deployment 的 PDB 用 `maxUnavailable: 1` 只能保证"同时最多死 1 个"（对单副本本身无保护意义）；真正的解法是**给单副本服务加反亲和 + 扩到 2 副本**，PDB 才有意义
- 注意：PDB 只约束**主动驱逐**（eviction API），节点掉电/OOM 被杀这类被动故障它不管（那是多副本/反亲和的职责）

---

## 2. 实施前检查

```bash
# 2.1 审计：找出所有"多副本但无 PDB"的 Deployment（脚本已备好）
bash /root/k8s-optimizations/optimization-plan/scripts/pdb-audit.sh
# 预期输出分两栏：
#   [需补 PDB - 多副本]   ns/deploy名 副本数
#   [高危 - 单副本无反亲和] ns/deploy名 1
# （单副本栏是"建议扩副本+反亲和"的候选清单，不强制本次处理）

# 2.2 确认现有 PDB 不误伤（历史遗留的 PDB minAvailable 配置过严会挡 drain）
kubectl get pdb -A -o custom-columns="NS:.metadata.namespace,NAME:.metadata.name,MINAVAIL:.spec.minAvailable,MAXUNAVAIL:.spec.maxUnavailable,ALLOWED:.status.disruptionsAllowed"
# 预期：ALLOWED ≥ 1（为 0 且副本健康说明配置过严，drain 会被永久卡住）
```

---

## 3. 实施步骤

### 3.1 多副本 Deployment 批量补 PDB

```bash
# 3.1.1 生成核心业务（≥2 副本）的 PDB 清单（先 dry-run 审阅）
bash scripts/pdb-audit.sh --generate-yaml > /tmp/pdb-batch.yaml
# 审阅内容：每个多副本 Deployment 一个 PDB，minAvailable 自动取 max(1, replicas-1)

# 3.1.2 应用
kubectl apply -f /tmp/pdb-batch.yaml
# 预期：poddisruptionbudget.policy/xxx created （每业务一条）

# 3.1.3 检查 PDB 状态健康
kubectl get pdb -A | awk '$NF==0 && $3!~/N\/A/ {print}' 
# 预期：无输出（disruptionsAllowed=0 且非 minAvailable=N/A 的行说明副本不满或配置问题）
```

### 3.2 有状态单副本服务（MySQL/ES 等）的专项处理

这类是**最高危**对象（单副本 + 有状态 + drain 即中断）。两个选择：

**方案 A（推荐，测试环境先做）**：扩副本 + 反亲和 + PDB

```yaml
# 示例：StatefulSet 补充（patch 方式，不整替业务模板）
spec:
  replicas: 2                       # MySQL 主从已有则跳过；单机版需业务侧评估
  podAntiAffinity:                  # 两个副本强制分散节点
    requiredDuringSchedulingIgnoredDuringExecution:
    - labelSelector:
        matchLabels: {app: db-mysql}
      topologyKey: kubernetes.io/hostname
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata: {name: db-mysql-pdb, namespace: db-beosin-test-dbmodes}
spec:
  minAvailable: 1                   # 从库可驱逐，主库在时 drain 不中断
  selector: {matchLabels: {app: db-mysql}}
```

**方案 B（业务不允许扩副本时）**：接受 drain 窗口中断，但把这类服务登记到《节点维护检查单》，drain 前人工确认窗口。

### 3.3 制度化：新 Deployment 模板带上 PDB

CI/CD 的 Deployment 模板中追加（业务方配合）：

```yaml
# 模板片段：所有 ≥2 副本的 Deployment 默认携带
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata: {name: "{{app}}-pdb", namespace: "{{ns}}"}
spec:
  minAvailable: 1
  selector: {matchLabels: {app: "{{app}}"}}
```

---

## 4. 验证方法

```bash
# 4.1 覆盖率：多副本 Deployment 的 PDB 覆盖率应达 100%
bash scripts/pdb-audit.sh | grep -c "需补 PDB"
# 预期：0

# 4.2 功能验证：拿一个测试业务做真实 drain 演练
# 选一个双副本业务所在的 worker：
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data --timeout=10m
# 验证点：
#   - drain 过程中业务始终有 ≥1 个 Ready（kubectl get deploy -n <ns> <name> 全程 1/2→2/2）
#   - drain 成功完成后业务恢复 2/2
kubectl uncordon <node>

# 4.3 PDB 状态总检（每次大变更后跑）
kubectl get pdb -A --no-headers | grep -v "1 " | head    # 人工审阅非健康行
```

---

## 5. 回滚方案

```bash
kubectl delete pdb <name> -n <ns>    # 删除即失效，无副作用
```

---

## 6. 生产环境实施注意

1. 生产 PDB minAvailable 不要超过必要值（如 3 副本配 minAvailable: 3 = 永远不能 drain，会卡死运维）
2. 有状态服务的扩副本方案（3.2 方案 A）必须业务侧确认数据一致性（MySQL 主从、ES 副本分片）后才能做
3. PDB 铺完后做一次 drain 演练（同 4.2），否则不知道配置对不对

---

## 7. 关联文件

- 审计脚本：`scripts/pdb-audit.sh`（支持 --generate-yaml 生成批量 PDB）
