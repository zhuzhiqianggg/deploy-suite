# Kubernetes 集群 sealos reset 误操作紧急排查与修复报告

> **文档类型**：故障排查与修复报告
> **故障时间**：2026-08-14
> **集群版本**：Kubernetes v1.29.9（3 master + 5 worker，sealos 部署）
> **CNI**：Calico v3.27.4（KDD 模式）
> **存储**：NFS（csi-driver-nfs）
> **镜像仓库**：华为云 SWR（swr.cn-east-3.myhuaweicloud.com）

---

## 一、故障背景

### 1.1 误操作

运维人员在 master 节点误执行了 `sealos reset --nodes=''` 命令。该命令本意是重置指定节点，但传入空字符串 `--nodes=''` 后，sealos 开始对集群中的节点逐个执行重置操作（包括停止 kubelet、清理 CNI 配置、删除证书、清理容器等）。

虽然操作者迅速中断了命令，但仍有大量节点受到影响：worker01/02/03 被完全重置后重新加入集群，worker05 也被重置后重新加入，worker04 的 calico 配置被部分污染。

### 1.2 故障现象

集群出现多种异常，业务方报告：

| 现象 | 用户描述 |
|------|---------|
| 服务发现异常 | Pod 启动报 `service unknown host`，但该 Service 确实存在 |
| 配置读取异常 | Java 服务启动报找不到 ConfigMap，但 CM 确实存在 |
| 节点状态异常 | 部分节点网络不通 |
| Pod 启动失败 | 大量 Pod 处于 ImagePullBackOff / CrashLoopBackOff / CreateContainerConfigError |

### 1.3 约束条件

- **禁止执行毁灭性命令**（如 `sealos clean`、`kubeadm reset`、删除节点等）
- **允许 delete pod**（让控制器重建）
- **允许 reset 单个节点重新加入**（作为兜底方案）

---

## 二、排查思路

采用 **从上到下、分层定位** 的排查策略：

```
节点层  →  控制面层  →  网络层(CNI)  →  服务发现(DNS)  →  存储层  →  应用层
```

**核心原则**：先看整体状态，再聚焦异常分类，最后定位根因。避免盲目操作。

---

## 三、排查过程

### 3.1 集群基础状态检查

#### 3.1.1 检查节点状态

```bash
kubectl get nodes -o wide
```

**输出**：
```
NAME                STATUS   ROLES           AGE    VERSION   INTERNAL-IP      ...
k8s-test-master01   Ready    control-plane   296d   v1.29.9   192.168.10.100
k8s-test-master02   Ready    control-plane   199d   v1.29.9   192.168.10.104
k8s-test-master03   Ready    control-plane   199d   v1.29.9   192.168.10.105
k8s-test-worker01   Ready    <none>          179m   v1.29.9   192.168.10.101
k8s-test-worker02   Ready    <none>          179m   v1.29.9   192.168.10.102
k8s-test-worker03   Ready    <none>          179m   v1.29.9   192.168.10.103
k8s-test-worker04   Ready    <none>          107d   v1.29.9   192.168.10.27
k8s-test-worker05   Ready    <none>          77m    v1.29.9   192.168.10.107
```

**分析**：
- 所有节点 STATUS=Ready，说明 kubelet 可与 apiserver 通信
- worker01/02/03 的 AGE 为 179m（约 3 小时），说明这 3 个节点是被 reset 后**重新加入**的
- worker05 的 AGE 为 77m，也是被 reset 后重新加入的
- worker04 的 AGE 为 107d（未被重置删除），但其配置可能被污染

> **原理**：`sealos reset` 会停止节点的 kubelet、清理 `/etc/kubernetes/` 下的证书和配置、清理 CNI 配置。节点重新加入需要重新执行 `kubeadm join` 或 sealos 的 join 流程。AGE 较小的节点即为重新加入的节点。

#### 3.1.2 检查控制面组件

```bash
kubectl get cs
kubectl cluster-info
```

**输出**：
```
NAME                 STATUS    MESSAGE   ERROR
scheduler            Healthy   ok
controller-manager   Healthy   ok
etcd-0               Healthy   ok

Kubernetes control plane is running at https://apiserver.cluster.local:6443
CoreDNS is running at https://apiserver.cluster.local:6443/api/v1/namespaces/kube-system/services/kube-dns:dns/proxy
```

**分析**：控制面三件套（scheduler / controller-manager / etcd）均 Healthy，apiserver 正常运行。**控制面层无问题**，故障在节点/网络层。

