# 04. Calico IPIP 模式优化：Always → CrossSubnet

| 属性 | 值 |
|------|-----|
| 优先级 | P1（免费性能提升） |
| 风险等级 | 低（单条 patch，秒级回滚，但需观察路由收敛） |
| 建议实施 | 第 2-3 周 |
| 观察期 | 48 小时（重点：Pod 重建后的路由收敛、跨节点连通性） |
| 状态 | ⬜ 待实施 |

---

## 1. 背景与问题

**现状**：`default-ipv4-ippool` 的 `ipipMode: Always`——所有 Pod 间流量无论目的地都做 IPIP 封装。

**关键事实**：本集群**全部 8 个节点都在同一个二层子网 192.168.10.0/24**（VMware 同一 portgroup），节点之间本来就二层直达。

**原理（学习点）**：

- IPIP 封装：把 Pod IP 包（`100.x.x.x`）外面再套一层节点 IP 包（`192.168.10.x`）。代价：
  - 每包额外 20 字节头 + 封装/解封装 CPU 开销（约 3-5%）
  - **MTU 缩水**：物理网卡 1500 时，Pod 侧有效 MTU 变 1480（IPIP）/1440（叠加其他），大包要么分片要么依赖 TCP MSS 钳制
- `ipipMode` 三种模式的本质：
  - `Always`：一律封装（适合节点跨子网且不想开 BGP 的场景）
  - `CrossSubnet`：**仅当对端节点在不同子网时才封装**；同子网直接路由裸包
  - `Never`：从不封装（需要底层网络能路由 Pod CIDR）
- 本集群同子网 → `CrossSubnet` 下所有流量**零封装直发**，纯粹把白交的税退回来

**预期收益**：跨节点 Pod 间吞吐 +10~20%，CPU 微降，MTU 恢复。同时保留跨子网扩展能力（未来加异地节点时自动启用封装，无需再改）。

---

## 2. 实施前检查

```bash
# 2.1 确认所有节点确实同子网（任一节点上）
ip -4 addr show | grep "192.168.10"
# 预期：所有节点 192.168.10.x/24（当前 100/104/105/101/102/103/106/107）

# 2.2 确认当前 ippool 模式
kubectl get ippool default-ipv4-ippool -o jsonpath='{.spec.ipipMode}{"\n"}'
# 预期：Always

# 2.3 记录基线性能（优化后对比用）
# 在两个不同节点各起一个测试 Pod，做一次 iperf3 / 大文件 dd 基线
kubectl run perf-a --image=registry.cn-hangzhou.aliyuncs.com/acs/iperf3:latest --restart=Never -n default
kubectl run perf-b --image=registry.cn-hangzhou.aliyuncs.com/acs/iperf3:latest --restart=Never -n default
# 等 Running 后记录 IP，iperf3 服务端/客户端跑 60s，记下吞吐值（示例）：
# kubectl exec perf-a -- iperf3 -s -D
# kubectl exec perf-b -- iperf3 -c <perf-a的IP> -t 60
# 基线记录：______ Mbits/s（填到本行，变更后对比）
kubectl delete pod perf-a perf-b -n default --force --grace-period=0
```

---

## 3. 实施步骤

```bash
# 3.1 备份当前 ippool 定义
kubectl get ippool default-ipv4-ippool -o yaml > /root/k8s-optimizations/optimization-plan/backups/ippool-backup-$(date +%Y%m%d).yaml

# 3.2 单条 patch 切换模式
kubectl patch ippool default-ipv4-ippool --type merge -p '{"spec":{"ipipMode":"CrossSubnet"}}'
# 预期：ippool.crd.projectcalico.org/default-ipv4-ippool patched

# 3.3 确认已生效
kubectl get ippool default-ipv4-ippool -o jsonpath='{.spec.ipipMode}{"\n"}'
# 预期：CrossSubnet
```

**变更生效机制**：Calico 的 felix（节点代理）watch ippool 变化，自动更新节点路由与 tunl0 使用策略，**无需重启 calico-node**。模式切换是热生效的。

---

## 4. 验证方法（观察期 48 小时）

```bash
# 4.1 立即验证：跨节点 Pod 连通性（最关键）
kubectl run net-test --image=busybox:1.36 --restart=Never -n default -- sleep 3600
kubectl exec net-test -- ping -c 3 <另一节点上的Pod IP>       # 跨节点 Pod IP
kubectl exec net-test -- ping -c 3 kubernetes.default.svc      # 集群服务
# 预期：全部通，0% 丢包

# 4.2 路由验证：同子网路由不再走 tunl0 封装
# 在任一节点：
ip route | grep "100.64"
# Always 模式预期（旧）：100.64.x.0/26 via 192.168.10.x dev tunl0  onlink
# CrossSubnet 模式预期（新）：100.64.x.0/26 via 192.168.10.x dev ens33  ← 出口变成物理网卡
# （部分条目变化即说明生效，felix 逐节点刷新）

# 4.3 MTU 验证（封装去除后 Pod 侧 MTU 应恢复）
kubectl exec net-test -- sh -c 'ping -c 2 -M do -s 1472 <另一节点Pod IP>'
# 预期：通（1472 payload + 28 header = 1500，证明无封装开销；IPIP 模式下此包会失败）

# 4.4 性能对比（与 2.3 基线）
# 重复 iperf3 步骤，吞吐提升 10%+ 即符合预期

# 4.5 48h 观察项
#   - calico-node 日志无 error：kubectl logs -n calico-system -l k8s-app=calico-node --tail=50 | grep -i error
#   - 无 Pod 网络相关 CrashLoopBackOff
#   - 重启一台节点（或等自然滚动）后 Pod 网络自动恢复（路由收敛验证）
kubectl delete pod net-test -n default --force --grace-period=0
```

---

## 5. 回滚方案

```bash
kubectl patch ippool default-ipv4-ippool --type merge -p '{"spec":{"ipipMode":"Always"}}'
# felix 热切回，秒级生效；之后抽查 4.1/4.2 确认恢复封装路由
```

---

## 6. 生产环境实施注意

1. 生产如有**跨子网节点**（如未来异地机房 member），CrossSubnet 会自动对跨子网流量启用封装——这正是期望行为，无需干预
2. 避免与节点重装/大规模 Pod 重建同时进行（便于归因）
3. 生产实施时间选业务低峰，虽然 patch 本身无感，但路由刷新瞬间的长连接（如 ES 节点间）理论上可能受毫秒级影响
4. 若生产使用 `vxlanMode` 而非 IPIP（本集群是 IPIP），同样逻辑适用：`vxlanMode: CrossSubnet`

---

## 7. 关联文件

- 备份：`backups/ippool-backup-YYYYMMDD.yaml`
