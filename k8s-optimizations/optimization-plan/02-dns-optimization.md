# 02. DNS 链路修复（节点多上游 + CoreDNS 去 8.8.8.8）

| 属性 | 值 |
|------|-----|
| 优先级 | **P1**（已实际造成集群性故障） |
| 风险等级 | 低（配置变更，秒级回滚） |
| 建议实施 | 第 1 周 |
| 观察期 | 48 小时（观察镜像 pull 错误率与解析延迟） |
| 状态 | ⬜ 待实施 |

---

## 1. 背景与问题

**现状（两处缺陷叠加）**：

1. **节点层**：所有节点 systemd-resolved 仅单上游 `223.5.5.5`，实测阵发超时（一轮 5 次挂 2 次）、平均延迟 400ms+（正常 <50ms）
2. **集群层**：CoreDNS forward 上游 `223.5.5.5 114.114.114.114 8.8.8.8`——**8.8.8.8 国内基本不可达**

**已造成的实际故障**：
- worker04/master01/master02 镜像 pull 报 `lookup swr.cn-east-3.myhuaweicloud.com on 127.0.0.53:53: i/o timeout`（最初被误判为 worker04 网卡问题）
- 任何节点拉新镜像都可能撞上（containerd 走节点 DNS 解析 registry）

**原理（学习点）**：

- 集群 DNS 有**两条独立链路**，要分开修：
  - **Pod 内解析**：Pod → CoreDNS（cluster.local 域内查询）→ CoreDNS `forward` 插件 → 外部上游
  - **节点进程解析**：containerd/kubelet/chrony 等 → systemd-resolved（127.0.0.53 stub）→ 节点上游
  - 镜像 pull 报 DNS 超时是**节点链路**的问题；Pod 内访问外网慢是**CoreDNS 链路**的问题
- CoreDNS `forward` 插件对多上游是**轮询/随机**选择。含 8.8.8.8 时，约 1/3 请求落到不可达上游，要等满超时（默认 2s）才 fallback → **1/3 的外部解析白等 2 秒**
- systemd-resolved 单上游 = 零容错；`DNS=` 写多个地址时 resolved 会自动择优/故障切换

---

## 2. 实施前检查

```bash
# 2.1 确认当前故障仍存在（在任一节点，直连上游测 20 次统计成功率）
ok=0; for i in $(seq 1 20); do dig +time=2 +tries=1 @223.5.5.5 swr.cn-east-3.myhuaweicloud.com +short >/dev/null 2>&1 && ok=$((ok+1)); done; echo "223.5.5.5: $ok/20"
ok=0; for i in $(seq 1 20); do dig +time=2 +tries=1 @114.114.114.114 swr.cn-east-3.myhuaweicloud.com +short >/dev/null 2>&1 && ok=$((ok+1)); done; echo "114.114.114.114: $ok/20"
ok=0; for i in $(seq 1 20); do dig +time=2 +tries=1 @119.29.29.29 swr.cn-east-3.myhuaweicloud.com +short >/dev/null 2>&1 && ok=$((ok+1)); done; echo "119.29.29.29: $ok/20"
# 预期：三个国内源接近 20/20（若某源 <15/20，从候选列表剔除）

# 2.2 确认节点 resolved 现状
resolvectl status | grep -A 3 "Link 2\|Link.*ens" | head -n 10
# 预期：Current DNS Server: 223.5.5.5（单上游现状确认）

# 2.3 确认 CoreDNS Corefile 现状
kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' | grep forward
# 预期：forward . 223.5.5.5 114.114.114.114 8.8.8.8 {
```

---

## 3. 实施步骤

### 3.1 修复 CoreDNS（集群层）

```bash
# 3.1.1 导出当前 Corefile 备份
kubectl -n kube-system get cm coredns -o yaml > /root/k8s-optimizations/optimization-plan/backups/coredns-cm-backup-$(date +%Y%m%d).yaml

# 3.1.2 编辑 ConfigMap
kubectl -n kube-system edit cm coredns
# 找到 forward 行，修改前：
#   forward . 223.5.5.5 114.114.114.114 8.8.8.8 {
#       max_concurrent 1000
#   }
# 修改后（去掉 8.8.8.8，加 119.29.29.29）：
#   forward . 223.5.5.5 114.114.114.114 119.29.29.29 {
#       max_concurrent 1000
#   }

# 3.1.3 滚动重启 CoreDNS 使配置生效
kubectl -n kube-system rollout restart deploy coredns
kubectl -n kube-system rollout status deploy coredns --timeout=120s
# 预期：successfully rolled out
```

