# Sealos K8s 单节点集群 —— 一键部署 & 完整指南

> **环境**：Ubuntu 22.04 LTS / ARM64 (aarch64) / 1 TiB RAM / 7T+ LVM（/data）
> **一键命令**：`sudo SKIP_CONFIRM=1 bash deploy.sh`
> **最后更新**：2026-09-11（v5：NFS 目录嵌套结构 pathPattern + nfsvers=3 修 mysqld idmap 崩溃 + certgen 归位基础镜像清单 + 坑 24-25）

---

## 目录结构

```
k8s-online-install/
├── deploy.sh                  ← 一键入口
├── config.env                 ← 所有可调参数集中在这里（改这里）
├── common.sh                  ← 共享函数（日志/wait_for/幂等 bashrc 写入）
├── scripts/
│   ├── 00-cleanup-docker.sh   ← 彻底清理 Docker/containerd/sealos 残留
│   ├── 01-prerequisites.sh    ← Swap/内核模块/sysctl/依赖/时间
│   ├── 02-sealos-install.sh   ← sealos run 安装 K8s（幂等，装过自动跳过）
│   ├── 03-nfs-storage.sh      ← NFS server 调优 + StorageClass + 默认 SC 去重
│   ├── 04-cluster-tuning.sh   ← kubelet/静态Pod/Calico/etcd 快照调优
│   ├── 05-kuboard.sh          ← Kuboard v4 + 内置 MySQL (NodePort 30080)
│   ├── 06-ingress-nginx.sh    ← ingress-nginx hostNetwork 80/443 + JSON 日志/安全优化
│   ├── 07-fluentbit-graylog.sh← Fluent Bit → Graylog (GELF UDP, Helm)
│   ├── 08-verify.sh           ← 综合验证 & 诊断报告
│   └── 09-usability.sh        ← 命令补全/别名/metrics-server/诊断 CLI
├── manifests/
│   └── ingress-nginx.yaml     ← ingress-nginx 完整清单（版本控制，脚本 sed 注入镜像版本）
├── diagnostics/
│   └── k8s-diagnose.sh        ← 故障诊断 CLI 源文件（安装到 /usr/local/bin/k8s-diagnose）
├── helm-values/               ← 生成的 values/manifest 都版本控制在这里
├── docs/
│   └── sealos-k8s-deploy-guide.md
└── logs/                      ← 部署日志（每次运行独立文件）
```

---

## 快速开始

```bash
cd /home/ubuntu/deploy/k8s-online-install
vim config.env                 # 确认版本、NFS 路径、Graylog IP（占位符时 07 只生成不部署）
sudo bash deploy.sh            # 一键 00 → 10（或 sudo SKIP_CONFIRM=1 bash deploy.sh）
source ~/.bashrc               # 立即启用补全和别名

kubectl get nodes              # Ready
kubectl get pods -A            # 全 Running（别名 kgpa）
kubectl top nodes              # 资源监控（09 装了 metrics-server）
kubectl get sc                 # nfs-client 为唯一 default
curl -I http://<节点IP>:80     # ingress-nginx 默认后端 404 = 正常
# Kuboard: http://<节点IP>:30080  admin/Kuboard123
# Grafana: http://<节点IP>:30300  admin/密码在 helm-values/grafana-admin-password.txt
# Prometheus: http://<节点IP>:30900   Alertmanager: http://<节点IP>:30903
```

**镜像前置步骤**（新机器/Kuboard/ingress/monitoring 镜像不在集群时）：
```bash
# 海外服务器（amd64）同步镜像到华为云 SWR（含 kuboard v4 / ingress-nginx / metrics-server）
bash images-manager.sh sync
# Prometheus 套件镜像清单单独一份（9 个，arm64 已验证），按同通道 sync/load2k8s 处理
cat k8s-online-install/helm-values/prometheus-stack-images.txt
# K8s 节点（ARM64）：核对架构 → 注入集群（打回官方名，kubelet 直接命中）
bash images-manager.sh arch && bash images-manager.sh load2k8s
```

**deploy.sh 参数**：

| 命令 | 作用 |
|------|------|
| `sudo ./deploy.sh` | 全量部署 00→10（默认先清理） |
| `sudo ./deploy.sh skip-cleanup` | 跳过清理直接部署（集群已干净时） |
| `sudo ./deploy.sh 04` | 只重跑调优 |
| `sudo ./deploy.sh 09` | 只重跑易用性（补全/诊断 CLI） |
| `sudo ./deploy.sh --dry-run` | 预演，列出执行计划 |
| `SKIP_CONFIRM=1` | 跳过所有交互确认 |

**所有脚本均幂等**：重复执行安全（02 检测到集群在跑会跳过安装、03 自动识别 Helm/raw 部署模式、04 参数已存在时跳过、08 清理旧 bashrc 行后重写标记块）。

---

## 镜像管理（images-manager.sh）

脚本位置：`/home/ubuntu/deploy/delivery-tools/images-manager.sh`，K8s 节点（国内、ARM64、无 Docker）与海外同步机共用一份清单。**所有镜像统一走这条通道**：海外机 `sync` → 华为云 SWR（`swr.cn-east-3.myhuaweicloud.com/lianantech-public`）→ K8s 节点 `load2k8s` 注入。

```bash
# 海外服务器（需可访问 docker.io / quay.io 等上游 + SWR）
bash images-manager.sh sync              # 全量同步（读 SWR 凭据 .swr-credentials）
bash images-manager.sh sync kuboard      # 只同步某一组（按过滤参数）

# K8s 节点（ARM64）
bash images-manager.sh arch              # 核对 SWR 镜像 amd64/arm64 双架构
EXCLUDE="kuboard-agent" bash images-manager.sh load2k8s   # 注入集群（ctr 拉取→打回官方名→删除 SWR 名）
bash images-manager.sh list              # 查看清单与注入状态
```