> **原理**：`kubectl get cs`（ComponentStatus）检查调度器、控制器管理器和 etcd 的健康状态。注意该命令在 v1.19+ 已废弃，但仍可用于基本检查。

#### 3.1.3 检查本机 kubelet 与容器运行时

```bash
systemctl status kubelet --no-pager | head -30
systemctl status containerd --no-pager | head -20
```

**分析**：kubelet 和 containerd 均 `active (running)`，本机（master01）运行时正常。但 kubelet 日志中已出现大量错误：
```
CreateContainerConfigError: failed to prepare subPath for volumeMount "xxx" of container "yyy"
stale NFS file handle
```

> **原理**：`stale NFS file handle` 表示 NFS 挂载点的文件句柄失效。通常发生在 NFS server 重启、NFS 导出路径变化、或挂载点长时间未刷新后。kubelet 在为 Pod 准备 subPath 挂载时无法访问该路径。

---

### 3.2 异常 Pod 分类统计

```bash
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
```

**异常 Pod 分类**：

| 异常状态 | 数量 | 含义 |
|---------|------|------|
| `ImagePullBackOff` | 多个 | 镜像拉取失败，kubelet 放弃重试并退避 |
| `ErrImagePull` | 多个 | 镜像拉取失败（首次） |
| `CreateContainerConfigError` | 多个 | 容器配置错误（subPath/NFS 问题） |
| `CrashLoopBackOff` | 2 个 | 容器启动后崩溃并退避重启 |
| `Unknown` | 1 个 | kubelet 无法上报 Pod 状态 |

**重点关注**：
- `calico-node-w5dsq`（worker05）CrashLoopBackOff → **网络组件故障**
- `metrics-server-fnw2k`（worker04）CrashLoopBackOff → **监控组件故障**

> **原理**：`field-selector=status.phase!=Running,status.phase!=Succeeded` 过滤出所有非 Running 且非 Succeeded 的 Pod，快速定位异常。

---

### 3.3 核心组件状态检查

#### 3.3.1 kube-system 组件

```bash
kubectl get pods -n kube-system -o wide
```

**关键发现**：
- CoreDNS 4 个 Pod 均 Running
- kube-proxy 全部 Running
- etcd / apiserver / controller-manager / scheduler 全部 Running
- **`metrics-server-fnw2k`（worker04）CrashLoopBackOff**，已重启 43 次

#### 3.3.2 calico-system 组件

```bash
kubectl get pods -n calico-system -o wide
```

**关键发现**：
- **`calico-node-w5dsq`（worker05）CrashLoopBackOff**，已重启 19 次
- `calico-node-hbzrd`（worker04）0/1 Running（readiness 失败）
- 其余 calico-node 正常

> **原理**：Calico 采用 DaemonSet 部署，每个节点一个 calico-node Pod。calico-node 负责本节点的 BGP 路由通告、路由表维护、iptables 规则下发。calico-node 异常会直接导致该节点上的 Pod 网络不通。

---

### 3.4 CoreDNS 服务发现诊断

用户报告 "service unknown host"，首先怀疑 CoreDNS。

#### 3.4.1 检查 DNS Service 与 Endpoints

```bash
kubectl get svc -A | grep kube-dns
kubectl get endpoints -n kube-system kube-dns -o wide
```

**输出**：
```
NAMESPACE     NAME       ClusterIP     ...
kube-system   kube-dns   10.96.0.10    ...

NAME       ENDPOINTS
kube-dns   100.108.198.165:53,100.123.115.89:53,100.124.90.148:53 + 9 more...
```

**分析**：kube-dns Service 存在，ClusterIP 为 10.96.0.10，4 个 CoreDNS Pod 的 endpoints 都已注册。**CoreDNS 本身正常**。

#### 3.4.2 检查 CoreDNS 配置

```bash
kubectl get configmap -n kube-system coredns -o yaml
```

**Corefile 内容**：
```
.:53 {
    errors
    health
    ready
    kubernetes cluster.local in-addr.arpa ip6.arpa {
       pods insecure
       fallthrough in-addr.arpa ip6.arpa
       ttl 30
    }
    prometheus :9153
    forward . 223.5.5.5 114.114.114.114 8.8.8.8
    cache 30
    loop
    reload
    loadbalance
}
```

**分析**：CoreDNS 配置正常，`kubernetes` 插件可解析 cluster.local 域名的 Service。