### 3.2 修复节点层（所有 8 节点）

**用脚本批量做**（推荐，从 master01 执行，脚本自动 ssh 全部节点）：

```bash
bash /root/k8s-optimizations/optimization-plan/scripts/dns-multi-upstream-fix.sh
# 脚本行为（echo 所有命令）：
#   1. 遍历 8 个节点（本机直接执行，其余 ssh）
#   2. 备份 /etc/systemd/resolved.conf
#   3. 写入 DNS=223.5.5.5 114.114.114.114 119.29.29.29
#   4. systemctl restart systemd-resolved
#   5. 每节点验证：resolvectl status + dig 10 次统计
```

**手工单节点方式**（理解原理用，生产批量仍用脚本）：

```bash
# 1. 备份
cp /etc/systemd/resolved.conf /etc/systemd/resolved.conf.bak-$(date +%Y%m%d)

# 2. 修改 [Resolve] 段（保留其他行不动）
sed -i 's/^#\?DNS=.*/DNS=223.5.5.5 114.114.114.114 119.29.29.29/' /etc/systemd/resolved.conf
grep "^DNS=" /etc/systemd/resolved.conf
# 预期输出：DNS=223.5.5.5 114.114.114.114 119.29.29.29

# 3. 重启
systemctl restart systemd-resolved && systemctl is-active systemd-resolved
# 预期：active

# 4. 验证上游已生效
resolvectl status | grep "DNS Servers" | head -n 3
# 预期：出现三个上游地址
```

> 注意：网卡 netplan 里如果写死了 `nameservers: addresses: [223.5.5.5]`，会覆盖全局配置。检查方式：
> ```bash
> grep -A 3 "nameservers" /etc/netplan/*.yaml
> # 若有，同步改为三上游后 netplan apply（脚本已包含此检查）
> ```

---

## 4. 验证方法（观察期 48 小时）

```bash
# 4.1 节点层：每节点 50 次解析零超时（脚本已内置，也可手工）
for i in $(seq 1 50); do dig +time=2 +tries=1 @127.0.0.53 swr.cn-east-3.myhuaweicloud.com +short >/dev/null 2>&1 || echo "FAIL-$i"; done
# 预期：无 FAIL 输出

# 4.2 Pod 层：CoreDNS 上游修复验证
kubectl run dns-test --rm -it --image=busybox:1.36 --restart=Never -n default -- sh -c 'time nslookup swr.cn-east-3.myhuaweicloud.com'
# 预期：解析成功且 <500ms（修复前约 1/3 概率 2s+）

# 4.3 CoreDNS 指标确认无 fallback 风暴
kubectl -n kube-system exec deploy/coredns -- sh -c 'wget -qO- localhost:9153/metrics 2>/dev/null | grep coredns_forward_requests_total'
# 预期：三个上游计数都在增长（轮询正常）

# 4.4 观察镜像 pull 错误（48h 内）
kubectl get events -A --sort-by=.lastTimestamp 2>/dev/null | grep -ci "i/o timeout" 
# 预期：0 或接近 0（修复前每天数次）
```

---

## 5. 回滚方案

```bash
# CoreDNS 回滚
kubectl apply -f /root/k8s-optimizations/optimization-plan/backups/coredns-cm-backup-YYYYMMDD.yaml
kubectl -n kube-system rollout restart deploy coredns

# 节点回滚（单节点示例，批量按脚本逻辑反做）
cp /etc/systemd/resolved.conf.bak-YYYYMMDD /etc/systemd/resolved.conf
systemctl restart systemd-resolved
```

---

## 6. 生产环境实施注意

1. 生产节点如有华为云内网 DNS（100.125.1.250 等，见项目记忆：华为云 SWR/NTP 走内网源），**内网 DNS 应列为第一上游**，公网 DNS 做备胎
2. CoreDNS 重启有 lameduck 5s 优雅退出（现有配置已有），4 副本滚动期间解析不中断
3. 生产操作顺序：先改 CoreDNS（秒级生效、秒级回滚），观察 1 天无异常，再批量改节点

---

## 7. 关联文件

- 脚本：`scripts/dns-multi-upstream-fix.sh`
- 备份位置：`backups/`（脚本自动创建）