**设计要点（决策经验）**：
- **为什么必须注入而不是让节点在线拉**：docker.io IPv4 被墙、daocloud mirror 对 `eipwork/*` 返回 403、`ctr` 裸客户端不走 certs.d 加速（见坑 12）。load2k8s 用 ctr 走 SWR 拉取后**打回官方镜像名**（如 `docker.io/eipwork/kuboard:v4`），kubelet 按 pod spec 原名直接命中，部署清单里不需要出现任何 SWR 地址。
- **tag 必须完整限定 docker.io 前缀**（坑 16）：`to_full_ref` 对 `组织/镜像` 补 `docker.io/`、裸短名补 `docker.io/library/`、带域名 registry 原样。否则 kubelet 规范化后查不到本地镜像，退化成走 mirror 外网拉取。
- **镜像本地命中验证**：`sudo crictl inspecti docker.io/<完整引用>`（crictl images 的展示名与 ImageStatus 实际查找名可能不一致，以 inspecti 为准）。
- `EXCLUDE=<子串>` 可临时跳过某个镜像；`.swr-credentials`（base64 的 SWR 长期凭据）必须在脚本同目录，600 权限。
- 新增镜像只改脚本 `IMAGES` 列表 → 海外机 sync → 节点 load2k8s，两步完成；ARM64 是硬约束，sync 前先 `arch` 核对。

---

## 远程访问（VPN 环境：SSH 隧道）

节点物理 IP 只有 `173.23.1.2/18`（eno1）。VPN 里 SSH 能通但浏览器访问不了 NodePort 时（安全组只放 22 / 浏览器代理不走该路由），用 SSH 隧道：

```bash
# 本机执行（一次转发 Kuboard + ingress + 监控；80/443 本机被占则换高位端口）
ssh -N \
  -L 30080:173.23.1.2:30080 \
  -L 18080:173.23.1.2:80 \
  -L 18443:173.23.1.2:443 \
  -L 30300:173.23.1.2:30300 \
  -L 30900:173.23.1.2:30900 \
  -L 30903:173.23.1.2:30903 \
  ubuntu@173.23.1.2
# Kuboard: http://localhost:30080   Ingress: http://localhost:18080 / https://localhost:18443
# Grafana: http://localhost:30300   Prometheus: http://localhost:30900   Alertmanager: http://localhost:30903

# 或者动态代理（SOCKS5），浏览器全网走隧道：NodePort / Pod IP / Service VIP 全通
ssh -N -D 1080 ubuntu@173.23.1.2
# 浏览器 SwitchyOmega: SOCKS5 → 127.0.0.1:1080，勾选"代理 DNS"

# 免敲长命令：写进本机 ~/.ssh/config，以后 ssh -N k8s-node1
# Host k8s-node1
#     HostName 173.23.1.2
#     User ubuntu
#     ServerAliveInterval 60
#     ExitOnForwardFailure yes
#     LocalForward 30080 173.23.1.2:30080
#     LocalForward 18080 173.23.1.2:80
#     LocalForward 18443 173.23.1.2:443
#     LocalForward 30300 173.23.1.2:30300
#     LocalForward 30900 173.23.1.2:30900
#     LocalForward 30903 173.23.1.2:30903

# 本机 kubectl（可选）：再加 -L 6443:173.23.1.2:6443，
# kubeconfig server 改 https://127.0.0.1:6443（apiserver 证书 SAN 是节点 IP，需临时 insecure-skip-tls-verify）
```

> ⚠️ **隧道目标必须是节点 IP（173.23.1.2），不能写 127.0.0.1**：NodePort 由 IPVS 在内核转发，只绑节点 IP 和 Service VIP，不绑 loopback，`curl 127.0.0.1:30080` 会连接拒绝。同理 `ss -tlnp` 里**永远看不到** NodePort 的 LISTEN（见坑 19）。

---

## config.env 关键配置

```bash
# 镜像加速器（Docker Hub IPv4 被墙）
REGISTRY_MIRRORS=("https://docker.m.daocloud.io" "https://docker.1panel.live")
K8S_REGISTRY_MIRRORS=("k8s.m.daocloud.io")   # registry.k8s.io（metrics-server 等）

# 版本（必须 labring/* 有 ARM64 manifest）
K8S_VERSION="v1.29.9"; CALICO_VERSION="v3.28.1"; HELM_VERSION="v3.12.0"; SEALOS_VERSION="v5.1.1"

# 存储
NFS_DIR="/data/nfs"; NFSD_THREADS=32

# Kubelet（留空 = 自动按总内存 2% 计算，至少 2Gi）
EVICTION_HARD_MEMORY="5%"; EVICTION_HARD_NODEFS="10%"; EVICTION_HARD_IMAGEFS="15%"
MAX_PODS=250
CONTAINER_LOG_MAX_SIZE="100Mi"; CONTAINER_LOG_MAX_FILES=3

# Kuboard v4（内置 MySQL 于 kuboard 命名空间，数据落 NFS PVC）
KUBOARD_IMAGE="eipwork/kuboard:v4"; KUBOARD_MYSQL_IMAGE="mysql:8.4"
KUBOARD_MYSQL_STORAGE="10Gi"

# ingress-nginx（hostNetwork 绑宿主机 80/443，无需 NodePort）
INGRESS_NGINX_VERSION="v1.11.3"; WEBHOOK_CERTGEN_VERSION="v1.4.3"

# 易用性（09：补全/别名/metrics-server/k8s-diagnose CLI）
INSTALL_METRICS_SERVER=true; INSTALL_KUBECTL_ALIASES=true

# etcd 每日快照
ETCD_SNAPSHOT_ENABLED=true; ETCD_SNAPSHOT_KEEP=7; ETCD_SNAPSHOT_CRON="0 2 * * *"

# Prometheus 监控套件（10：自部署 kube-prometheus-stack，不用 Kuboard 内置）
PROMETHEUS_STACK_CHART_VERSION="90.0.0"; PROMETHEUS_NAMESPACE="monitoring"
PROMETHEUS_ADMISSION_WEBHOOKS="true"    # certgen 用 ingress 官方版，KPS_CERTGEN_IMAGE 可改
KPS_CERTGEN_IMAGE="registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.5.1"
PROMETHEUS_STORAGE_CLASS="local-path"; PROMETHEUS_STORAGE_SIZE="100Gi"   # TSDB 走本地盘，NFS 不适合
PROMETHEUS_RETENTION="15d"; PROMETHEUS_RETENTION_SIZE="40GB"
PROMETHEUS_CPU_REQ="2"; PROMETHEUS_MEM_REQ="8Gi"; PROMETHEUS_CPU_LIM="4"; PROMETHEUS_MEM_LIM="16Gi"
ALERTMANAGER_STORAGE_CLASS="nfs-client"; ALERTMANAGER_STORAGE_SIZE="2Gi"
GRAFANA_STORAGE_CLASS="nfs-client"; GRAFANA_STORAGE_SIZE="5Gi"
GRAFANA_NODEPORT="30300"; PROMETHEUS_NODEPORT="30900"; ALERTMANAGER_NODEPORT="30903"
GRAFANA_ADMIN_USER="admin"; GRAFANA_ADMIN_PASSWORD=""   # 留空 = 自动生成，存 helm-values/grafana-admin-password.txt

# Graylog（占位符时 07 只生成 values 不部署）
GRAYLOG_HOST="GRAYLOG_HOST_IP_PLACEHOLDER"; GRAYLOG_PORT="52201"; GRAYLOG_PROTOCOL="udp"
```