> **原理**：CoreDNS 的 `kubernetes` 插件通过 watch API 感知 Service 和 Endpoints 变化，当 Pod 查询 `<service>.<namespace>.svc.cluster.local` 时，CoreDNS 返回该 Service 的 ClusterIP。如果 CoreDNS 正常但 Pod 仍报 "unknown host"，问题通常在 **Pod 所在节点的网络**（无法访问 kube-dns 的 ClusterIP）。

#### 3.4.3 结论

CoreDNS 正常，"service unknown host" 的根因不在 DNS 本身，而在**节点网络层**（Pod 无法访问 kube-dns ClusterIP 10.96.0.10）。需进一步排查 calico。

---

### 3.5 Calico 网络诊断（核心根因）

#### 3.5.1 查看 calico-node-w5dsq 日志

```bash
kubectl logs -n calico-system calico-node-w5dsq --tail=50
```

**关键输出**：
```
[INFO] Using NODENAME environment for node name k8s-test-worker05
[INFO] Determined node name: k8s-test-worker05
[INFO] Using autodetected IPv4 address 192.168.10.107/24 on matching interface ens33
[INFO] Node IPv4 changed, will check for conflicts
[WARNING] Calico node 'k8s-test-worker04' is already using the IPv4 address 192.168.10.107.
[INFO] Clearing out-of-date IPv4 address from this node IP="192.168.10.107/24"
[WARNING] Terminating
Calico node failed to start
```

**这是核心根因！**

**分析**：
- worker05（IP 192.168.10.107）的 calico-node 启动时，自动检测到本机 IP 为 192.168.10.107
- calico-node 进行 IP 冲突检查时，发现 **worker04 的 calico node 记录中 IPv4Address 也是 192.168.10.107**
- 由于 IP 冲突，worker05 的 calico-node 直接退出，进入 CrashLoopBackOff

> **原理**：Calico 在 KDD（Kubernetes API Data Store）模式下，每个 Node 资源的 annotation `projectcalico.org/IPv4Address` 记录该节点的 IP。calico-node 启动时会：
> 1. 自动检测本机 IP（通过 IP autodetection）
> 2. 检查该 IP 是否已被其他 calico node 占用
> 3. 如果冲突，拒绝启动（避免 BGP 路由混乱）
>
> 正常情况下 worker04 的 IP 应为 192.168.10.27，但被错误记录为 192.168.10.107。

#### 3.5.2 检查所有节点的 calico IPv4Address annotation

```bash
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.projectcalico\.org/IPv4Address}{"\t"}{.metadata.annotations.projectcalico\.org/IPv4IPIPTunnelAddr}{"\n"}{end}'
```

**输出**：
```
k8s-test-master01   192.168.10.100/24   100.125.47.0
k8s-test-master02   192.168.10.104/24   100.108.198.128
k8s-test-master03   192.168.10.105/24   100.120.155.192
k8s-test-worker01   192.168.10.101/24   100.89.101.80
k8s-test-worker02   192.168.10.102/24   100.123.115.83
k8s-test-worker03   192.168.10.103/24   100.124.90.132
k8s-test-worker04   192.168.10.107/24   100.102.35.64     ← 错误！应为 192.168.10.27
k8s-test-worker05   (空)                                  ← calico-node 未成功启动，未写入
```

**确认根因**：worker04 的 `projectcalico.org/IPv4Address` 被错误设置为 `192.168.10.107/24`（实际应为 `192.168.10.27/24`）。

#### 3.5.3 检查 worker04 真实 IP

```bash
ssh 192.168.10.27 "ip -4 addr show ens33 | grep inet; hostname"
```

**输出**：
```
inet 192.168.10.27/24 brd 192.168.10.255 scope global ens33
k8s-test-worker04
```

**确认**：worker04 真实 IP 为 192.168.10.27，hostname 为 k8s-test-worker04，但 calico 数据库中的记录错误。

#### 3.5.4 检查 worker04 路由表

```bash
ssh 192.168.10.27 "ip route | head -20"
```

**关键输出**：
```
default via 192.168.10.1 dev ens33 proto static
blackhole 100.102.35.64/26 proto bird       ← worker04 自身 pod CIDR 被 blackhole
...
```

**分析**：worker04 的 pod CIDR（100.102.35.64/26）被 calico bird 设置为 blackhole，导致该节点上的 Pod 流量无法正确路由。

