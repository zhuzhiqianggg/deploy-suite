# Kubernetes 集群问题排查与修复手册

> **文档类型**：通用排查手册 + 实战案例
> **适用版本**：Kubernetes v1.27+
> **维护说明**：本文档整合了 k8s 集群常见问题的排查方法论、诊断命令、原理解析与修复方案，并收录真实故障案例供参考。

---

## 目录

- [第一部分：排查方法论](#第一部分排查方法论)
- [第二部分：分层排查指南](#第二部分分层排查指南)
  - [第一章 集群健康巡检](#第一章-集群健康巡检)
  - [第二章 节点层问题排查](#第二章-节点层问题排查)
  - [第三章 控制面问题排查](#第三章-控制面问题排查)
  - [第四章 网络层（CNI）问题排查](#第四章-网络层cni问题排查)
  - [第五章 服务发现（DNS）问题排查](#第五章-服务发现dns问题排查)
  - [第六章 存储层问题排查](#第六章-存储层问题排查)
  - [第七章 镜像拉取问题排查](#第七章-镜像拉取问题排查)
  - [第八章 Pod 状态异常排查指南](#第八章-pod-状态异常排查指南)
- [第三部分：实战案例](#第三部分实战案例)
  - [案例一：sealos reset 误操作导致集群大面积故障](#案例一sealos-reset-误操作导致集群大面积故障)
  - [案例二：CreateContainerConfigError 批量出现（stale NFS）](#案例二createcontainerconfigerror-批量出现stale-nfs)
- [附录：常用命令速查表](#附录常用命令速查表)

---

# 第一部分：排查方法论

## 1.1 核心原则

面对 k8s 集群故障，遵循以下原则：

| 原则 | 说明 |
|------|------|
| **先观察后操作** | 先全面收集信息（节点状态、Pod 状态、事件、日志），再动手修复 |
| **分层定位** | 从上到下逐层排查：节点 → 控制面 → 网络 → DNS → 存储 → 应用 |
| **最小变更** | 优先使用可逆操作（delete pod、annotate），避免毁灭性命令（reset、clean） |
| **保留现场** | 修复前记录关键状态（截图/日志），便于复盘 |
| **一次一改** | 每次只改一个变量，观察效果后再进行下一步 |

## 1.2 分层排查模型

```
┌─────────────────────────────────────────────────────┐
│  应用层    Pod CrashLoopBackOff / OOM / 配置错误     │
├─────────────────────────────────────────────────────┤
│  存储层    PV/PVC / NFS stale / CSI 异常             │
├─────────────────────────────────────────────────────┤
│  DNS 层    CoreDNS / Service 解析失败                │
├─────────────────────────────────────────────────────┤
│  网络层    CNI(calico/flannel) / kube-proxy / 路由   │
├─────────────────────────────────────────────────────┤
│  控制面    apiserver / etcd / scheduler / cm         │
├─────────────────────────────────────────────────────┤
│  节点层    kubelet / containerd / 资源 / 内核        │
└─────────────────────────────────────────────────────┘
```

**排查顺序**：通常从节点层和控制面入手（基础设施），再到网络和 DNS（连通性），最后看存储和应用。但需根据现象灵活调整——例如 "service unknown host" 应优先查 DNS 和网络。

## 1.3 故障分类速查

| 现象关键词 | 优先排查层 | 常见根因 |
|-----------|-----------|---------|
| 节点 NotReady | 节点层 | kubelet 异常、资源耗尽、容器运行时挂掉 |
| Pod 一直 Pending | 调度器 | 资源不足、节点污点、PVC 未绑定、调度约束 |
| ImagePullBackOff | 镜像层 | 凭据失效、镜像不存在、仓库不可达 |
| CrashLoopBackOff | 应用层 | 应用启动失败、配置错误、依赖未就绪 |
| CreateContainerConfigError | 存储层 | subPath 错误、stale NFS、Secret/ConfigMap 缺失 |
| service unknown host | DNS/网络层 | CoreDNS 异常、节点网络不通、kube-proxy 异常 |
| 找不到 ConfigMap/Secret | 网络/权限层 | 节点无法访问 apiserver、RBAC 权限、网络策略 |
| 连接超时 | 网络层 | calico/flannel 路由异常、kube-proxy iptables 混乱 |
| Pod 无法挂载存储 | 存储层 | NFS server 异常、CSI 驱动问题、PV/PVC 配置错误 |

---

# 第二部分：分层排查指南

## 第一章 集群健康巡检

### 1.1 节点状态检查

```bash
# 查看所有节点状态
kubectl get nodes -o wide

# 查看节点详情（含条件、资源、Taints）
kubectl describe node <node-name>

# 查看节点资源使用
kubectl top nodes
```

**关键字段解读**：

| 字段 | 健康值 | 异常含义 |
|------|--------|---------|
| STATUS | Ready | NotReady = kubelet 异常；Unknown = 节点失联 |
| ROLES | control-plane/\<none\> | 角色标识 |
| AGE | - | AGE 过小可能是重装/重新加入的节点 |
| VERSION | 一致 | 版本不一致可能导致兼容问题 |

**节点 Conditions 详解**（`kubectl describe node`）：

| Condition | True 含义 | 处理 |
|-----------|----------|------|
| Ready | 节点健康 | False/Unknown 表示 kubelet 问题 |
| MemoryPressure | 内存不足 | 检查内存占用，清理或扩容 |
| DiskPressure | 磁盘不足 | 清理镜像/日志，`crictl rmi --prune` |
| PIDPressure | 进程数过多 | 检查僵尸进程 |
| NetworkUnavailable | 网络异常 | 检查 CNI 配置 |

### 1.2 控制面检查

```bash
# 组件状态（v1.19+ 已废弃但可用）
kubectl get cs

# 集群信息
kubectl cluster-info

# 检查 leader 选举（多 master）
kubectl -n kube-system get endpoints kube-scheduler -o yaml | grep holderIdentity
kubectl -n kube-system get endpoints kube-controller-manager -o yaml | grep holderIdentity
```

### 1.3 核心组件 Pod 状态

```bash
# kube-system 命名空间
kubectl get pods -n kube-system -o wide

# CNI 命名空间（calico 为 calico-system，flannel 为 kube-system）
kubectl get pods -n calico-system -o wide

# 所有非 Running 的 Pod
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
```

### 1.4 事件检查

```bash
# 集群级事件（按时间排序）
kubectl get events -A --sort-by='.lastTimestamp' | tail -30

# 某命名空间事件
kubectl get events -n <namespace> --sort-by='.lastTimestamp'

# Warning 事件
kubectl get events -A --field-selector type=Warning
```

> **原理**：Event 资源记录了集群中发生的各类事件（调度、拉取、启动失败等），默认保留 1 小时。`--sort-by='.lastTimestamp'` 按时间排序，便于追踪故障发生顺序。

---

## 第二章 节点层问题排查

### 2.1 节点 NotReady 排查

**第一步：查看节点状态与条件**

```bash
kubectl describe node <node-name> | grep -A5 Conditions
```

**第二步：登录节点检查 kubelet**

```bash
# SSH 到异常节点
ssh <node-ip>

# 检查 kubelet 服务
systemctl status kubelet

# 查看 kubelet 日志
journalctl -u kubelet --no-pager -n 100

# 检查容器运行时
systemctl status containerd    # 或 crictl info
crictl ps                      # 查看运行的容器
```

**常见 NotReady 原因**：

| 原因 | 诊断方法 | 修复 |
|------|---------|------|
| kubelet 进程挂掉 | `systemctl status kubelet` | `systemctl restart kubelet` |
| kubelet 无法连接 apiserver | 日志报 "connection refused" | 检查网络、证书、`/etc/kubernetes/kubelet.conf` |
| 容器运行时异常 | `crictl info` 失败 | `systemctl restart containerd` |
| 内存耗尽 | `free -m`、Conditions 显示 MemoryPressure | 清理进程或扩容 |
| 磁盘满 | `df -h`、Conditions 显示 DiskPressure | 清理镜像 `crictl rmi --prune` |
| CNI 未就绪 | `/etc/cni/net.d/` 为空 | 重新安装 CNI |

### 2.2 节点资源耗尽排查

```bash
# 查看节点资源使用
kubectl top nodes
kubectl describe node <node-name> | grep -A10 "Allocated resources"

# 登录节点查看
ssh <node-ip>
free -h                          # 内存
df -h                            # 磁盘
top                              # CPU/内存占用进程
ps aux --sort=-%mem | head -10   # 内存占用 Top
```

**磁盘清理**：

```bash
# 清理未使用的镜像
crictl rmi --prune

# 清理退出容器
crictl rm $(crictl ps -a -q --state Exited)

# 清理日志（注意保留近期日志）
journalctl --vacuum-time=3d

# 查看 containerd 日志占用
du -sh /var/log/containerd/
```

### 2.3 kubelet 证书过期排查

```bash
# 查看证书到期时间
openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -enddate

# 批量查看所有证书
for cert in /etc/kubernetes/pki/*.crt; do
  echo "$cert: $(openssl x509 -in $cert -noout -enddate)"
done

# kubeadm 方式查看
kubeadm certs check-expiration
```

> **原理**：k8s 控制面证书默认有效期 1 年。证书过期会导致 apiserver、kubelet、etcd 之间无法通信，表现为节点 NotReady、kubectl 命令失败。使用 `kubeadm certs renew` 续期。

---

## 第三章 控制面问题排查

### 3.1 apiserver 异常

**症状**：kubectl 命令超时/失败、apiserver Pod 重启

```bash
# 检查 apiserver Pod
kubectl get pods -n kube-system -l component=kube-apiserver -o wide

# 查看 apiserver 日志
kubectl logs -n kube-system kube-apiserver-<master> --tail=50

# 检查 apiserver 健康度
curl -k https://localhost:6443/healthz
curl -k https://localhost:6443/livez
curl -k https://localhost:6443/readyz
```

**常见原因**：

| 原因 | 诊断 | 修复 |
|------|------|------|
| etcd 不可达 | 日志报 "etcdserver: request timed out" | 检查 etcd 状态 |
| 证书过期 | 日志报 "certificate has expired" | `kubeadm certs renew` |
| 内存不足 | Pod OOMKilled | 扩容 master 节点 |
| 磁盘满 | etcd 无法写入 | 清理磁盘 |

### 3.2 etcd 异常

**症状**：apiserver 无法读写、集群状态不一致

```bash
# 检查 etcd Pod
kubectl get pods -n kube-system -l component=etcd

# 查看 etcd 日志
kubectl logs -n kube-system etcd-<master> --tail=50

# 检查 etcd 集群健康（在 master 节点执行）
ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint health

# 查看 etcd 集群成员
ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  member list -w table

# 查看 etcd 状态
ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint status -w table
```

> **原理**：etcd 是 k8s 的唯一数据存储，所有集群状态都保存在 etcd 中。etcd 需要磁盘 IO 快、网络稳定。etcd 异常会导致整个集群不可用。
>
> **关键指标**：
> - `db_size`：数据库大小，超过 2GB 需关注
> - `is_learner`：新成员应为 learner，同步完成后转为正式成员
> - `raft_term`：所有成员应一致

### 3.3 scheduler / controller-manager 异常

```bash
# 检查组件状态
kubectl get pods -n kube-system -l component=kube-scheduler
kubectl get pods -n kube-system -l component=kube-controller-manager

# 查看日志
kubectl logs -n kube-system kube-scheduler-<master> --tail=30
kubectl logs -n kube-system kube-controller-manager-<master> --tail=30

# 检查 leader 选举（多 master 环境）
kubectl -n kube-system get endpoints kube-scheduler -o yaml | grep holderIdentity
kubectl -n kube-system get endpoints kube-controller-manager -o yaml | grep holderIdentity
```

> **原理**：多 master 环境下，scheduler 和 controller-manager 通过 leader 选举保证只有一个实例工作。如果 leader 异常，会自动切换到其他实例。`holderIdentity` 字段显示当前 leader 所在节点。

---

## 第四章 网络层（CNI）问题排查

### 4.1 CNI 组件检查

```bash
# 查看所有 CNI Pod（根据 CNI 不同选择命名空间）
kubectl get pods -n calico-system -o wide       # Calico
kubectl get pods -n kube-system | grep flannel   # Flannel
kubectl get pods -n kube-system | grep cilium    # Cilium

# 检查每个节点都有 CNI Pod（DaemonSet 应每节点一个）
kubectl get pods -n calico-system -o wide | grep calico-node
```

### 4.2 Pod 网络连通性排查

**场景**：Pod 之间无法通信、Pod 无法访问 Service

```bash
# 进入 Pod 测试网络
kubectl exec -it <pod-name> -- bash

# 测试 DNS 解析
nslookup kubernetes.default
getent hosts kubernetes.default.svc.cluster.local

# 测试 Service 连通性
curl -k https://kubernetes.default.svc.cluster.local
wget -qO- --no-check-certificate https://<service-ip>:<port>

# 测试 Pod 间连通性
ping <target-pod-ip>
curl http://<target-pod-ip>:<port>
```

**跨节点 Pod 通信失败排查**：

```bash
# 1. 检查源 Pod 所在节点的 CNI 路由
ssh <source-node>
ip route | grep -E "cali|flannel|cilium|vxlan"

# 2. 检查目标 Pod 所在节点的 CNI 路由
ssh <target-node>
ip route | grep -E "cali|flannel|cilium|vxlan"

# 3. 检查 CNI 接口
ip addr | grep -E "tunl0|flannel|cilium|vxlan"

# 4. 检查 iptables 转发规则
iptables -L FORWARD -n | head -20
```

### 4.3 Calico 专项排查

**检查 calico node 状态**：

```bash
# 查看每个节点的 calico IP 配置
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.projectcalico\.org/IPv4Address}{"\t"}{.metadata.annotations.projectcalico\.org/IPv4IPIPTunnelAddr}{"\n"}{end}'
```

**calico-node CrashLoopBackOff 排查**：

```bash
# 查看日志
kubectl logs -n calico-system <calico-node-pod> --tail=50
```

**常见错误及处理**：

| 错误日志 | 根因 | 修复 |
|---------|------|------|
| `Calico node 'X' is already using the IPv4 address Y` | IP 冲突 | 修正 Node annotation `projectcalico.org/IPv4Address` |
| `Failed to sync routes to interface` | felix 路由同步异常 | 重启 calico-node Pod |
| `Datastore connection failed` | 无法连接 apiserver | 检查节点网络和 RBAC |
| `IP Autodetection failed` | 自动检测 IP 失败 | 配置 `IP_AUTODETECTION_METHOD` |

**修复 calico IP 冲突**：

```bash
# 1. 查看节点真实 IP
ssh <node-ip> "ip -4 addr show <interface> | grep inet"

# 2. 修正 calico annotation
kubectl annotate node <node-name> \
  projectcalico.org/IPv4Address=<correct-ip>/<cidr> --overwrite

# 3. 重启该节点的 calico-node
kubectl delete pod -n calico-system <calico-node-pod-on-that-node>

# 4. 验证
kubectl get pods -n calico-system -o wide | grep <node-name>
```

> **原理**：Calico 在 KDD 模式下，节点 IP 存储在 Node 资源的 annotation `projectcalico.org/IPv4Address` 中。calico-node 启动时会自动检测本机 IP 并检查冲突。如果 annotation 记录的 IP 与其他节点冲突，calico-node 会拒绝启动。

### 4.4 kube-proxy / iptables 排查

**场景**：Service 无法访问、ClusterIP 不通

```bash
# 检查 kube-proxy
kubectl get pods -n kube-system -l k8s-app=kube-proxy -o wide

# 查看 kube-proxy 日志
kubectl logs -n kube-system <kube-proxy-pod> --tail=30

# 检查 iptables 规则（在节点上执行）
iptables -t nat -L KUBE-SERVICES -n | head -20
iptables -t nat -L KUBE-SVC-<hash> -n   # 具体某 Service 的链

# 测试 Service IP 连通性（注意：Service IP 不响应 ICMP）
# 错误方式：ping 10.96.0.1  → 返回 "Destination Port Unreachable" 是正常的
# 正确方式：
curl -k https://10.96.0.1:443/healthz                    # apiserver
timeout 5 bash -c 'cat < /dev/null > /dev/tcp/10.96.0.1/443' && echo OK
```

> **原理**：kube-proxy 负责将 Service ClusterIP 通过 iptables/ipvs DNAT 到后端 Pod IP。如果 kube-proxy 异常或 iptables 规则缺失，Service 将无法访问。
>
> **重要**：Service ClusterIP 是虚拟 IP，由 iptables/ipvs 拦截处理，不响应 ICMP ping。判断 Service 连通性必须用 TCP 测试。

### 4.5 IPVS 模式排查（如启用）

```bash
# 查看 IPVS 规则
ipvsadm -L -n

# 查看某 Service 的 IPVS 规则
ipvsadm -L -n | grep -A5 <service-ip>

# 查看 IPVS 模块加载
lsmod | grep -E "ip_vs|nf_conntrack"
```

---

## 第五章 服务发现（DNS）问题排查

### 5.1 CoreDNS 状态检查

```bash
# 检查 CoreDNS Pod
kubectl get pods -n kube-system -l k8s-app=kube-dns -o wide

# 检查 kube-dns Service
kubectl get svc -n kube-system kube-dns

# 检查 Endpoints
kubectl get endpoints -n kube-system kube-dns

# 查看 CoreDNS 配置
kubectl get configmap -n kube-system coredns -o yaml
```

> **原理**：CoreDNS 通过 `kubernetes` 插件 watch Service/Endpoints 变化，当 Pod 查询 `<service>.<namespace>.svc.cluster.local` 时返回 ClusterIP。kube-dns Service（通常 10.96.0.10）通过 Endpoints 将流量转发到 CoreDNS Pod。

### 5.2 DNS 解析失败排查

```bash
# 方法一：在 Pod 内测试（推荐）
kubectl exec -it <running-pod> -- bash -c \
  "getent hosts kubernetes.default.svc.cluster.local"

# 方法二：创建临时 Pod 测试（需要镜像可拉取）
kubectl run dns-test --image=busybox:1.28 --rm -it --restart=Never \
  -- nslookup kubernetes.default

# 方法三：直接查询 CoreDNS
kubectl exec -it <running-pod> -- bash -c \
  "nslookup kubernetes.default 10.96.0.10"
```

**DNS 故障分类**：

| 现象 | 可能根因 | 排查方向 |
|------|---------|---------|
| 所有 Service 都无法解析 | CoreDNS 异常 | 检查 CoreDNS Pod 状态 |
| 部分 Pod 无法解析 | 节点网络不通 | 检查该节点 CNI、kube-proxy |
| 短域名解析失败 | search domain 配置 | 检查 Pod 的 `/etc/resolv.conf` |
| 外部域名解析失败 | forward 配置 | 检查 CoreDNS Corefile 的 forward 指令 |
| 解析慢 | CoreDNS 负载高 | 扩展 CoreDNS 副本数 |

### 5.3 CoreDNS 配置详解

```bash
kubectl get configmap -n kube-system coredns -o yaml
```

**Corefile 关键指令**：

| 指令 | 作用 |
|------|------|
| `kubernetes cluster.local` | 解析 cluster.local 域名的 Service |
| `forward . 8.8.8.8` | 外部域名转发到上游 DNS |
| `cache 30` | DNS 缓存 30 秒 |
| `loop` | 检测 DNS 循环解析 |
| `reload` | 自动重载 Corefile 变更 |
| `loadbalance` | 轮询返回 A 记录 |

### 5.4 Pod DNS 配置检查

```bash
# 查看 Pod 的 DNS 配置
kubectl exec <pod-name> -- cat /etc/resolv.conf
```

**正常输出**：
```
nameserver 10.96.0.10
search <namespace>.svc.cluster.local svc.cluster.local cluster.local
options ndots:5
```

> **原理**：`ndots:5` 表示如果域名中点数少于 5 个，会先追加 search domain 查询。例如解析 `redis` 会依次尝试 `redis.<namespace>.svc.cluster.local`、`redis.svc.cluster.local` 等。

---

## 第六章 存储层问题排查

### 6.1 PV/PVC 状态检查

```bash
# 查看 PV
kubectl get pv

# 查看 PVC
kubectl get pvc -A

# 查看 StorageClass
kubectl get sc
```

**PVC 状态含义**：

| 状态 | 含义 | 处理 |
|------|------|------|
| Bound | 已绑定 PV（正常） | - |
| Pending | 等待绑定 | 检查 StorageClass、PV 容量、节点亲和性 |
| Lost | PV 被删除 | 数据丢失，需重建 |

### 6.2 NFS 存储问题排查

**stale NFS file handle 问题**：

```bash
# 查看节点上的 NFS 挂载
ssh <node-ip> "mount | grep nfs"

# 查看 kubelet 日志中的 NFS 错误
ssh <node-ip> "journalctl -u kubelet --no-pager -n 100 | grep -i 'stale\|nfs'"
```

**典型错误**：
```
CreateContainerConfigError: failed to prepare subPath for volumeMount "xxx": 
stale NFS file handle
```

> **原理**：NFSv4 使用文件句柄（file handle）标识文件。当 NFS server 重启、导出表变化、或网络长时间中断后，旧文件句柄失效。kubelet 为 Pod 准备 subPath 挂载时无法访问失效路径，导致 CreateContainerConfigError。
>
> **关键特性**：stale NFS file handle **不会自动恢复**。kubelet 会无限重试同一个 Pod 实例（restart count 持续增加），但每次都访问同一个失效挂载点。必须 delete Pod 让控制器重建，新 Pod 会重新 mount NFS 并重新准备 subPath。

**修复方法**：

```bash
# 方法一：delete Pod 让控制器重建（推荐，最安全）
kubectl delete pod <pod-name> -n <namespace>

# 方法二：在节点上重新挂载 NFS（影响该节点所有 Pod）
ssh <node-ip>
umount /var/lib/kubelet/pods/<pod-uid>/volumes/kubernetes.io~nfs/<pv-name>
# kubelet 会自动重新挂载

# 方法三：重启 kubelet（最后手段，影响该节点所有 Pod）
ssh <node-ip> "systemctl restart kubelet"
```

### 6.3 CSI 驱动排查

```bash
# 查看 CSI 驱动
kubectl get csidriver
kubectl get csinode

# 查看 CSI 控制器 Pod
kubectl get pods -A | grep -E "csi|nfs"

# 查看 CSI 日志
kubectl logs <csi-controller-pod> -n <namespace> --tail=50
```

---

## 第七章 镜像拉取问题排查

### 7.1 镜像拉取失败分类

```bash
# 查看拉取失败详情
kubectl describe pod <pod-name> -n <namespace> | grep -A5 -E "Failed|Error|Warning"
```

| 错误 | 含义 | 排查方向 |
|------|------|---------|
| `401 Unauthorized` | 认证失败 | 检查 imagePullSecrets 凭据 |
| `403 Forbidden` | 无权限 | 检查仓库权限 |
| `not found` | 镜像不存在 | 确认镜像 tag 是否存在 |
| `timeout` | 网络超时 | 检查节点到仓库的网络 |
| `name resolution failed` | DNS 解析失败 | 检查节点 DNS 配置 |

### 7.2 imagePullSecrets 排查

```bash
# 检查 Pod 是否配置了 imagePullSecrets
kubectl get pod <pod-name> -o jsonpath='{.spec.imagePullSecrets}'

# 查看 Secret 内容
kubectl get secret <secret-name> -n <namespace> -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d
```

**解码 auth 字段**：

```bash
# dockerconfigjson 中的 auth 是 base64(username:password)
echo "<auth-value>" | base64 -d
# 输出格式：username:password
```

> **原理**：kubelet 拉取私有仓库镜像时，使用 Pod spec 中 `imagePullSecrets` 引用的 Secret（类型 `kubernetes.io/dockerconfigjson`）向仓库认证。Secret 中的 `.dockerconfigjson` 字段结构与 `~/.docker/config.json` 一致。

### 7.3 更新 registry-secret

```bash
# 单个 namespace 更新
kubectl create secret docker-registry <secret-name> \
  --docker-server=<registry-server> \
  --docker-username=<username> \
  --docker-password=<password> \
  -n <namespace> \
  --dry-run=client -o yaml | kubectl apply -f -

# 批量更新所有 namespace
NS_LIST=$(kubectl get secret -A -o jsonpath='{range .items[?(@.metadata.name=="<secret-name>")]}{.metadata.namespace}{"\n"}{end}')
for ns in $NS_LIST; do
  kubectl create secret docker-registry <secret-name> \
    --docker-server=<registry-server> \
    --docker-username=<username> \
    --docker-password=<password> \
    -n "$ns" --dry-run=client -o yaml | kubectl apply -f -
done
```

> **原理**：`--dry-run=client -o yaml` 生成声明式 YAML，`kubectl apply` 幂等应用。已存在的 Secret 会被更新，不存在的会被创建。

### 7.4 手动测试镜像拉取

```bash
# 在节点上用 crictl 测试（注意：crictl 不使用 k8s secret，以匿名方式拉取）
ssh <node-ip> "crictl pull <image>"

# 如果需要认证，配置 containerd 或使用 nerdctl
ssh <node-ip> "nerdctl login <registry-server> -u <username> -p <password>"
ssh <node-ip> "nerdctl pull <image>"
```

> **注意**：`crictl pull` 不使用 k8s 的 imagePullSecrets，以匿名方式拉取。如果 crictl pull 返回 401，只能说明镜像仓库需要认证，不能直接判断 k8s secret 是否有效。判断 secret 有效性应 delete Pod 看是否拉取成功。

---

## 第八章 Pod 状态异常排查指南

### 8.1 Pod 状态总览

```bash
# 所有非 Running 的 Pod
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded

# 按状态分类统计
kubectl get pods -A -o jsonpath='{range .items[*]}{.status.containerStatuses[0].state.waiting.reason}{"\n"}{end}' | sort | uniq -c | sort -rn
```

### 8.2 各状态排查指南

#### Pending

**含义**：Pod 未被调度到任何节点

```bash
kubectl describe pod <pod-name> | tail -20   # 查看 Events
```

**常见原因**：
- 资源不足：`Insufficient cpu/memory`
- 节点污点：`node(s) had taints`
- 调度约束：`node(s) didn't match node selector`
- PVC 未绑定：`pod has unbound immediate PersistentVolumeClaims`

#### ImagePullBackOff / ErrImagePull

**含义**：镜像拉取失败

```bash
kubectl describe pod <pod-name> | grep -A3 "Failed"
```

详见 [第七章 镜像拉取问题排查](#第七章-镜像拉取问题排查)。

#### CrashLoopBackOff

**含义**：容器启动后崩溃，kubelet 退避重试

```bash
# 查看容器日志
kubectl logs <pod-name> -n <namespace>
kubectl logs <pod-name> -n <namespace> --previous   # 查看上次崩溃的日志

# 查看退出码
kubectl describe pod <pod-name> | grep -A5 "Last State"
```

**常见退出码**：

| 退出码 | 含义 |
|--------|------|
| 0 | 正常退出 |
| 1 | 应用错误 |
| 137 | OOMKilled（内存不足） |
| 139 | Segfault |
| 143 | SIGTERM 终止 |

#### CreateContainerConfigError

**含义**：容器创建时配置错误

```bash
kubectl describe pod <pod-name> | grep -A3 "Error"
# 查看 kubelet 日志
ssh <node-ip> "journalctl -u kubelet --no-pager -n 50 | grep <pod-name>"
```

**常见原因**：
- `stale NFS file handle`：见 [第六章 NFS 排查](#62-nfs-存储问题排查)
- `secret/configmap not found`：Secret/ConfigMap 不存在
- `invalid environment variable`：环境变量名非法

> **关键**：CreateContainerConfigError **不会自动恢复**，kubelet 会无限重试同一 Pod。需要 delete Pod 触发重建。

#### CreateContainerError

**含义**：容器创建失败（运行时层面）

**常见原因**：
- RuntimeClass 不存在
- 依赖的镜像被删除但本地引用残留
- 容器运行时异常

#### InvalidImageName

**含义**：镜像名格式错误

检查 Pod spec 中的 image 字段是否符合规范。

#### RunContainerError

**含义**：容器运行失败

**常见原因**：
- 镜像损坏
- 容器运行时配置错误
- 安全上下文冲突

### 8.3 批量处理异常 Pod

```bash
# 批量 delete ImagePullBackOff Pod（让控制器重建）
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded \
  -o jsonpath='{range .items[?(@.status.containerStatuses[0].state.waiting.reason=="ImagePullBackOff")]}{.metadata.namespace} {.metadata.name}{"\n"}{end}' \
| while read ns name; do
    kubectl delete pod -n "$ns" "$name"
  done

# 批量 delete CreateContainerConfigError Pod
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded \
  -o jsonpath='{range .items[?(@.status.containerStatuses[0].state.waiting.reason=="CreateContainerConfigError")]}{.metadata.namespace} {.metadata.name}{"\n"}{end}' \
| while read ns name; do
    kubectl delete pod -n "$ns" "$name"
  done
```

> **原理**：Deployment/StatefulSet 的 Pod 被 delete 后，控制器会自动重建。StatefulSet Pod 保持同名重建，Deployment Pod 生成新名。这是安全的操作，不会删除控制器本身。

---

# 第三部分：实战案例

## 案例一：sealos reset 误操作导致集群大面积故障

### 背景

- **集群**：3 master + 5 worker，Kubernetes v1.29.9，Calico v3.27.4（KDD 模式），NFS 存储
- **误操作**：运维执行 `sealos reset --nodes='192.168.10.107'`，本意只重置 worker05（IP 192.168.10.107）。worker05 是从 worker04 虚拟机克隆的节点，克隆残留导致 containerd 等组件已存在，sealos add 时提示"已安装"，故尝试用 sealos reset 清理该节点。但 `--nodes` 传 IP 时 sealos 解析异常，导致**误重置了所有节点**
- **中断**：操作者迅速中断命令，但 worker01/02/03/05 已被重置后重新加入，worker04 因克隆残留 calico 配置被污染（annotation IPv4Address 被错误设为 worker05 的 IP 192.168.10.107）

### 故障现象

| 现象 | 描述 |
|------|------|
| 服务发现异常 | Pod 启动报 `service unknown host`，但 Service 存在 |
| 配置读取异常 | Java 服务报找不到 ConfigMap，但 CM 存在 |
| 大量 Pod 异常 | ImagePullBackOff / CrashLoopBackOff / CreateContainerConfigError |
| 组件异常 | calico-node CrashLoopBackOff、metrics-server CrashLoopBackOff |

### 排查过程

#### 步骤 1：集群基础检查

```bash
kubectl get nodes -o wide
kubectl get cs
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
```

**发现**：
- 8 节点均 Ready，但 worker01/02/03 AGE=179m、worker05 AGE=77m（重新加入）
- 控制面 Healthy
- 异常 Pod 分类：ImagePullBackOff、CrashLoopBackOff、CreateContainerConfigError

#### 步骤 2：CoreDNS 排查（针对 "service unknown host"）

```bash
kubectl get pods -n kube-system -l k8s-app=kube-dns
kubectl get svc -n kube-system kube-dns
kubectl get endpoints -n kube-system kube-dns
```

**发现**：CoreDNS 4 Pod 均 Running，Service 和 Endpoints 正常。**DNS 本身无问题**，推断是节点网络导致 Pod 无法访问 kube-dns ClusterIP。

#### 步骤 3：Calico 诊断（定位核心根因）

```bash
# 查看 CrashLoopBackOff 的 calico-node 日志
kubectl logs -n calico-system calico-node-w5dsq --tail=50
```

**关键发现**：
```
[INFO] Using autodetected IPv4 address 192.168.10.107/24 on matching interface ens33
[WARNING] Calico node 'k8s-test-worker04' is already using the IPv4 address 192.168.10.107.
[WARNING] Terminating
Calico node failed to start
```

**分析**：worker05（IP 192.168.10.107）的 calico-node 启动时检测到 IP 冲突——worker04 的 calico 记录中 IPv4Address 被错误设为 192.168.10.107（实际应为 192.168.10.27）。

```bash
# 确认 calico annotation 错误
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.projectcalico\.org/IPv4Address}{"\n"}{end}'
```

**确认**：worker04 annotation `projectcalico.org/IPv4Address = 192.168.10.107/24`（错误，应为 192.168.10.27/24）。

```bash
# 检查 worker04 路由
ssh 192.168.10.27 "ip route | grep blackhole"
```

**发现**：`blackhole 100.102.35.64/26 proto bird`——worker04 自身 pod CIDR 被 blackhole，导致 Pod 无法访问 Service ClusterIP。

#### 步骤 4：metrics-server 诊断

```bash
kubectl logs -n kube-system metrics-server-xxx --tail=10
```

**发现**：
```
panic: ... dial tcp 10.96.0.1:443: connect: no route to host
```

**分析**：metrics-server 在 worker04 上，无法访问 apiserver Service IP，与 calico blackhole 直接相关。

#### 步骤 5：镜像拉取诊断

```bash
ssh 192.168.10.27 "crictl pull swr.cn-east-3.myhuaweicloud.com/beosin-develop/kafka:4.1.0"
# 返回 401 Unauthorized

kubectl get secret registry-secret -n xxx -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d
# 发现凭据 cn-east-3@T16VHCCGXG4DUVBIHSSN（已失效）
```

**发现**：registry-secret 凭据已失效。

### 根因链

```
sealos reset --nodes='192.168.10.107'（传 IP 导致误重置所有节点），中断
        │
        ▼
worker05 是 worker04 的虚拟机克隆，克隆残留导致 calico 数据库中
worker04 的 annotation IPv4Address 被错误设为 192.168.10.107（worker05 的 IP）
        │
        ├──► worker05 (192.168.10.107) calico-node IP 冲突 → CrashLoopBackOff
        │
        └──► worker04 calico felix 路由异常 → blackhole pod CIDR
                  │
                  ├──► Pod 无法访问 Service ClusterIP (10.96.0.1 / 10.96.0.10)
                  │      ├──► metrics-server panic
                  │      ├──► "service unknown host"
                  │      └──► "找不到 configmap"
                  │
                  └──► stale NFS file handle

附加问题：registry-secret 凭据失效 → ImagePullBackOff
```

### 修复过程

```bash
# 1. 修正 calico node IP（核心修复）
kubectl annotate node k8s-test-worker04 \
  projectcalico.org/IPv4Address=192.168.10.27/24 --overwrite

# 2. 重启 calico-node（worker04 + worker05）
kubectl delete pod -n calico-system calico-node-hbzrd
kubectl delete pod -n calico-system calico-node-w5dsq

# 3. 验证 worker04 网络恢复
ssh 192.168.10.27 "curl -k -s -o /dev/null -w '%{http_code}' https://10.96.0.1:443/healthz"
# 返回 200

# 4. 重启 metrics-server
kubectl delete pod -n kube-system metrics-server-xxx

# 5. 批量更新 registry-secret（31 个 namespace）
for ns in $(kubectl get secret -A -o jsonpath='{range .items[?(@.metadata.name=="registry-secret")]}{.metadata.namespace}{"\n"}{end}'); do
  kubectl create secret docker-registry registry-secret \
    --docker-server=swr.cn-east-3.myhuaweicloud.com \
    --docker-username='cn-east-3@HPUARDFLFY2N9UCLVREX' \
    --docker-password='<new-password>' \
    -n "$ns" --dry-run=client -o yaml | kubectl apply -f -
done

# 6. 批量重建 ImagePullBackOff Pod
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded \
  -o jsonpath='{range .items[?(@.status.containerStatuses[0].state.waiting.reason=="ImagePullBackOff")]}{.metadata.namespace} {.metadata.name}{"\n"}{end}' \
| while read ns name; do kubectl delete pod -n "$ns" "$name"; done
```

### 修复效果

| 指标 | 修复前 | 修复后 |
|------|--------|--------|
| 节点 Ready | 8/8（但 worker04/05 网络异常） | 8/8（网络全通） |
| calico-node | 2 个 CrashLoopBackOff | 8/8 Running |
| metrics-server | CrashLoopBackOff | 2/2 Running |
| DNS 解析 | 部分节点失败 | 全部正常 |
| 异常 Pod | 几十个 | 仅剩 stale NFS Pod（非集群问题） |

### 经验总结

1. **sealos reset 的破坏性**：`--nodes=''` 空字符串会导致误重置所有节点，执行前务必确认参数
2. **分层排查法有效性**：从现象（service unknown host）→ DNS（正常）→ 网络（calico blackhole）→ 根因（IP 配置错误），逐层逼近
3. **calico KDD annotation 机制**：理解 `projectcalico.org/IPv4Address` annotation 是排查 calico IP 冲突的关键
4. **Service IP 不响应 ICMP**：`ping <service-ip>` 返回 "Destination Port Unreachable" 是正常的，需用 TCP 测试
5. **安全修复原则**：全程仅用 `annotate`、`delete pod`、`apply`，未执行毁灭性命令

---

## 案例二：CreateContainerConfigError 批量出现（stale NFS）

### 背景

集群网络恢复后，部分 Pod 仍处于 `CreateContainerConfigError` 状态，未自动恢复。

### 现象

```bash
kubectl get pods -A | grep CreateContainerConfigError
```

多个 Pod 报 CreateContainerConfigError，restart count 持续增长。

### 排查

```bash
# 查看具体错误
kubectl describe pod <pod-name> | grep -A3 "Error"

# 查看 kubelet 日志
ssh <node-ip> "journalctl -u kubelet --no-pager -n 50 | grep <pod-name>"
```

**发现**：
```
CreateContainerConfigError: failed to prepare subPath for volumeMount "xxx": 
stale NFS file handle
```

### 为什么没有自动恢复

1. **stale NFS file handle 不会自愈**：文件句柄失效后，kubelet 每次重试访问同一失效挂载点
2. **kubelet 不主动重建 Pod**：CreateContainerConfigError 属于配置错误，kubelet 无限重试同一 Pod 实例，不会 delete 重建
3. **restart count 增长是重试证据**：但每次都失败，因为访问的还是同一个失效挂载

### 修复

```bash
# delete Pod 让控制器重建，新 Pod 会重新 mount NFS 并准备 subPath
kubectl delete pod <pod-name> -n <namespace>

# 批量处理所有 CreateContainerConfigError Pod
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded \
  -o jsonpath='{range .items[?(@.status.containerStatuses[0].state.waiting.reason=="CreateContainerConfigError")]}{.metadata.namespace} {.metadata.name}{"\n"}{end}' \
| while read ns name; do kubectl delete pod -n "$ns" "$name"; done
```

### 预防

- NFS server 重启后，批量检查挂载了 NFS 的 Pod
- 考虑使用 CSI 驱动替代直接 NFS 挂载（CSI 有更好的错误恢复机制）
- 定期检查 NFS server 健康状态

---

# 附录：常用命令速查表

## A.1 集群状态检查

```bash
kubectl get nodes -o wide                              # 节点状态
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded  # 异常 Pod
kubectl get cs                                         # 控制面组件
kubectl cluster-info                                   # 集群信息
kubectl get events -A --sort-by='.lastTimestamp' | tail -30  # 最近事件
kubectl top nodes                                      # 节点资源
kubectl top pods -A                                    # Pod 资源
```

## A.2 诊断命令

```bash
kubectl describe pod <pod> -n <ns>                     # Pod 详情
kubectl logs <pod> -n <ns>                             # Pod 日志
kubectl logs <pod> -n <ns> --previous                  # 上次崩溃日志
kubectl get pod <pod> -o yaml                          # Pod 完整配置
kubectl exec -it <pod> -n <ns> -- bash                 # 进入 Pod
kubectl get endpoints -n <ns> <svc>                    # Service Endpoints
```

## A.3 网络诊断

```bash
# 在 Pod 内测试
kubectl exec -it <pod> -- bash -c "getent hosts <service>.<ns>.svc.cluster.local"
kubectl exec -it <pod> -- curl -k https://<service-ip>:<port>

# 节点路由检查
ssh <node> "ip route"
ssh <node> "ip route | grep blackhole"                 # 检查黑洞路由
ssh <node> "iptables -t nat -L KUBE-SERVICES -n"       # kube-proxy 规则

# TCP 连通性测试（Service IP 不响应 ICMP）
timeout 5 bash -c 'cat < /dev/null > /dev/tcp/<ip>/<port>' && echo OK
```

## A.4 Calico 诊断

```bash
# 查看节点 calico IP 配置
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.projectcalico\.org/IPv4Address}{"\n"}{end}'

# 修正 calico IP
kubectl annotate node <node> projectcalico.org/IPv4Address=<ip>/<cidr> --overwrite

# 重启某节点的 calico-node
kubectl delete pod -n calico-system <calico-node-pod>
```

## A.5 镜像与 Secret

```bash
# 查看 Secret 内容
kubectl get secret <name> -n <ns> -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d

# 更新 registry-secret
kubectl create secret docker-registry <name> \
  --docker-server=<server> --docker-username=<user> --docker-password=<pass> \
  -n <ns> --dry-run=client -o yaml | kubectl apply -f -

# 节点上测试镜像拉取
ssh <node> "crictl pull <image>"
```

## A.6 批量操作

```bash
# 批量 delete 指定状态的 Pod
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded \
  -o jsonpath='{range .items[?(@.status.containerStatuses[0].state.waiting.reason=="<REASON>")]}{.metadata.namespace} {.metadata.name}{"\n"}{end}' \
| while read ns name; do kubectl delete pod -n "$ns" "$name"; done

# 清理未使用镜像
ssh <node> "crictl rmi --prune"

# 查看异常 Pod 状态统计
kubectl get pods -A -o jsonpath='{range .items[*]}{.status.containerStatuses[0].state.waiting.reason}{"\n"}{end}' | sort | uniq -c | sort -rn
```

## A.7 节点运维

```bash
# 重启 kubelet
ssh <node> "systemctl restart kubelet"

# 重启 containerd
ssh <node> "systemctl restart containerd"

# 查看 kubelet 日志
ssh <node> "journalctl -u kubelet --no-pager -n 100"

# 证书检查
kubeadm certs check-expiration

# 证书续期
kubeadm certs renew all
```

---

> **文档维护**：本手册持续更新，遇到新的典型问题可补充到对应章节或新增案例。
> 
> **使用建议**：排查时先定位故障层（参考 1.3 故障分类速查），再按对应章节的步骤执行诊断命令，根据输出对照"常见原因"表定位根因，最后按"修复方法"操作。