---

## Prometheus 监控套件（10）

**为什么自部署而不用 Kuboard 内置监控**：Kuboard 内置套件的配置会被自动恢复（改了 Grafana 大盘/Alertmanager 规则都会被还原），自部署官方 chart 完全可控。

### 架构与组件（kube-prometheus-stack 90.0.0，operator v0.93.1）

| 组件 | 版本 | 持久化 | 访问 |
|------|------|--------|------|
| Prometheus | v3.14.0 | local-path 100Gi（本地盘） | NodePort 30900 |
| Alertmanager | v0.34.0 | nfs-client 2Gi | NodePort 30903 |
| Grafana | 13.2.1 | nfs-client 5Gi | NodePort 30300（admin / 密码见 helm-values/grafana-admin-password.txt） |
| node-exporter | v1.12.1 | - | DaemonSet（宿主机指标） |
| kube-state-metrics | v2.20.0 | - | K8s 对象指标 |
| Prometheus Operator | v0.93.1 | - | 管理 CRD（ServiceMonitor/PodMonitor/...） |

```bash
# 日常运维
helm list -n monitoring                       # release 名 kps
kubectl get pods -n monitoring                # 别名 kgpa
sudo SKIP_CONFIRM=1 bash k8s-online-install/scripts/10-prometheus-stack.sh   # 重跑 = helm upgrade

# 自定义监控：部署 ServiceMonitor / PodMonitor 即被自动纳管（values 已放开 selector）
# Grafana 数据源（Prometheus）与 K8s 监控大盘由 chart 自动配置，开箱即用
```

### 关键设计决策

- **TSDB 走 local-path 不走 NFS**：Prometheus 写入是大量小 IO + WAL fsync，NFS 延迟会拖垮 ingest（同时拉高 nfsd 线程占用，殃及其它 PVC）。本地盘 `/data/k8s/pv`，100Gi、保留 15d / 40GB。
- **admission webhook 开启（`PROMETHEUS_ADMISSION_WEBHOOKS`，见坑 22）**：certgen 用 ingress-nginx 官方 `registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.5.1` override 掉 chart 默认的 ghcr.io jkroepke fork——实测 v1.5.1 的 create/patch 参数与默认证书密钥名 `cert/key` 与 kps 期望完全一致（非法 CR 已验证被准确拦截）。镜像一律以官方名为准（quay.io / registry.k8s.io / docker.io 官方仓库 tag），同步通道只做搬运不改引用。**certgen 是集群级公共件**（06 ingress-nginx 与 10 kps 的 admission webhook 共用同一工具同一镜像），归 `images-manager.sh`「K8s 基础组件」分组统一维护；镜像路径带 `ingress-nginx` 只是上游项目归属（该工具由 ingress-nginx 仓库维护），非 ingress 专属，保持官方名不改 tag。prometheus 专属清单 `prometheus-stack-images.txt` 已将其移除避免重复。
- **Prometheus 容器以 root 运行**（见坑 23）：local-path（hostPath）不响应 fsGroup，非 root 必然 permission denied。
- **kubeProxy / kubeEtcd 采集已关**：kube-proxy 指标只监听 `127.0.0.1:10249`，Pod 侧抓不到（不关会有 targetDown 常驻告警）；etcd 指标需客户端证书认证，配置复杂且已有每日快照兜底。
- **scheduler / controller-manager 采集**：静态 Pod 指标在节点 IP 的 10259/10257（https，kubelet serving 证书），values 里 endpoints 指向节点 IP + `insecureSkipVerify: true`。
- **镜像 8 个全部 arm64 多架构验证**（certgen 归基础镜像清单不计入；全部走 certs.d 加速通道在线可拉或已 load），清单在 `helm-values/prometheus-stack-images.txt`，走 images-manager.sh 通道同步注入（用户自行处理）；chart 离线包已打包在 `charts/kube-prometheus-stack-90.0.0.tgz`（缺失时脚本自动 helm repo 兜底）。
- **Grafana 密码幂等**：config.env 留空时首次生成 20 位随机密码写入 `helm-values/grafana-admin-password.txt`（600，sudo 读），重跑复用，不会漂移。
- **实测结果**：16/16 抓取目标 UP（apiserver/coredns/kubelet+cadvisor+probes/node-exporter/ksm/scheduler/controller-manager/自身组件），Grafana 数据源（Prometheus/Alertmanager）由 chart 自动配置。

---

## 集群调优参数详解（04）

### kubelet（/var/lib/kubelet/config.yaml，经 kubelet-config ConfigMap 下发）