> **原理**：Calico 使用 BIRD 进行 BGP 路由通告。`blackhole` 路由表示该 CIDR 没有有效的下一跳。这通常发生在 calico-node 配置不一致或 BGP 会话异常时。当 pod CIDR 被 blackhole，该节点上的 Pod 无法访问 Service ClusterIP（如 kube-dns 10.96.0.10、apiserver 10.96.0.1），从而出现 "service unknown host" 和 "找不到 configmap" 的现象。

---

### 3.6 metrics-server 诊断

```bash
kubectl logs -n kube-system metrics-server-5fc7cf64fc-fnw2k --tail=10
```

**输出**：
```
panic: unable to load configmap based request-header-client-ca-file: 
Get "https://10.96.0.1:443/api/v1/namespaces/kube-system/configmaps/extension-apiserver-authentication": 
dial tcp 10.96.0.1:443: connect: no route to host
```

**分析**：metrics-server 在 worker04 上，尝试访问 apiserver 的 Service IP（10.96.0.1:443）时失败，报 `no route to host`。这与 worker04 的 calico 路由 blackhole 问题直接相关。

> **原理**：metrics-server 作为 APIService 的聚合层，启动时需要从 kube-system/extension-apiserver-authentication ConfigMap 读取 request-header-client-ca-file。它通过 Service IP（10.96.0.1）访问 apiserver，但由于 worker04 网络异常，无法到达 apiserver，导致 panic 退出。

---

### 3.7 镜像拉取诊断

#### 3.7.1 查看失败 Pod 详情

```bash
kubectl describe pod -n db-beosin-starbit-test kafka-0 | tail -10
```

**输出**：
```
Normal  BackOff  3m25s (x677 over 159m)  kubelet  Back-off pulling image "swr.cn-east-3.myhuaweicloud.com/beosin-develop/kafka:4.1.0"
```

#### 3.7.2 手动测试镜像拉取

```bash
ssh 192.168.10.27 "sudo crictl pull swr.cn-east-3.myhuaweicloud.com/beosin-develop/kafka:4.1.0"
```

**输出**：
```
failed to authorize: failed to fetch anonymous token: 
unexpected status from GET request to https://swr.cn-east-3.myhuaweicloud.com/swr/auth/v2/registry/auth/...: 
401 Unauthorized
```

**分析**：`crictl pull` 以**匿名方式**拉取，返回 401。说明镜像仓库需要认证，但节点上没有有效的认证信息。

#### 3.7.3 检查 imagePullSecrets 配置

```bash
# 检查 Pod 是否配置了 imagePullSecrets
kubectl get pod -n db-beosin-starbit-test kafka-0 -o jsonpath='{.spec.imagePullSecrets}'

# 检查现有 secret 内容
kubectl get secret registry-secret -n db-beosin-starbit-test -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d
```

**输出**：
```json
{"auths":{"swr.cn-east-3.myhuaweicloud.com":{"username":"cn-east-3@T16VHCCGXG4DUVBIHSSN","password":"98b16e24...","auth":"Y24t..."}}}
```

**分析**：Pod 正确引用了 `registry-secret`，但 secret 中的凭据（`cn-east-3@T16VHCCGXG4DUVBIHSSN`）**已失效**。需用新的凭据更新。

> **原理**：Kubernetes 的 imagePullSecrets 机制允许 Pod 拉取私有仓库镜像。kubelet 在拉取镜像时，会使用 Pod spec 中 `imagePullSecrets` 引用的 Secret（类型为 `kubernetes.io/dockerconfigjson`）向镜像仓库认证。如果凭据失效，kubelet 会收到 401 Unauthorized，Pod 进入 ImagePullBackOff。

---

### 3.8 NFS 存储诊断

从 kubelet 日志看到大量 `stale NFS file handle` 错误：

```bash
ssh 192.168.10.27 "sudo journalctl -u kubelet --no-pager -n 50 | grep 'stale NFS'"
```

**输出**：
```
Failed to prepare subPath for volumeMount: error checking path 
/var/lib/kubelet/pods/xxx/volume-subpaths/trace-beosin-saas-test-pv/trace-kl/0: stale NFS file handle
```

**分析**：NFS 挂载点的文件句柄失效。但后续检查发现 NFS 挂载本身是正常的：

```bash
ssh 192.168.10.27 "mount | grep nfs | head -5"
```

**输出**：
```
192.168.10.100:/data/nfs/db-beosin-test-dbmodes on /var/lib/kubelet/pods/.../volumes/kubernetes.io~nfs/... type nfs4 (rw,relatime,...)
```

