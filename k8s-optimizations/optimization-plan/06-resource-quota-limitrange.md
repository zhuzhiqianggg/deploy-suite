# 06. ResourceQuota + LimitRange 铺设（ns 级爆炸半径控制）

| 属性 | 值 |
|------|-----|
| 优先级 | P1 |
| 风险等级 | 低（配额偏松时几乎无感；设太紧会导致 Pod 创建被拒） |
| 建议实施 | 持续迭代（存量 ns 分批 + 新 ns 建立时强制带上） |
| 观察期 | 每个 ns 铺设后观察 1 个发版周期 |
| 状态 | ⬜ 待实施 |

---

## 1. 背景与问题

**现状**：115 个业务 namespace，**零 ResourceQuota、零 LimitRange**。

**原理（学习点）**：

- 防线分工：
  - `requests/limits`（Pod 级）：业务自己声明——**靠自觉**
  - `ResourceQuota`（ns 级）：硬约束 ns 总量——**靠制度**。没有它，任何业务一次配错（如 memory limit 多写一个 0）就能压死节点并拖垮同节点的其他业务
  - `LimitRange`（ns 级兜底）：给**没写** requests/limits 的 Pod 自动注入默认值——堵"漏网之鱼"
- 注意 ResourceQuota 的两个行为细节：
  1. 一旦 ns 有 Quota，该 ns 内**新建** Pod 必须显式声明 requests/limits，否则被直接拒绝（`Forbidden: exceeded quota`）——所以铺设前要确认存量 CI/CD 模板里有资源字段（本集群业务普遍已配，风险低）
  2. Quota 只约束**新建/更新**，存量 Pod 不受影响（不会驱逐运行中的 Pod）
- `pods` 计数配额：防"副本数风暴"（如错误配置 replicas: 1000）

**配额分档设计**（按业务体量）：

| 档位 | 适用 | requests.cpu | requests.memory | limits.cpu | limits.memory | pods |
|------|------|-------------|-----------------|-----------|--------------|------|
| small | 前端/轻量工具类 ns | 4 | 8Gi | 8 | 16Gi | 30 |
| medium | 常规后端/中间件 ns | 8 | 16Gi | 16 | 32Gi | 50 |
| large | DB/ES/大数据类 ns | 16 | 32Gi | 24 | 48Gi | 80 |

> 分档依据：单 worker 节点 8C/30G。large 档 requests 上限 16C 保证单 ns 至多"占满"两个节点，不会横扫全集群。

---

## 2. 实施前检查

```bash
# 2.1 统计每个业务 ns 的当前实际用量（定档依据）
kubectl describe ns | grep -B 20 "Resource Quota\|No resource quota" | head -n 5   # 快速看有无
# 用实际用量列表（推荐）：
for ns in $(kubectl get ns -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep -vE "^(kube-|calico|tigera|ingress|default|kuboard|logging|csi)"); do
  req_cpu=$(kubectl get pods -n $ns -o json | jq '[.items[]?.spec.containers[]?.resources.requests.cpu // "0m" | if test("m$") then sub("m";"")|tonumber else tonumber*1000 end] | add // 0' 2>/dev/null)
  req_mem=$(kubectl get pods -n $ns -o json | jq '[.items[]?.spec.containers[]?.resources.requests.memory // "0" | sub("Gi$";"Gi") ] | length' 2>/dev/null)
  echo "$ns: ${req_cpu}m"
done | sort -t: -k2 -rn | head -n 20
# 按输出给每个 ns 定档：当前 requests 在档位的 50% 以下为安全档

# 2.2 抽查业务 manifest 是否都带资源字段（Quota 生效后无字段会创建失败）
kubectl get pods -n trace-beosin-saas-test -o json | jq -r '[.items[].spec.containers[] | select(.resources.requests == null)] | length'
# 预期：0（无缺失）。若非 0，列出具体工作负载补齐后再上 Quota
```

---

## 3. 实施步骤