| 参数 | 值 | 说明 |
|------|-----|------|
| `systemReserved` | cpu 2000m / mem 2% / disk 4Gi | **顶层字段**（不是 `resources.reserved`，那是错的），影响 Node Allocatable 计算 |
| `kubeReserved` | cpu 1000m / mem 2% / disk 2Gi | 控制平面组件预留 |
| `enforceNodeAllocatable` | [pods] | 只硬限制 Pod（改 system-reserved 需 systemd cgroup 配套，风险大） |
| `evictionHard` | mem<5% nodefs<10% imagefs<15% inodes<5% | 1TiB 内存 5%≈50Gi，保证 OOM 前先驱逐 |
| `evictionSoft` + grace period | mem<10% nodefs<15% | 软阈值提前预警 |
| `evictionMaxPodGracePeriod` | 90s | 驱逐时给 Pod 的最长宽限 |
| `containerLogMaxSize/Files` | 100Mi × 3 | **CRI 日志轮转归 kubelet 管，containerd 不管**（老配置 10Mi 太小，Java 应用动辄截断） |
| `maxPods` | 250 | 大内存单节点放宽（默认 110） |
| `kubeAPIQPS/Burst` | 50/100 | 大批量 Pod 时 kubelet 与 apiserver 的交互限速 |
| `shutdownGracePeriod` | 30s（critical 10s） | 节点关机时先优雅停普通 Pod |

> ⚠️ 只配置 configz 里实际存在的字段。`maxParallelImagePulls`/`plegRelistPeriod` 在本版本 configz 未暴露，乱加会导致 kubelet 起不来（脚本已内置回滚）。

### 静态 Pod（/etc/kubernetes/manifests/*.yaml）

**必须改 manifest 文件**，`kubectl patch pod` 对静态 Pod 无效（kubelet 会用文件覆盖回去）：

| 组件 | 参数 |
|------|------|
| kube-apiserver | `--max-requests-inflight=2000` `--max-mutating-requests-inflight=1000` `--default-not-ready-toleration-seconds=60` `--default-unreachable-toleration-seconds=60` |
| kube-controller-manager | 并发 syncs deployment/replicaset/service=10/10/20、HPA 周期 30s、`--terminated-pod-gc-threshold=1000` |
| kube-scheduler | `--kube-api-qps=50` `--kube-api-burst=100`（**不能加 `--parallelism`**：scheduler 无此 CLI flag，只有 KubeSchedulerConfiguration 配置字段且 v1 默认值就是 16，写入即 unknown flag → CrashLoopBackOff） |

> ⚠️ `--pod-eviction-timeout` 已废弃，v1.29 传入会让 controller-manager crash loop（老脚本踩过）。脚本每个 manifest 先备份，Pod 异常自动回滚。

### 网络优化

| 项 | 值 | 说明 |
|-----|-----|------|
| kube-proxy 模式 | ipvs | 已是 ipvs（比 iptables 强在大规模 Service 下的规则查找 O(1)） |
| Calico ipipMode | IPIP Always（operator 管理） | sealos 的 Calico 由 **tigera-operator** 管理（Installation CR `encapsulation: IPIP`），手动 patch ippool 为 CrossSubnet 会被秒级回改，operator API 也无 CrossSubnet 选项。**单节点无跨节点流量，IPIP 无实际开销**；未来扩多节点且同网段时，改 Installation 的 encapsulation 并评估 |
| sysctl | conntrack_max=2621440、somaxconn=65535、rmem/wmem_max=16MiB 等 | 见 `/etc/sysctl.d/99-kubernetes.conf` |
| 内核模块 | overlay, br_netfilter, ip_vs*, nf_conntrack | `/etc/modules-load.d/k8s-modules.conf` |

### NFS 优化（03）

| 项 | 值 | 说明 |
|-----|-----|------|
| nfsd 线程 | 32（`NFSD_THREADS`） | 默认 8 是单机 NFS 卡顿的常见根因；`cat /proc/fs/nfsd/threads` 验证 |
| SC mountOptions | `hard, nfsvers=3, rsize/wsize=1048576, timeo=600` | 1MiB 大块读写；hard 保证写完整（服务端挂了会 hang 而不是丢数据）。**★ 必须 v3 不用 v4.x**：v4 走 idmap，域名不匹配时客户端内核把文件属主解析成 nobody(65534)，mysqld(999) 写 redo 报 EACCES(13) CrashLoop（见坑 25）；v3 AUTH_SYS 纯数字权限检查无此问题 |
| SC pathPattern | `${.PVC.namespace}/${.PVC.name}` | PVC 数据按 **`/data/nfs/{命名空间}/{PVC名}/`** 嵌套存放（替代默认扁平 `ns-pvcname-pvuid`）；`db` 命名空间另有预建目录 `/data/nfs/db/{mysql,redis,es/*,kafka,doris}`（config.env `NFS_*_DIR`） |
| 默认 SC 去重 | 自动 | 双 default SC 调度行为不可预测，脚本自动摘掉其它 SC 的 default 标记 |
| 自适应部署 | Helm/raw 双模式 | 检测到 Helm 装的 provisioner 只调整 SC；**SC parameters 不可变**，pathPattern 不符时脚本自动删 SC 重建（不影响已绑定 PV，日后 helm upgrade provisioner 需带 `--set storageClass.pathPattern`） |

### etcd 备份

- 每天 02:00 cron（`/etc/cron.d/etcd-backup`）→ `/data/nfs/backup/etcd/`，保留 7 份
- 手动触发：`sudo /usr/local/bin/k8s-etcd-backup.sh`，日志 `/var/log/etcd-backup.log`
- 恢复：`etcdctl snapshot restore <db> --data-dir=/var/lib/etcd.restored` 后替换数据目录重启 etcd

---

## 易用性（09）

**命令补全**（kubectl / helm / crictl / kubeadm / sealos 视版本）：
- 系统级文件 `/etc/bash_completion.d/<tool>`，root + 普通用户 ~/.bashrc 各写一份标记块
- 幂等：`# >>> k8s-sealos usability block >>>` 标记块重写，历史遗留的重复 alias / source 不存在文件的行自动清理
- 验证：`bash -ic 'type __start_kubectl'` 有输出即正常

**别名**：

| 别名 | 命令 |
|------|------|
| `k` | kubectl（带补全） |
| `kgp` / `kgpa` | get pods / get pods -A |
| `kgd` / `kgs` / `kgn` | get deployment / svc / nodes |
| `kdel` | delete |
| `kl` | logs -f |
| `kex` | exec -it |
| `kdesc` | describe |
| `kdiag` | k8s-diagnose（集群故障一键排查） |

**metrics-server**：`kubectl top nodes / kubectl top pods -A`；自签 kubelet 证书场景已带 `--kubelet-insecure-tls`；镜像走 k8s.m.daocloud.io 加速。