**结论**：NFS 挂载存在，stale file handle 问题在 calico 网络修复、Pod 重建后自行恢复。

> **原理**：NFSv4 使用文件句柄（file handle）标识文件。当 NFS server 重启或导出表变化时，旧文件句柄失效。`stale NFS file handle` 通常通过重新挂载或重启 kubelet 解决。但在本案例中，网络恢复后 Pod 重建，kubelet 重新建立 subPath 挂载，问题自动消失。

---

## 四、根因定位

经过分层排查，根因链如下：

```
sealos reset --nodes='' 中断
        │
        ▼
worker04 的 calico node annotation IPv4Address 被错误设为 192.168.10.107
        │
        ├──► worker05 (192.168.10.107) calico-node 启动时 IP 冲突 → CrashLoopBackOff
        │         │
        │         └──► worker05 上 Pod 网络异常
        │
        └──► worker04 calico felix 路由同步异常 → blackhole 100.102.35.64/26
                  │
                  ├──► worker04 上 Pod 无法访问 Service ClusterIP (10.96.0.1 / 10.96.0.10)
                  │         │
                  │         ├──► metrics-server panic (无法访问 apiserver)
                  │         ├──► "service unknown host" (无法访问 kube-dns)
                  │         └──► "找不到 configmap" (kubelet 无法与 apiserver 通信)
                  │
                  └──► stale NFS file handle (网络中断导致挂载异常)
```

**附加问题**：registry-secret 凭据失效（独立于网络问题，但加剧了故障影响）。

---

## 五、修复过程

### 5.1 修复 calico node IP 配置（核心修复）

**目标**：将 worker04 的 calico annotation IPv4Address 从错误的 192.168.10.107 修正为 192.168.10.27。

```bash
# 修正 worker04 的 calico IPv4Address annotation
kubectl annotate node k8s-test-worker04 \
  projectcalico.org/IPv4Address=192.168.10.27/24 --overwrite

# 验证
kubectl get node k8s-test-worker04 \
  -o jsonpath='{.metadata.annotations.projectcalico\.org/IPv4Address}'
```

**输出**：
```
node/k8s-test-worker04 annotated
192.168.10.27/24
```

> **原理**：`kubectl annotate --overwrite` 直接修改 Node 资源的 annotation。calico-node 启动时会读取该 annotation 确认本节点 IP。修正后，worker05 的 calico-node 不会再检测到 IP 冲突。
>
> **注意**：直接修改 calico annotation 通常有效，但如果 calico-node 正在运行且配置了 IP 自动检测，可能会覆盖手动修改。因此需要配合重启 calico-node。

### 5.2 重启 calico-node Pod

**目标**：让 worker04 和 worker05 的 calico-node 重新启动，重新同步路由表和 BGP 配置。

```bash
# 重启 worker04 的 calico-node
kubectl delete pod -n calico-system calico-node-hbzrd

# 重启 worker05 的 calico-node
kubectl delete pod -n calico-system calico-node-w5dsq
```

> **原理**：calico-node 是 DaemonSet，delete Pod 后控制器会在同一节点上重建。新的 calico-node 启动时会：
> 1. 读取 Node annotation 确认本机 IP
> 2. 初始化 BGP 数据
> 3. 配置 felix 路由表
> 4. 通告本节点的 pod CIDR

**等待 30 秒后验证**：

```bash
sleep 30
kubectl get pods -n calico-system -o wide | grep calico-node
```

**输出**：
```
calico-node-rmmlk   1/1   Running   0   37s   192.168.10.27   k8s-test-worker04
calico-node-z45jx   1/1   Running   0   37s   192.168.10.107  k8s-test-worker05
```

**两个 calico-node 都恢复 Running (1/1)**。

**验证 annotation**：

```bash
kubectl get node k8s-test-worker04 k8s-test-worker05 \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.projectcalico\.org/IPv4Address}{"\t"}{.metadata.annotations.projectcalico\.org/IPv4IPIPTunnelAddr}{"\n"}{end}'
```

**输出**：
```
k8s-test-worker04   192.168.10.27/24   100.102.35.64
k8s-test-worker05   192.168.10.107/24  100.126.17.192
```

**annotation 已正确**。

### 5.3 验证 worker04 网络恢复

```bash
# 测试 TCP 443 连通性（apiserver service IP）
ssh 192.168.10.27 "timeout 5 bash -c 'cat < /dev/null > /dev/tcp/10.96.0.1/443' && echo 'TCP 443 OK' || echo 'TCP 443 FAIL'"

# 测试 apiserver healthz
ssh 192.168.10.27 "curl -k -s -o /dev/null -w '%{http_code}' --max-time 5 https://10.96.0.1:443/healthz"
```

