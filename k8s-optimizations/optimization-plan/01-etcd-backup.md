# 01. etcd 备份与恢复体系

| 属性 | 值 |
|------|-----|
| 优先级 | **P0（最高，集群唯一无兜底环节）** |
| 风险等级 | 无（纯增量操作，不触碰运行中的集群） |
| 建议实施 | 第 1 周，立即 |
| 观察期 | 脚本运行 7 天 + 1 次完整恢复演练 |
| 状态 | ⬜ 待实施 |

---

## 1. 背景与问题

**现状**：etcd 数据 444M（持续增长），**无任何备份**——无 crontab、无备份目录、无 Velero。

**风险场景**（raft 三副本防不住的）：
- 误操作：`kubectl delete ns xxx` 手滑、误删 Secret/CRD（三副本会"忠实地"把误删同步到所有副本）
- 逻辑损坏：异常断电/磁盘错误导致 db 损坏
- 三台 master 同时不可用（同机房/同存储故障域）

**原理（学习点）**：
- etcd 是集群唯一"账本"：所有 Deployment/Service/ConfigMap/Secret 的**定义**都在里面。Pod/容器是可再生的（重启即有），但对象定义丢了等于整个集群"失忆"
- raft 三副本 = 高可用（防单点），**≠ 备份**（防误删/逻辑损坏）。快照（snapshot）才是逻辑错误的兜底
- `snapshot save` 是一致性快照：从 mvcc 历史中取出当前时刻的完整状态，文件可校验、可跨版本恢复

---

## 2. 实施前检查

```bash
# 2.1 确认 etcdctl 位置（sealos 部署的集群通常在 /usr/bin/etcdctl）
which etcdctl || ls -l /usr/bin/etcdctl /usr/local/bin/etcdctl 2>/dev/null

# 2.2 确认证书路径（kube-apiserver manifest 中引用的路径）
ssh root@192.168.10.100 'grep -E "cacert|cert|key" /etc/kubernetes/manifests/etcd.yaml | grep -v trusted | head -n 6'
# 预期证书文件均存在于 /etc/kubernetes/pki/etcd/ 下：
ls -l /etc/kubernetes/pki/etcd/{ca.crt,server.crt,server.key}

# 2.3 手工试一次快照（验证整条链路可用，此时还不进 crontab）
ETCDCTL_API=3 etcdctl snapshot save /tmp/test-snap.db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key
# 预期输出：Snapshot saved at /tmp/test-snap.db

# 2.4 校验快照完整性（关键！坏快照 = 没备份）
etcdctl snapshot status /tmp/test-snap.db -w table
# 预期输出：HASH / REVISION / TOTAL KEYS / TOTAL SIZE 一行表格，无报错

# 2.5 确认备份目标空间（本地目录或 NFS 挂载点）
df -h /data 2>/dev/null || echo "需先准备备份目录（见 3.1）"
```

**常见问题**：
- 若 `which etcdctl` 为空 → 在 master01 上 `apt list --installed 2>/dev/null | grep etcd` 查包；sealos 装的 etcdctl 在 PATH 外时用绝对路径。实在没有：从 etcd release 下载对应版本二进制（3.5.x），放 /usr/local/bin/
- 若证书路径不同 → 一切以 `/etc/kubernetes/manifests/etcd.yaml` 中的实际挂载为准

---

## 3. 实施步骤

### 3.1 准备备份目录

```bash
# 在 master01 上执行。优先用独立磁盘/NFS；若无，用系统盘单独目录（可接受，但生产建议 NFS/异地）
mkdir -p /data/etcd-backup
# 若使用现有 NFS（推荐，防 master 主机整机故障）：
# mount -t nfs <nfs-server>:/path/to/etcd-backup /data/etcd-backup
# 并写入 /etc/fstab 持久化
chmod 700 /data/etcd-backup
```

> 生产环境要求：备份目录**必须脱离 master 主机本身**（NFS 或异地），否则机器盘坏 = 备份与数据同归于尽。

### 3.2 部署备份脚本

```bash
# 脚本已随本方案提供：scripts/etcd-backup.sh
# 复制到 master01 并赋权
install -m 750 /root/k8s-optimizations/optimization-plan/scripts/etcd-backup.sh /root/scripts/etcd-backup.sh
# （目录不存在时先 mkdir -p /root/scripts）

# 首次手工执行，确认输出
bash /root/scripts/etcd-backup.sh
# 预期输出（脚本 echo 每条命令）：
#   [CMD] etcdctl snapshot save /data/etcd-backup/snap-YYYYmmdd-HHMMSS.db ...
#   [OK] 快照完成: xxx.db (大小 xxM)
#   [CMD] etcdctl snapshot status ... （校验）
#   [OK] 备份链路正常
```