**crictl**：`/etc/crictl.yaml` 预置 containerd endpoint，`crictl ps` 开箱即用。

**诊断 CLI（k8s-diagnose）**：源文件在 `diagnostics/k8s-diagnose.sh`，09 脚本安装到 `/usr/local/bin/k8s-diagnose`（任意目录可用，带 `--fix/--verbose` 补全）：

```bash
k8s-diagnose              # 全链路诊断：节点/控制面/网络/DNS/存储/镜像拉取/Pod/事件
k8s-diagnose --fix        # 诊断 + 自动执行安全修复（delete 异常 Pod 触发重建）
k8s-diagnose --verbose    # 显示详细过程（含正常项和执行过的命令）
kdiag                     # 别名等价
```

---

## 各脚本要点

### 00 彻底清理（重装前必跑）

**关键清理项**：
- `/root/.sealos/default/Clusterfile` ← **#1 blocker**（sealos 报 "cluster status is not ClusterSuccess" 的根因）
- `/var/lib/systemd/deb-systemd-helper-masked/containerd.service` ← Docker deb mask 掉 containerd
- `/opt/containerd/bin/` ← Docker 旧二进制
- `/var/lib/containers/storage/overlay/*/merged` ← podman busy mount（umount -l 强制卸载）

### 01 系统前置

Swap 关 / ufw disable / 内核模块 / sysctl（ip_forward、conntrack 262 万、**ARP gc_thresh 1024/2048/4096**、conntrack 超时、netdev_max_backlog、**vm.overcommit_memory=1（ES 必需）**、pid_max 419 万、somaxconn 65535、rmem/wmem 16MiB、inotify 100 万 watch）/ 依赖包（**python3-yaml 是 04 的硬依赖**、dnsutils 供 07 验证 DNS、bash-completion）/ chrony / 预装 nfs-kernel-server + **nfs-common**（Ubuntu 客户端包名是 nfs-common，RHEL 系才叫 nfs-utils；每个 K8s 节点挂 NFS PVC 都必须有它）

### 02 Sealos K8s 安装

1. **幂等**：集群已在跑（有 Ready 节点）则跳过安装只做收尾
2. 下载 sealos CLI（ghproxy 优先）
3. `sealos run labring/kubernetes:v1.29.9 labring/helm:v3.12.0 labring/calico:v3.28.1 --single`
4. kubeconfig 同时配 root 和 sudo 发起用户
5. containerd 加速器 **幂等 + 失败自动回滚**（TOML 里重复 table 定义会让 containerd 起不来；只追加子表不追加父表）
6. Sealos 自动：装 containerd(1.7.27)/kubeadm/kubelet/etcd、内部 registry(sealos.hub:5000)、证书 99 年

### 03 NFS 存储类

见上文「NFS 优化」。StorageClass `nfs-client`（default, Retain, WaitForFirstConsumer）。raw 部署清单落盘 `helm-values/nfs-subdir-external-provisioner.yaml`。

### 04 调优

见上文「集群调优参数详解」。全部带备份回滚。

### 05 Kuboard v4 —— NodePort 30080，内置 MySQL，配置全部内置 kuboard 命名空间

- **v4 与 v3 架构不同**：v4 用 MySQL 持久化（不再需要 etcd）；本机部署自带 MySQL 8.4 于 kuboard 命名空间，数据落 NFS PVC（/data/nfs/kuboard）
- DB 连接通过 `kuboard-config` Secret 注入（DB_DRIVER/DB_URL/DB_USERNAME/DB_PASSWORD），无需改 kuboard 镜像
- Service NodePort 30080（web）+ 30443（TLS）
- 镜像用官方名 `eipwork/kuboard:v4`，由 `images-manager.sh sync + load2k8s` 注入（daocloud 对 eipwork 仓库 403，必须走 SWR 通道）
- 首次登录 admin / Kuboard123（密码策略：初始密码 3 天有效、连续错 5 次锁 60s，登录后立即改密）
- **导入当前集群（UI 手动，约 30 秒）**：登录 Kuboard → 添加集群 → 粘贴 `/etc/kubernetes/admin.conf` 全文 → 提交。kuboard server 在集群内，直连 apiserver 无需 agent
- 自动导入（脚本化）已调研：REST API 存在（`POST /api/cluster.kuboard.cn/v4/cluster` + `ping-apiserver` 预检，见坑 20），但 REST 登录未通，暂不可脚本化

### 06 ingress-nginx —— hostNetwork 80/443，整合 k8s-optimizations 生产优化配置

- `hostNetwork: true + dnsPolicy: ClusterFirstWithHostNet`，控制器直接绑宿主机 80/443（流量路径: 用户 → ELB → 节点），无需 NodePort
- **JSON 访问日志**（23 字段：request_id/uri/upstream_*/realip 还原后的用户 IP），Fluent Bit 直接采集
- 安全：custom-headers CM 全局注入 HSTS/X-Frame-Options 等响应头、server-tokens off、隐藏上游指纹、TLS1.2+1.3 弱套件禁用
- 性能：gzip+brotli 双压缩、upstream keepalive 连接池、限定重试（tries=3/10s）防重试风暴
- admission webhook：certgen Job 自动签证书，非法 ingress 在提交时即被拒绝
- 清单版本控制在 `manifests/ingress-nginx.yaml`，脚本 sed 注入镜像版本后 apply
- 验证：宿主机 ss 80/443 监听、curl 默认后端 404、JSON 日志 `kubectl logs -n ingress-nginx -l app.kubernetes.io/component=controller`

### 07 Fluent Bit → Graylog

- **GRAYLOG_HOST 是占位符时只生成 values 不部署**（避免日志发不出去的空转 DaemonSet），填好 IP 重跑即可
- multiline.parser docker+cri（Java 堆栈不撕裂）、systemd 采集 kubelet 日志、grep 排除系统命名空间、Gelf_Short_Message_Key=log
- values 落盘 `helm-values/fluent-bit-values.yaml`

### 08 验证

控制平面 / kube-proxy 模式 / Calico 模式 / DNS（宿主机 dig @ClusterIP，不再起测试 Pod）/ SC 唯一 default / nfsd 线程 / **kubelet configz 核验调优是否真生效** / 补全文件 / metrics-server / etcd 快照 / 证书 / 全集群异常 Pod 扫描