**输出**：
```
TCP 443 OK
200
```

**worker04 网络完全恢复**。

> **说明**：`ping 10.96.0.1` 会返回 `Destination Port Unreachable`，这是正常的——Service ClusterIP 不响应 ICMP，只响应 TCP。判断网络连通性应使用 TCP 测试。

### 5.4 重启 metrics-server

```bash
# delete CrashLoopBackOff 的 metrics-server，让其在网络恢复后重新启动
kubectl delete pod -n kube-system metrics-server-5fc7cf64fc-fnw2k

# 等待并验证
sleep 20
kubectl get pods -n kube-system -o wide | grep metrics-server
```

**输出**：
```
metrics-server-5fc7cf64fc-b9pnp   1/1   Running   3   171d   100.120.155.234   k8s-test-master03
metrics-server-5fc7cf64fc-gng5q   1/1   Running   0   59s   100.126.17.193    k8s-test-worker05
```

**metrics-server 完全恢复**。

### 5.5 更新 registry-secret（修复镜像拉取）

**背景**：现有 registry-secret 的凭据 `cn-east-3@T16VHCCGXG4DUVBIHSSN` 已失效，需更新为新凭据。

#### 5.5.1 解码用户新提供的 secret 内容

用户提供 base64 编码的 `.dockerconfigjson`：

```bash
echo "ewoJImF1dGhzIjogewoJCSJzd3IuY24tZWFzdC0zLm15aHVhd2VpY2xvdWQuY29tIjogewoJCQkiYXV0aCI6ICJZMjR0WldGemRDMHpRRWhRVlVGU1JFWk1SbGt5VGpsVlEweFdVa1ZZT2pobE1XTTBNekk1WW1WaE1qbGpPV0V3TVRFNFl6Y3haV05tWldKak1qWXlOakl4TmpObVlqVm1aVGsyTkRaa1l6a3laREJrWTJKbE1EWXhNV1JrTWpnPSIKCQl9Cgl9Cn0=" | base64 -d
```

**输出**：
```json
{
  "auths": {
    "swr.cn-east-3.myhuaweicloud.com": {
      "auth": "Y24tZWFzdC0zQEhQVUFSREZMRlkyTjlVQ0xWUkVYOjhlMWM0MzI5YmVhMjljOWEwMTE4YzcxZWNmZWJjMjYyNjIxNjNmYjVmZTk2NDZkYzkyZDBkY2JlMDYxMWRkMjg="
    }
  }
}
```

#### 5.5.2 解码 auth 字段获取 username/password

```bash
echo "Y24tZWFzdC0zQEhQVUFSREZMRlkyTjlVQ0xWUkVYOjhlMWM0MzI5YmVhMjljOWEwMTE4YzcxZWNmZWJjMjYyNjIxNjNmYjVmZTk2NDZkYzkyZDBkY2JlMDYxMWRkMjg=" | base64 -d
```

**输出**：
```
cn-east-3@HPUARDFLFY2N9UCLVREX:8e1c4329bea29c9a0118c71ecfebc26262163fb5fe9646dc92d0dcbe0611dd28
```

- **新 username**：`cn-east-3@HPUARDFLFY2N9UCLVREX`
- **新 password**：`8e1c4329bea29c9a0118c71ecfebc26262163fb5fe9646dc92d0dcbe0611dd28`

> **原理**：docker registry secret 的 `auth` 字段是 `base64(username:password)`。解码后可得到明文凭据。

#### 5.5.3 批量更新所有 namespace 的 registry-secret

```bash
#!/bin/bash
# 获取所有包含 registry-secret 的 namespace
NS_LIST=$(kubectl get secret -A -o jsonpath='{range .items[?(@.metadata.name=="registry-secret")]}{.metadata.namespace}{"\n"}{end}')

COUNT=0
for ns in $NS_LIST; do
  # 使用 --dry-run=client 生成 yaml，再 apply 更新（幂等操作）
  kubectl create secret docker-registry registry-secret \
    --docker-server=swr.cn-east-3.myhuaweicloud.com \
    --docker-username='cn-east-3@HPUARDFLFY2N9UCLVREX' \
    --docker-password='8e1c4329bea29c9a0118c71ecfebc26262163fb5fe9646dc92d0dcbe0611dd28' \
    -n "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1 \
    && COUNT=$((COUNT+1)) && echo "updated: $ns"
done
echo "===total updated: $COUNT==="
```