### 3.1 定档并应用（单个 ns 示例：medium 档）

```bash
# 模板已备好：scripts/quota-template.yaml（含三档 Quota + LimitRange）
# 单 ns 应用示例：
cat /root/k8s-optimizations/optimization-plan/scripts/quota-template.yaml | sed 's/<NAMESPACE>/trace-beosin-saas-test/' | kubectl apply -f -
# （模板中默认带 medium 档注释，替换 NAMESPACE 后按需取消对应档位注释）

# 预期输出：
#   resourcequota/medium-quota created
#   limitrange/default-limits created
```

### 3.2 批量铺设（存量 ns 分批）

```bash
# 每批 10 个 ns，第一批建议从"轻量前端类"开始（影响最小）
kubectl get ns -o name | grep -vE "kube-|calico|tigera|ingress|default$|kuboard|logging|csi" | head -n 10

# 逐个：定档 → 应用（同 3.1）→ 观察 1 天 → 下一批
```

### 3.3 新 ns 规范（制度化）

新业务 ns 建立时**必须同时提交 Quota**（写入团队流程）：

```bash
# 新 ns 标准创建三件套
kubectl create ns <new-ns>
cat scripts/quota-template.yaml | sed 's/<NAMESPACE>/<new-ns>/' | kubectl apply -f -
# + 该 ns 的 secret-registry（项目惯例）
```

---

## 4. 验证方法

```bash
# 4.1 Quota 生效与用量查看
kubectl describe quota -n trace-beosin-saas-test
# 预期：LIMIT 列显示配额，USED 列显示当前用量（应远小于 LIMIT）

# 4.2 功能验证：超配额的 Pod 被拒绝（拿测试 ns 验证一次）
kubectl create ns quota-test -o yaml --dry-run=client | kubectl apply -f -
cat scripts/quota-template.yaml | sed 's/<NAMESPACE>/quota-test/' | kubectl apply -f -
kubectl run boom -n quota-test --image=busybox:1.36 --restart=Never --limits=memory=99Gi
# 预期：Error from server (Forbidden): exceeded quota ...（证明防线有效）
kubectl delete ns quota-test

# 4.3 LimitRange 兜底验证（无资源字段的 Pod 被自动注入默认值）
kubectl run nores -n <已铺LimitRange的ns> --image=busybox:1.36 --restart=Never -- sleep 60
kubectl get pod nores -n <ns> -o jsonpath='{.spec.containers[0].resources}' | jq
# 预期：自动出现 default-cpu/default-memory 形态的 requests/limits
# （注意：若 ns 同时有 Quota，此 Pod 会因"没写字段"直接被拒——LimitRange 的 default 只对
#   "没配 Quota 的 ns"或"Quota 不含资源维度"时生效。两者同时存在时 Quota 优先，
#   这是预期行为：有制度就按制度，兜底只给没制度的场景）

# 4.4 一个发版周期观察
#   - CI/CD 发版无 Forbidden 报错（若出现：该业务实际用量已超档，升档处理）
#   - kubectl describe quota 各 ns USED 无贴脸 LIMIT
```

---

## 5. 回滚方案

```bash
kubectl delete quota medium-quota -n <ns>
kubectl delete limitrange default-limits -n <ns>
# 秒级生效，运行中 Pod 不受任何影响
```

---

## 6. 生产环境实施注意

1. 生产 ns 用量与测试不同，**重新按 2.1 步骤定档**，不要照抄测试的分档
2. 生产首批选非核心业务 ns，跑 3 天再扩大
3. Quota 的 `USED` 与 `LIMIT` 差值 <20% 时提前升档（避免发版被拒阻塞业务）
4. 系统命名空间（kube-system/calico-system 等）**不上 Quota**（系统组件有 PriorityClass，配额可能拒掉关键组件）

---

## 7. 关联文件

- 模板：`scripts/quota-template.yaml`（三档 Quota + LimitRange，带逐字段注释）