### 09 易用性

见上文「易用性」。08 验证已包含 ingress（80/443 监听/IngressClass）与 Kuboard（30080）检查。

---

## 踩过的坑（完整实录）

### 坑 1：sealos 秒退 "Error: cluster status is not ClusterSuccess"

**根因**（按顺序排查）：
1. Docker deb 在 `/var/lib/systemd/deb-systemd-helper-masked/` mask 了 containerd.service
2. `/opt/containerd/bin/` 有 Docker 旧二进制
3. `/var/lib/containers/storage/overlay/*/merged` podman busy mount，rm 不掉
4. `/root/.sealos/default/Clusterfile` ← **这个是 #1 blocker**（上次失败的 phase: ClusterFailed 让 sealos 认为集群已存在，直接秒退）

**修复**：`rm -rf /root/.sealos` ← 这一个动作让 sealos 立刻工作。

### 坑 2：Docker Hub IPv4 不通

`registry-1.docker.io` IPv4 超时。所有组件必须走 daocloud 等镜像代理。

### 坑 3：Calico 需要 Helm CLI

`sealos run labring/calico:xxx` 报 `helm: 未找到命令`（calico 被包装成 Helm chart）。解决：先 `sealos run labring/helm:v3.12.0`。

### 坑 4：kubelet 配置的真正来源是本地文件

kubeadm 默认不开 dynamic kubelet config，kubelet 只读 `/var/lib/kubelet/config.yaml`；`kubelet-config` ConfigMap 只是模板，改 CM + 重启 kubelet 也不会生效。04 脚本同时改本地文件（真配置）和 CM（保持一致性），重启后 configz 核验。

### 坑 5：Sealos 内部 registry 不同步

自己 `ctr pull` 的镜像不会自动进 sealos.hub:5000。解决：`ctr images tag <mirror-tag> sealos.hub:5000/<path>`（03/05 脚本已内置）。

### 坑 6：kubectl patch pod 对静态 Pod 无效

静态 Pod 由 kubelet 从 manifest 文件管理，patch 会被文件内容覆盖回去。必须改 `/etc/kubernetes/manifests/*.yaml`。

### 坑 7：kubelet 配置里写不存在的字段 = kubelet 起不来

v1beta1 KubeletConfiguration 是严格校验。例如 `resources.reserved`（不存在，正确的是顶层 `systemReserved`）、`maxParallelImagePulls`（本版本 configz 未暴露）。04 脚本只写 configz 验证过的字段 + 失败回滚。

### 坑 8：containerd 日志轮转是伪命题

CRI 运行时（containerd）场景，容器日志轮转由 **kubelet** 的 `containerLogMaxSize/containerLogMaxFiles` 负责，改 containerd config.toml 没用（那是 Docker daemon.json 的概念）。

### 坑 9：双默认 StorageClass

local-path 和 nfs-client 同时标 default 时，未指定 SC 的 PVC 绑定行为不可预测。03 脚本每次运行自动去重。

### 坑 10：命令补全在集群装好前配置必然失败

老流程在 01（kubectl 未装）就写补全 → 文件没生成 + bashrc 盲 append 垃圾行。现在统一放 08，幂等标记块写入。

### 坑 11：TOML 重复 table 定义 → containerd 起不来

containerd config.toml 里 `[...registry.mirrors]` 父表已存在时再 append 一份同名 table，TOML 解析直接失败。02 脚本：只追加子表 / 检测已存在则改 endpoint 行 / 重启后健康检查 / 失败回滚。

### 坑 12：`ctr images pull` 不走 certs.d 镜像加速

certs.d 的 mirror 配置是 **CRI 插件**的设置，kubelet 拉镜像走 mirror；但 `ctr` 裸客户端直连上游（被墙超时）。手工预拉必须加 `--hosts-dir /etc/containerd/certs.d`。已内置到 05/06 脚本。

### 坑 13：certgen Job 忘配 serviceAccountName → RBAC 拒绝死循环

ingress-nginx admission 的 create/patch Job 未指定 `serviceAccountName: ingress-nginx-admission` 时用 default SA，`secrets get` 被拒 → CrashLoopBackOff → webhook secret 建不出来 → controller 挂载证书卷失败。同时 patch Job 还需要 ClusterRole 授权 `admissionregistration.k8s.io get/update/patch`；controller 自己要 `pods get`（启动时取自身 Pod 信息）。manifest 已内置全部修复。

### 坑 14：`ssl-session-cache` 是布尔键，不是 nginx 的 size 语法

ConfigMap 里写 `ssl-session-cache: shared:SSL:10m` 会让 controller 启动崩溃（`cannot parse as bool`）。正确写法：`ssl-session-cache: "true"` + `ssl-session-cache-size: 10m`。

### 坑 15：Kuboard v3 → v4 是换数据库的架构变化

v3 用内置 etcd + kubeconfig 挂载；v4 用 MySQL（DB_URL 注入）。v3 升 v4 不能沿用旧数据，需按全新部署。daocloud mirror 对 `eipwork/*` 仓库返回 403（不要试图绕），统一走 `images-manager.sh sync eipwork` → SWR → `load2k8s` 通道。

### 坑 16：load2k8s 注入的镜像 tag 必须完整限定 docker.io 前缀

kubelet 查本地镜像前会把镜像名规范化为完整引用（`eipwork/kuboard:v4` → `docker.io/eipwork/kuboard:v4`）。`to_full_ref` 若对含命名空间的镜像"原样"打短名 tag，kubelet ImageStatus 查不到 → 走 daocloud 外网拉取 → `eipwork/*` 403 → ImagePullBackOff。`mysql:8.4` 能命中是因为它被补全成 `docker.io/library/mysql:8.4`。已修复：`to_full_ref` 对 `组织/镜像` 补 `docker.io/`、对裸短名补 `docker.io/library/`、带域名 registry 原样。存量短名镜像用 `ctr -n k8s.io images tag` 补 tag 即可，无需重新下载。

### 坑 17：Kuboard v4 DB_URL 的 characterEncoding 要 Java 字符集名