**输出**：
```
updated: api-beosin-saas-test
updated: bms-beosin-saas-test
...（共 31 个 namespace）
===total updated: 31===
```

> **原理**：
> - `kubectl create secret docker-registry --dry-run=client -o yaml` 生成 Secret 的 YAML 声明（不实际创建）
> - `kubectl apply -f -` 以声明式方式应用，已存在的 Secret 会被更新，不存在的会被创建
> - 这种方式是**幂等**的，可安全重复执行
> - `--docker-registry` 类型会自动生成 `.dockerconfigjson` 字段

#### 5.5.4 验证新凭据生效

```bash
# delete 两个失败的 Pod，验证镜像能否拉取
kubectl delete pod -n db-beosin-starbit-test kafka-0
kubectl delete pod -n bms-beosin-saas-test bms-web-f6587745f-vtnqp

# 等待 60 秒后检查
sleep 60
kubectl get pods -n db-beosin-starbit-test kafka-0 -o wide
kubectl get pods -n bms-beosin-saas-test -o wide | grep bms-web
```

**输出**：
```
NAME      READY   STATUS    RESTARTS   AGE   IP               NODE
kafka-0   1/1     Running   0          65s   100.126.17.194   k8s-test-worker05

NAME               READY   STATUS    RESTARTS   AGE   IP               NODE
bms-web-...-4hqwp  1/1     Running   0          65s   100.126.17.195   k8s-test-worker05
```

**新凭据生效，镜像拉取成功**。

### 5.6 批量重建 ImagePullBackOff Pod

```bash
# 获取所有 ImagePullBackOff 状态的 Pod 并 delete（让控制器重建）
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded \
  -o jsonpath='{range .items[?(@.status.containerStatuses[0].state.waiting.reason=="ImagePullBackOff")]}{.metadata.namespace} {.metadata.name}{"\n"}{end}' \
| while read ns name; do
    kubectl delete pod -n "$ns" "$name"
  done
```

**输出**：
```
[bms-beosin-starbit-test] pod "bms-front-65c64694b-9pgzx" deleted
[bms-beosin-starbit-test] pod "bms-web-584f49ddb6-s5nqq" deleted
...（共 13 个 Pod）
```

> **原理**：
> - Deployment/StatefulSet 的 Pod 被 delete 后，控制器会自动重建
> - 重建的 Pod 会使用更新后的 imagePullSecrets 拉取镜像
> - `kubectl delete pod` 是安全的——不会删除控制器本身，Pod 会被重新调度和创建
> - **注意**：StatefulSet 的 Pod delete 后会保持同名重建（如 kafka-0），Deployment 的 Pod 会生成新名

---

## 六、验证

### 6.1 验证节点状态

```bash
kubectl get nodes
```

**输出**：8 个节点全部 Ready。

### 6.2 验证核心组件

```bash
# kube-system 组件（应无异常）
kubectl get pods -n kube-system | grep -vE "Running|NAME"

# calico-system 组件（应无异常）
kubectl get pods -n calico-system | grep -vE "Running|NAME"
```

**输出**：均无异常输出，全部 Running。

### 6.3 验证 DNS 服务发现

```bash
# 在已运行的 Pod 内测试 DNS 解析
ES_POD=$(kubectl get pods -n db-beosin-saas-test -l app=elasticsearch -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n db-beosin-saas-test $ES_POD -- bash -c \
  "getent hosts kubernetes.default.svc.cluster.local && \
   getent hosts kube-dns.kube-system.svc.cluster.local"
```

**输出**：
```
10.96.0.1       kubernetes.default.svc.cluster.local
10.96.0.10      kube-dns.kube-system.svc.cluster.local
```

**DNS 解析正常**。

> **原理**：`getent hosts` 通过系统的 NSS（Name Service Switch）解析主机名，会使用 `/etc/resolv.conf` 配置的 DNS 服务器。Pod 内 `/etc/resolv.conf` 指向 kube-dns（10.96.0.10），能正确解析 Service 名称说明 CoreDNS 服务发现完全正常。

### 6.4 异常 Pod 统计

```bash
echo "Running pods: $(kubectl get pods -A --field-selector=status.phase=Running --no-headers | wc -l)"
echo "Failed pods: $(kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded --no-headers | wc -l)"
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
```