### 3.3 配置 crontab

```bash
crontab -e
# 追加一行：每天 02:00 备份（低峰期，快照有短暂的 fsync 开销）
0 2 * * * /root/scripts/etcd-backup.sh >> /var/log/etcd-backup.log 2>&1
```

### 3.4（可选，推荐）其余两台 master 也部署

etcd 快照只需在**一台** member 上做（快照内容是集群一致的）。但建议 master02 上再配一份**错峰**备份（如 04:00），多一重保险：

```bash
# master02 上重复 3.1-3.3，crontab 时间改为：
0 4 * * * /root/scripts/etcd-backup.sh >> /var/log/etcd-backup.log 2>&1
```

---

## 4. 验证方法（观察期 7 天）

```bash
# 4.1 每日检查备份文件生成与增长
ls -lh /data/etdb-backup/ 2>/dev/null; ls -lh /data/etcd-backup/
tail -n 20 /var/log/etcd-backup.log

# 4.2 第二天起确认保留策略生效（默认保留 7 份，最老的自动删除）
ls /data/etcd-backup/snap-*.db | wc -l    # 稳定后应 ≤ 8

# 4.3 抽查任一快照可校验
etcdctl snapshot status /data/etcd-backup/$(ls /data/etcd-backup | grep snap | tail -n 1) -w table
```

### 恢复演练（必做！没演练过的备份 = 没备份）

在**测试集群**完整走一遍（生产演练前先在测试环境验证流程）：

```bash
# 演练目标：把快照恢复到一台"新 etcd"，验证数据完整可用
# 以下在测试集群任一 master 上操作（会造成该 etcd 数据目录被替换，建议演练机不是生产 member）

# 1. 停掉演练机的 etcd 与 apiserver（静态 pod 移走）
mv /etc/kubernetes/manifests/etcd.yaml /etc/kubernetes/manifests/etcd.yaml.bak
mv /etc/kubernetes/manifests/kube-apiserver.yaml /etc/kubernetes/manifests/kube-apiserver.yaml.bak
# 等待 pod 停止
crictl ps | grep -E "etcd|apiserver"   # 预期：无输出

# 2. 备份旧数据目录（演练保护）
mv /var/lib/etcd /var/lib/etcd.bak-$(date +%Y%m%d)

# 3. 从快照恢复到临时目录
etcdctl snapshot restore /data/etcd-backup/snap-XXXX.db \
  --data-dir=/var/lib/etcd \
  --name=<节点名> \
  --initial-cluster=<节点名>=https://<本机IP>:2380 \
  --initial-cluster-token=etcd-cluster \
  --initial-advertise-peer-urls=https://<本机IP>:2380
# 学习点：restore 是"生成一个单成员集群的数据目录"，集群成员信息从参数注入

# 4. 启动 etcd 与 apiserver（静态 pod 移回）
mv /etc/kubernetes/manifests/etcd.yaml.bak /etc/kubernetes/manifests/etcd.yaml
mv /etc/kubernetes/manifests/kube-apiserver.yaml.bak /etc/kubernetes/manifests/kube-apiserver.yaml

# 5. 验证数据
kubectl get ns | wc -l            # 预期：与快照时刻一致
kubectl get deploy -A | wc -l     # 预期：与快照时刻一致
etcdctl endpoint status -w table --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key
```

> ⚠️ 单成员 etcd 恢复后如果原集群还要重组（重新 add member），流程更复杂（需要 `etcdctl member add` + 各成员依次重建）。**完整的三 member 灾难恢复演练**建议放在测试集群专门做一次，步骤参考官方文档 "Disaster recovery"，此处不展开——日常保证"快照可校验+单机恢复可行"已覆盖 95% 场景。

---

## 5. 回滚方案

本项无回滚需求（纯增量）。取消方式：

```bash
crontab -e   # 删除对应行即可
```

---

## 6. 生产环境实施注意

1. 备份目录必须 NFS/异地（脱离 master 主机）
2. 生产 crontab 建议加告警：备份失败时输出能被监控捕获（脚本失败 exit 非 0，可在脚本尾部按需接入钉钉/企微 webhook）
3. 恢复演练在生产做一次"只校验不切换"版本：`etcdctl snapshot restore` 到 /tmp 目录 + `snapshot status`，不替换生产数据目录
4. k8s 版本升级（文档 08）前，**手工触发一次备份**并确认校验通过

---

## 7. 关联文件

- 脚本：`scripts/etcd-backup.sh`（每日快照+校验+清理）
- 巡检：`scripts/etcd-defrag-check.sh`（碎片率检查，见文档 09）