JDBC 的 `characterEncoding` 参数是 **Java charset**，必须写 `UTF-8`；写 MySQL 字符集 `utf8mb4` 会在连接初始化时抛 `Unsupported character encoding 'utf8mb4'` → CrashLoopBackOff。MySQL 8.x 下 `characterEncoding=UTF-8` 自动映射服务端 utf8mb4（服务端由 `--character-set-server=utf8mb4` 保证）。

### 坑 18：kuboard-agent 不需要预装

Kuboard v4 Web 界面不依赖 agent；只有通过界面"导入集群"纳管时，server 才自动创建 kuboard-agent Deployment（引用上游 `eipwork/kuboard-agent:v3`，上游没有 v4 tag）。不预装、不预拉，需要时再说。

### 坑 19：NodePort 在 `ss -tlnp` 里看不到 LISTEN，且 127.0.0.1 不通

kube-proxy(ipvs) 对 NodePort 的转发是**内核态 IPVS 规则**（`sudo ipvsadm -Ln -t <节点IP>:<NodePort>` 可见），不产生任何 TCP LISTEN socket，所以 `ss -tlnp` 看不到 30080 属正常，不代表服务不可用。两个连带现象：
- IPVS 只绑节点 IP 和 Service VIP（kube-ipvs0 上的 /32），**不绑 127.0.0.1** → `curl 127.0.0.1:<NodePort>` 连接拒绝，必须用节点 IP 访问。
- `ss` 输出里 `127.0.0.1:30080 ↔ 127.0.0.1:2379 ESTABLISHED` 这类条目是 kube-apiserver 连 etcd 时内核随机分配的**临时源端口**恰好撞上 30080，与 NodePort 无关。
- 验证服务是否正常：`curl http://<节点IP>:<NodePort>`；VPN 环境访问不了就走 SSH 隧道（见「远程访问」章节）。

### 坑 20：Kuboard v4 的 REST 登录 API 直接调用返回 Bad credentials

OpenAPI 在 `http://<节点IP>:30080/v3/api-docs`（89 个端点，含集群导入 `POST /api/cluster.kuboard.cn/v4/cluster`、预检 `POST .../cluster/0/ping-apiserver`）。但直接 POST `/api/login.kuboard.cn/v4/login`（body 含 `userSource:"dao"`）返回 `{"message":"Bad credentials","code":500}`——而 DB 里 admin 的 bcrypt 哈希已验证就是 Kuboard123、`accountLocked: false`、无 MFA。说明前端登录请求还带了未确认的前置条件（cookie/header/字段）。**结论：自动导入集群留待用浏览器抓包确认后实现，当前用 UI 手动导入**（见 05 脚本说明）。

### 坑 21：`tr -dc ... < /dev/urandom | head` 在 `set -o pipefail` 下 SIGPIPE

10 号脚本首次运行在生成 Grafana 密码时退出码 141（SIGPIPE）：/dev/urandom 是无限流，`head -c 20` 取够字节就退出，tr 继续写管道收到 SIGPIPE，`set -o pipefail` 把 141 当失败直接中止脚本。databases/generate-passwords.sh 之所以没炸是因为管道尾巴挂了 `|| true`。**修复：改用 `python3 -c 'import secrets...)'` 生成，无管道无风险**。同类坑：任何「无限流 | head」组合在 pipefail 脚本里都要小心（`yes | head` 同理）。

### 坑 22：kube-prometheus-stack 关 admission webhook 后，operator 还会因 tls-secret 挂载卡死

只设 `prometheusOperator.admissionWebhooks.enabled=false` 不够：operator Deployment 的 tls 证书卷挂载由 **`prometheusOperator.tls.enabled`**（默认 true）控制，与 admission webhook 开关是两个独立字段。webhooks 关掉后 Secret 不会创建，但卷还在 → `FailedMount: secret "kps-kube-prometheus-stack-admission" not found` 循环。**必须同时设 `tls.enabled: false`**（operator 改走 HTTP）。连带：certgen 镜像 `ghcr.io/jkroepke/kube-webhook-certgen:1.8.8` 是 helm **pre-install 钩子**，缺镜像会卡死整个 install 直到超时（15m），release 留在 pending/failed 态。清理：`helm uninstall`（failed 态可直接卸载）+ 删残留 Job。

**终局方案（certgen 同源不同家的坑）**：kube-prometheus-stack 默认用 ghcr.io 上维护者 jkroepke 的 kube-webhook-certgen fork，与 ingress-nginx 官方 `registry.k8s.io/ingress-nginx/kube-webhook-certgen` 是同一工具的血统但发布渠道不同——ghcr 无 certs.d 加速通道，官方版有。**不要凭经验认为"官方版默认写 tls.crt/tls.key 不能换"**：实测 v1.5.1 官方版 `create` 的默认密钥名已改为 `cert/key`（老版 jette 才是 tls.crt/tls.key），与 kps chart 期望（`--web.cert-file=/cert/cert`）完全对齐；chart 传的参数（create：`--host/--namespace/--secret-name`；patch：`--webhook-name/--namespace/--secret-name/--patch-failure-policy`）v1.5.1 全支持。**values 里 override `prometheusOperator.admissionWebhooks.patch.image` 即可无痛换官方版**（config.env `PROMETHEUS_ADMISSION_WEBHOOKS=true` + `KPS_CERTGEN_IMAGE`，10 号脚本生成）。验证手段：`kubectl run tmp --image=<certgen> -- patch --help` 查参数 + 提交非法 CR 看是否被 webhook 拦截。

### 坑 23：local-path PV + volumeMount subPath，非 root 容器必然 permission denied

Prometheus STS（chart 90 默认 uid=1000/g=2000）启动即崩：`open /prometheus/queries.active: permission denied`。三层原因叠加：① local-path 底层是 hostPath，kubelet **不支持 fsGroup 权限赋予**（k8s 对 hostPath 的硬限制）；② chart 的 volumeMount 带 **subPath（prometheus-db/）**，子目录由 kubelet 以 root 建出，外层 777 也没用；③ local-path-provisioner 的 setup 脚本若只 `mkdir -p` 不给权限，新 PV 目录就是 root:755。**修复（三管齐下）**：provisioner setup 改为 `mkdir -m 0777 -p "$VOL_DIR"`（10 号脚本有自愈检测）；存量 PV 目录手动 `chmod 777`；Prometheus `securityContext` 设 runAsUser 0（单节点 lab 权衡，无额外镜像依赖）。同类问题适用所有「非 root + local-path + subPath」组合。