**输出**：
```
Running pods: 233
Failed pods: 2

NAMESPACE                                 NAME              STATUS         ...
db-lianantech-saas-test                   redis-exporter    ErrImagePull   ...  ← 镜像不存在
trace-lianantech-zhejiangshengting-test   trace-front       ErrImagePull   ...  ← 镜像不存在
```

**剩余 2 个异常 Pod 的根因**：镜像 tag 在仓库中不存在（`not found`，非 401 认证问题），属于应用部署/CI 层面问题，非集群故障。

---

## 七、故障恢复总结

### 7.1 修复操作清单

| 序号 | 操作 | 命令 | 影响范围 |
|------|------|------|---------|
| 1 | 修正 calico node IP | `kubectl annotate node k8s-test-worker04 projectcalico.org/IPv4Address=192.168.10.27/24 --overwrite` | worker04 |
| 2 | 重启 calico-node | `kubectl delete pod -n calico-system calico-node-hbzrd calico-node-w5dsq` | worker04, worker05 |
| 3 | 重启 metrics-server | `kubectl delete pod -n kube-system metrics-server-5fc7cf64fc-fnw2k` | metrics-server |
| 4 | 更新 registry-secret | `kubectl create secret docker-registry ... \| kubectl apply -f -`（31 个 namespace） | 全集群镜像拉取 |
| 5 | 重建失败 Pod | `kubectl delete pod ...`（13 个 ImagePullBackOff Pod） | 业务 Pod |

### 7.2 恢复效果

| 指标 | 修复前 | 修复后 |
|------|--------|--------|
| 节点 Ready | 8/8（但 worker04/05 网络异常） | 8/8（网络全通） |
| calico-node | 2 个异常 | 8/8 Running |
| metrics-server | CrashLoopBackOff | 2/2 Running |
| CoreDNS | Running（但部分节点无法访问） | Running + 解析正常 |
| 异常 Pod | 几十个 | 2 个（镜像不存在，非集群问题） |
| DNS 解析 | 部分节点失败 | 全部正常 |

### 7.3 关键经验

1. **sealos reset 的破坏性**：`--nodes=''` 空字符串参数会导致 sealos 误重置所有节点。执行 reset 类命令前务必确认参数。

2. **calico KDD 模式的 annotation 机制**：calico node 的 IP 信息存储在 Node annotation 中，可通过 `kubectl annotate` 直接修正。理解这一机制是排查 calico IP 冲突问题的关键。

3. **分层排查法**：面对 "service unknown host" 这类现象，不要只盯着 DNS，要向上追溯——CoreDNS 正常但 Pod 无法访问 kube-dns ClusterIP，问题在节点网络层（calico 路由）。

4. **Service IP 的 ICMP 行为**：`ping <service-ip>` 返回 `Destination Port Unreachable` 是正常的（Service IP 不响应 ICMP），判断连通性应使用 TCP 测试（如 `curl` 或 `bash /dev/tcp`）。

5. **镜像拉取认证排查**：`crictl pull` 以匿名方式拉取，不使用 k8s secret。判断是否为认证问题，应查看 kubelet 的 ImagePullBackOff 详情和 secret 内容。

6. **安全修复原则**：本次修复全程未使用毁灭性命令，仅用 `kubectl annotate`（修改配置）、`kubectl delete pod`（触发重建）、`kubectl apply`（更新 secret），最大程度保护了集群数据。

---

## 八、后续建议

1. **镜像仓库凭据管理**：建立 registry-secret 凭据的定期轮换机制，避免凭据失效导致大面积 ImagePullBackOff。

2. **剩余 2 个 ErrImagePull Pod**：
   - `redis-exporter:latest`：确认该镜像 tag 是否存在，或更换为具体版本 tag
   - `trace-front:lianantech-saas-release-20260305141850-c9ade9c1`：确认该 CI 构建产物是否已推送

3. **calico IP 自动检测配置**：考虑在 calico-node 的环境变量中显式配置 `IP_AUTODETECTION_METHOD`，避免自动检测到错误 IP。

4. **sealos 操作规范**：执行 `sealos reset` 前二次确认 nodes 参数，建议在测试环境验证后再操作生产。

5. **集群监控告警**：对 calico-node CrashLoopBackOff、metrics-server 异常等关键组件配置告警，及早发现。

---

> **文档结束** | 本次故障修复全程遵循"不执行毁灭性命令"的约束，通过精准定位 calico IP 配置错误这一核心根因，用最小代价恢复了整个集群。