### 坑 24：StorageClass parameters 与 PV nfs.path 都是不可变字段

想给 nfs-client 加/改 `pathPattern`（PVC 目录从扁平 `ns-pvcname-pvuid` 改嵌套 `{ns}/{pvc}`）时：`kubectl patch sc` 直接被拒 `Forbidden: updates to parameters are forbidden`；想改存量 PV 的路径绕过数据迁移，`kubectl patch pv` 同样被拒 `spec.persistentvolumesource is immutable after creation`。**唯一路径**：SC 删了重建（不影响已绑定 PV/PVC，只影响新 PVC）；存量 PV 想换目录只能「scale 0 → 删 PVC/PV → 数据搬新目录 → 重建 PVC（带原 helm ownership 注解，防 helm upgrade 报 not owned）→ scale 1」。StatefulSet 的 PVC 删掉后由 STS 控制器自动重建。另注意：prometheus-operator 会把 StatefulSet replicas 拉回期望值，scale 0 会被覆盖，强删 pod 即可。

### 坑 25：NFS 挂载用 nfsvers=4.x 时 MySQL InnoDB 必崩（idmap 属主漂移）

nfs-client SC 的 mountOptions 配 `nfsvers=4.1` 后，kuboard-mysql 初始化成功但正式启动即 crash：`[InnoDB] Operating system error number 13` → `Assertion failure: log0files_io.cc`。**根因**：NFSv4.x 走 idmap，本机（server）与容器挂载端的 idmap domain 不一致时，客户端内核把 server 发来的 owner string 解析失败 → 文件属主在客户端视角漂移成 nobody(65534)（症状：目录组显示 `nogroup` 而非真实 gid；宿主机本地以同 uid 访问一切正常——因为走的是本地 XFS 不经 idmap）→ mysqld(999) 权限检查失败 EACCES(13)。**以 root 运行的容器（alertmanager/grafana）不受影响，所以只有 mysql 崩**。**修复**：mountOptions 固定 `nfsvers=3`（AUTH_SYS 纯数字权限检查，无 idmap 参与），删除 PVC/PV 重新 provision（空数据直接删）。验证：`stat -c %u:%g` 数据目录显示纯数字 gid 且 pod Running。

---

## 紧急故障排查

```bash
# 第一步永远是：一键全链路诊断（自动定位 90% 常见问题）
k8s-diagnose --verbose            # 未安装时: bash k8s-online-install/diagnostics/k8s-diagnose.sh
# NotReady → kubelet/containerd
journalctl -u kubelet --no-pager | tail -50
journalctl -u containerd --no-pager | tail -30

# ImagePullBackOff
kubectl describe pod <pod> | grep -A3 Events
sudo crictl images ls | grep <image>

# DNS 测试（宿主机直查 CoreDNS）
dig +short kubernetes.default.svc.cluster.local @10.96.0.10

# Calico 挂了 → 先装 Helm 再装 Calico
sealos run labring/helm:v3.12.0
sealos run labring/calico:v3.28.1 --force

# kubelet 调优后起不来 → 本地配置备份在 /var/lib/kubelet/config.yaml.bak.*
sudo cp /var/lib/kubelet/config.yaml.bak.<时间戳> /var/lib/kubelet/config.yaml && sudo systemctl restart kubelet

# 静态 Pod 参数有毒 → manifest 备份在 /etc/kubernetes/manifests/*.bak.*
cp /etc/kubernetes/manifests/kube-apiserver.yaml.bak.* /etc/kubernetes/manifests/kube-apiserver.yaml  # 按实际备份文件名

# etcd 手动快照 / 查看
sudo /usr/local/bin/k8s-etcd-backup.sh && tail /var/log/etcd-backup.log

# 彻底重置（回到 clean 状态）
sudo SKIP_CONFIRM=1 bash deploy.sh cleanup
sudo SKIP_CONFIRM=1 bash deploy.sh
```

---

## 集群信息速查

| 项目 | 值 |
|------|-----|
| OS | Ubuntu 22.04.4 LTS |
| 架构 | ARM64 (aarch64) |
| K8s | v1.29.9 |
| containerd | 1.7.27 (sealos 内置) |
| CNI | Calico v3.28.1（tigera-operator 管理，IPIP Always） |
| kube-proxy | ipvs |
| 存储 | NFS → /data/nfs（nfsd 32 线程），PVC 按 `/data/nfs/{命名空间}/{PVC名}/` 嵌套 |
| StorageClass | nfs-client（唯一 default，Retain，1MiB 块，nfs3+hard，pathPattern 嵌套目录） |
| 证书有效期 | 99 年 (sealos) |
| sealos registry | sealos.hub:5000 (admin:passw0rd) |
| Kuboard | http://NODE_IP:30080 |
| metrics-server | kubectl top 可用 |
| Prometheus | http://NODE_IP:30900（kube-prometheus-stack 90.0.0，TSDB local-path 100Gi，保留 15d/40GB） |
| Grafana | http://NODE_IP:30300（admin / helm-values/grafana-admin-password.txt） |
| Alertmanager | http://NODE_IP:30903 |
| etcd 快照 | 每日 02:00 → /data/nfs/backup/etcd（保留 7 份） |
| 补全/别名 | kubectl/helm/crictl/kubeadm + k/kgp/kgpa/kl... |

---

## 后续扩展

```bash
sealos add --nodes <ip> --passwd <pw>     # 扩节点
sealos run labring/kubernetes:v1.30.x --upgrade  # 升级 K8s（升级会重写静态 Pod manifest，之后重跑 04）

# 恢复 etcd
ETCDCTL_API=3 etcdctl snapshot restore /data/nfs/backup/etcd/etcd-snapshot-XXX.db \
  --data-dir=/var/lib/etcd.restored
# 然后停 kubelet、替换 /var/lib/etcd、重启

helm install ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx --create-namespace
```

> 注：数据库（MySQL/Redis/ES/Kafka）与 Doris 部署在 `databases/` 目录，不在本目录范围内。
