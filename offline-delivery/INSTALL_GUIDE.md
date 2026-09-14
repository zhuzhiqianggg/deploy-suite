# 离线安装操作手册

> 适用版本：v1.0 (2026-07-06)
> 支持架构：ARM64 (aarch64) / AMD64 (x86_64)
> 目标系统：openEuler 22.03（兼容同类 RPM 系 Linux）
> 离线环境：目标服务器无法访问外网

本文档面向**最终用户**（需要部署离线系统的运维/测试工程师），从环境准备到生产部署，全流程手把手教学。

---

## 目录

1. [架构与组件](#1-架构与组件)
2. [环境准备](#2-环境准备)
3. [离线包选择](#3-离线包选择)
4. [K8s 集群部署](#4-k8s-集群部署)
5. [Worker 节点加入（可选）](#5-worker-节点加入可选)
6. [Docker 部署](#6-docker-部署)
7. [业务数据库部署](#7-业务数据库部署)
8. [部署验证清单](#8-部署验证清单)
9. [常见问题排查](#9-常见问题排查)
10. [卸载与清理](#10-卸载与清理)

---

## 1. 架构与组件

### 1.1 系统架构图

```
┌─────────────────────────────────────────────────────────────────┐
│                        目标离线环境（无外网）                    │
│                                                                   │
│  ┌─────────────────────────────────┐  ┌────────────────────┐   │
│  │   K8s 集群（master 节点）       │  │ 数据库服务器（独立）│   │
│  │                                  │  │                    │   │
│  │  • K8s 1.33.6 (control-plane)   │  │  • MySQL 8.4       │   │
│  │  • Calico CNI                    │  │  • Redis 8.8       │   │
│  │  • ingress-nginx (DaemonSet)     │  │  • Kafka 4.0.2     │   │
│  │  • Prometheus + Grafana          │  │  • NebulaGraph     │   │
│  │  • metrics-server                │  │  • Doris           │   │
│  │  • NFS Client Provisioner        │  │  • Elasticsearch   │   │
│  │  • Kuboard v4 (NodePort 30080)  │  │  (docker-compose)  │   │
│  │  • image-cri-shim (镜像代理)     │  │                    │   │
│  │  • sealos.hub:5000 (本地registry)│  │                    │   │
│  └─────────────────────────────────┘  └────────────────────┘   │
│                                                                   │
│  ┌─────────────────────────────────┐                            │
│  │   K8s Worker 节点（可选）         │                            │
│  │  • 加入现有集群                  │                            │
│  │  • 自动加载所需二进制             │                            │
│  └─────────────────────────────────┘                            │
└─────────────────────────────────────────────────────────────────┘
```

### 1.2 关键设计原则

| 原则 | 说明 |
|------|------|
| **数据库独立部署** | MySQL/Redis/Kafka/NebulaGraph/Doris/ES **不部署在 K8s 集群内**，由 `install_db.sh` 在独立服务器用 docker-compose 部署 |
| **唯一例外：Kuboard** | Kuboard 自带的 mariadb 跑在 K8s 节点上（容器内），不依赖外部数据库 |
| **K8s 组件在 K8s 内** | etcd / calico / metrics-server / ingress-nginx / prometheus 等 K8s 组件都跑在 K8s 内 |
| **image-cri-shim** | 在 K8s 节点上运行，把 Pod YAML 中的外部 registry 镜像引用自动重写到本地 sealos.hub:5000 |

### 1.3 四个独立离线包

| 包名 | tar.gz 命名 | 大小（ARM64） | 大小（AMD64） | 是否必需 |
|------|------------|--------------|--------------|----------|
| K8s | `k8s-offline-openEuler-{aarch64\|x86_64}-*.tar.gz` | ~1.9G | ~1.3G | 视需求 |
| Docker | `offline-docker-{aarch64\|x86_64}-*.tar.gz` | ~112M | ~85M | 数据库/容器主机必需 |
| Database | `offline-database-{aarch64\|x86_64}-*.tar.gz` | ~1.1G | ~1.9G | 视需求 |
| Kuboard | **已整合到 K8s 包** | - | - | 包含在 K8s 中 |

---

## 2. 环境准备

### 2.1 硬件最低要求

| 角色 | CPU | 内存 | 磁盘 | 网络 |
|------|-----|------|------|------|
| K8s master | 4 核 | 8G | 50G | 1 Gbps |
| K8s worker | 4 核 | 8G | 50G | 1 Gbps |
| 数据库服务器 | 8 核 | 16G | 200G+ (依数据量) | 1 Gbps |

### 2.2 系统要求

```bash
# 确认架构
uname -m
# arm64 (aarch64) 或 x86_64

# 确认系统版本
cat /etc/os-release | grep -E "NAME|VERSION"
# 期望: openEuler 22.03

# 必须 root
whoami
# root
```

### 2.3 离线包传输

将对应架构的 tar.gz 上传到目标服务器的 `/opt/install/` 目录：

```bash
# 创建安装目录
mkdir -p /opt/install
cd /opt/install

# 上传离线包（以 K8s 包为例）
# 使用 scp / rsync / U盘 等任意方式
scp k8s-offline-openEuler-aarch64-20260704215338.tar.gz root@<target>:/opt/install/
```

### 2.4 验证 tar.gz 完整性

```bash
cd /opt/install

# 下载时附带的 .sha256 文件
sha256sum -c k8s-offline-openEuler-aarch64-20260704215338.tar.gz.sha256
# 期望输出: k8s-offline-openEuler-aarch64-20260704215338.tar.gz: OK
```

---

## 3. 离线包选择

按你的部署需求选择：

| 场景 | 需要的包 | 服务器数量 |
|------|---------|-----------|
| 纯 K8s 集群（应用内置数据库） | K8s | 1 台 (单节点) 或 1 master + N workers |
| K8s + 业务数据库 | K8s + Docker + Database | 1 master (K8s) + 1 (数据库) 或更多 |
| 仅运行数据库 | Docker + Database | 1 台 |
| 多节点 K8s + 数据库 | K8s (master+workers) + Docker + Database | master+workers+db server |

**典型生产部署**：
- 1 台 K8s master 节点
- N 台 K8s worker 节点
- 1 台数据库服务器（独立）

---

## 4. K8s 集群部署

### 4.1 一键安装

```bash
cd /opt/install

# 解压 K8s 离线包
tar xzf k8s-offline-openEuler-aarch64-20260704215338.tar.gz

# 进入解压目录
cd k8s-offline-openEuler-aarch64

# 一键安装（自动确认所有提示）
ASSUME_YES=true bash install_offline.sh -y
```

**安装过程**（约 10-15 分钟）：
1. 系统初始化（关闭 swap、内核模块、sysctl）
2. 安装 RPM 依赖
3. 安装 sealos / helm / containerd
4. sealos run 启动 K8s 集群
5. 加载 21 个应用镜像到 containerd
6. 部署 ingress-nginx / metrics-server / prometheus / NFS / Kuboard

### 4.2 验证安装

```bash
# 1. 节点状态
kubectl get nodes -o wide
# NAME             STATUS   ROLES           AGE   VERSION
# renzixing-test   Ready    control-plane   5m    v1.33.6

# 2. 所有 pod 状态
kubectl get pods -A
# 期望: 31 个 pod 全部 Running

# 3. Kuboard 访问
curl -sf -m 5 http://192.168.2.39:30080/ -o /dev/null && echo "Kuboard OK"
# 注: IP 替换为你 master 节点的实际 IP

# 4. StorageClass 可用
kubectl get storageclass
# 期望: nfs-client (default)

# 5. Ingress Class
kubectl get ingressclass
# 期望: nginx

# 6. 镜像重写（image-cri-shim）
systemctl is-active image-cri-shim
# 期望: active
```

### 4.3 测试一个 pod

```bash
# 创建一个测试 nginx pod
kubectl run test-nginx --image=nginx:1.27 --port=80

# 查看是否启动成功
kubectl get pod test-nginx -w

# 测试 ServiceAccount/网络/镜像拉取完整链路
```

---

## 5. Worker 节点加入（可选）

如果你需要多节点 K8s 集群，**与 master 安装一致使用 sealos**。`add_worker.sh` 在 master 节点上执行，通过 SSH 远程部署 worker。

### 5.1 准备 SSH 免密登录

sealos add 通过 SSH 登录 worker 节点。**在 master 节点**上执行：

```bash
# 1. 确保 master 节点已生成 SSH 密钥
ls /root/.ssh/id_rsa

# 2. 将 master 的公钥复制到所有 worker 节点
ssh-copy-id root@<worker-ip>
# 默认密码需要运维提供
```

### 5.2 在 master 节点执行 add_worker.sh

```bash
# 在 K8s master 节点执行
cd /opt/install/k8s-offline-openEuler-aarch64/scripts

# 1. 添加单个 worker (默认 SSH 密钥登录)
sudo bash add_worker.sh --nodes 192.168.1.101

# 2. 添加多个 worker (逗号分隔)
sudo bash add_worker.sh --nodes 192.168.1.101,192.168.1.102

# 3. IP 范围
sudo bash add_worker.sh --nodes 192.168.1.100-192.168.1.110

# 4. 自定义 SSH 用户和密码
sudo bash add_worker.sh --nodes 192.168.1.101 --user admin --passwd xxx

# 5. 同时添加 master + worker (高可用)
sudo bash add_worker.sh --masters 192.168.1.11 --nodes 192.168.1.101

# 6. 自动确认 (跳过交互)
sudo bash add_worker.sh -y --nodes 192.168.1.101
```

**sealos add 会自动**：
- SSH 到 worker 节点
- 安装 containerd / calico-host / kubelet / kube-proxy 等所有 K8s 组件
- 加入集群并保持与 master 相同的 K8s 版本

**注意**：
- 脚本**只在 master 节点**运行，**不在 worker 上运行**
- worker 节点无需任何准备（sealos 会自动部署）
- 端口 22 (SSH) 必须在 worker 节点开放
- master 与 worker 之间网络必须互通（推荐 1Gbps）

---

## 6. Docker 部署

> **重要**：如果当前服务器是 K8s 节点（kubelet 在运行），**不要部署 Docker**。Docker 会和 K8s 共享的 containerd 冲突。
>
> Docker 应部署在**独立的数据库服务器**上。

### 6.1 一键安装

```bash
cd /opt/install

# 解压 Docker 离线包
tar xzf offline-docker-aarch64-*.tar.gz
cd offline-docker-aarch64

# 一键安装
bash install_docker_offline.sh
```

**自动行为**：
- 检测 K8s 节点 → 跳过 containerd 冲突部分
- 安装 Docker 29.6.0 + Docker Compose v2.36.1 + Buildx v0.25.0
- 配置 daemon.json（cgroupdriver=systemd、日志轮转、iptables）
- 加载 br_netfilter 内核模块
- 启动 dockerd 并设置开机自启

### 6.2 验证

```bash
# 1. Docker 版本
docker version
# 期望: Server Version: 29.6.0

# 2. docker-compose 可用
docker compose version
# 期望: Docker Compose version v2.36.1

# 3. 测试运行
docker run --rm hello-world
# 期望: "Hello from Docker!"

# 4. daemon 状态
systemctl status docker
# 期望: active (running)
```

---

## 7. 业务数据库部署

> **必须先安装 Docker**（第 6 节）

### 7.1 一键部署（默认配置）

```bash
cd /opt/install

# 解压 Database 离线包
tar xzf offline-database-aarch64-*.tar.gz
cd offline-database-aarch64

# 部署所有 enabled=true 的服务（按 config/database-package.conf）
bash scripts/install_db.sh
```

**默认启用**：
- MySQL 8.4 (端口 3306)
- Redis 8.8 (端口 6379)
- Kafka 4.0.2 (KRaft 模式)
- NebulaGraph 3.8.0 (graphd/storaged/metad/console)
- Kafka UI (端口 8080)

### 7.2 选择性部署

```bash
# 仅部署 MySQL + Redis
bash scripts/install_db.sh mysql redis

# 用 binary 模式部署 Doris
bash scripts/install_db.sh --mode binary doris

# 仅启动已部署的服务（不加载镜像）
bash scripts/install_db.sh --start-only

# 查看运行状态
bash scripts/install_db.sh --status
```

### 7.3 自定义密码

编辑 `config/database-package.conf`：

```bash
# MySQL
MYSQL_ROOT_PASSWORD=YourStrongRootPass123
MYSQL_PASSWORD=YourAppPassword456

# Redis
REDIS_PASSWORD=YourRedisPass789
```

### 7.4 验证

```bash
# 1. 容器运行状态
docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}"
# 期望: mysql84 / redis / kafka / nebula-* 全部 Up

# 2. MySQL 连接
docker exec mysql84 mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT VERSION();"

# 3. Redis
docker exec redis redis-cli -a "$REDIS_PASSWORD" PING
# 期望: PONG

# 4. 数据持久化路径
ls /data/mysql/data /data/redis/data
# 期望: 数据库文件存在
```

### 7.5 密码保存位置

```bash
# 安装完成后，密码保存在
cat /data/mysql/.password
cat /data/redis/.password
cat /data/kafka/.password
cat /data/nebula/.password
# 建议下载到本地保管后从服务器删除
```

---

## 8. 部署验证清单

完成所有安装后，逐项验证：

### 8.1 K8s 集群验证

```bash
# 节点
kubectl get nodes -o wide                          # 期望: Ready

# Pods
kubectl get pods -A                                # 期望: 31 个全 Running

# StorageClass
kubectl get sc                                     # 期望: nfs-client (default)

# IngressClass
kubectl get ingressclass                           # 期望: nginx

# Kuboard
curl -sf -m 5 http://<master-ip>:30080/ -o /dev/null && echo "Kuboard OK"

# image-cri-shim
systemctl is-active image-cri-shim                 # 期望: active

# sealos.hub registry
curl -sf -m 5 -u admin:passw0rd http://sealos.hub:5000/v2/_catalog | head -1
# 期望: {"repositories":[...]}
```

### 8.2 Docker 验证

```bash
docker version                                     # 期望: Server 29.6.0
docker compose version                             # 期望: v2.36.1
systemctl is-active docker                         # 期望: active
docker run --rm hello-world                        # 期望: Hello from Docker!
```

### 8.3 数据库验证

```bash
docker ps                                          # 期望: 所有 DB 容器 Up
docker exec mysql84 mysql -uroot -p<pass> -e "SELECT 1;"
docker exec redis redis-cli -a <pass> PING          # 期望: PONG
ls /data/mysql/data /data/redis/data               # 期望: 持久化文件
```

---

## 9. 常见问题排查

### 9.1 K8s 安装失败：sealos run 报 "docker already exist"

**原因**：目标服务器之前装过 Docker，残留的 docker 二进制在 PATH 中，sealos run 会拒绝。

**解决**：
```bash
# 手动清理 docker 二进制
rm -f /usr/local/bin/docker /usr/local/bin/dockerd
rm -f /usr/bin/docker /usr/bin/dockerd
rm -f /usr/local/bin/docker-compose /usr/bin/docker-compose
rm -rf /var/lib/docker /etc/docker

# 重新执行 install_offline.sh
bash install_offline.sh -y
```

### 9.2 K8s pod 一直 ErrImagePull / ImagePullBackOff

**原因**：image-cri-shim 未运行，或 sealos.hub:5000 没有该镜像。

**排查**：
```bash
# 1. 检查 image-cri-shim
systemctl status image-cri-shim
# 若 inactive: systemctl start image-cri-shim

# 2. 检查 registry
curl -sf -m 5 -u admin:passw0rd http://sealos.hub:5000/v2/_catalog

# 3. 看 pod 详情
kubectl describe pod <pod-name> -n <namespace>

# 4. 手动加载缺失镜像
ctr --address=/run/containerd/containerd.sock -n k8s.io images import /opt/install/k8s-offline-openEuler-aarch64/images/arm64/<image>.tar
ctr --address=/run/containerd/containerd.sock -n k8s.io images push \
    --local --plain-http --user admin:passw0rd \
    sealos.hub:5000/<repo>/<image>:<tag> <original-image>
```

### 9.3 Pod 一直 ContainerCreating

**排查**：
```bash
# 1. 看 pod 事件
kubectl describe pod <pod-name> -n <namespace>

# 2. 检查 NFS 服务（在 K8s 节点上）
systemctl status nfs-server
# 若失败: systemctl restart nfs-server

# 3. 检查 PV 是否 Bound
kubectl get pv
```

### 9.4 数据库部署失败：docker not found

**原因**：未安装 Docker。

**解决**：先按第 6 节安装 Docker。

### 9.5 数据库部署失败：端口被占用

```bash
# 查看占用端口的进程
ss -tlnp | grep -E "3306|6379|9092"

# 停止冲突服务（或修改 compose/ 下的端口映射）
```

### 9.6 安装 Kuboard 访问不了

```bash
# 1. 检查 pod 状态
kubectl get pods -n kuboard

# 2. 检查 NodePort
kubectl get svc -n kuboard
# 期望: kuboard NodePort 30080

# 3. 检查防火墙
# openEuler 默认开启 firewalld
firewall-cmd --add-port=30080/tcp --permanent
firewall-cmd --reload

# 4. 访问 http://<master-ip>:30080
# 默认账户: admin / Kuboard123
```

---

## 10. 卸载与清理

### 10.1 卸载 K8s 集群

```bash
# 在 K8s master 节点执行
bash /opt/install/k8s-offline-openEuler-aarch64/scripts/cleanup_test_cluster.sh

# 自动确认清理
ASSUME_YES=true bash /opt/install/k8s-offline-openEuler-aarch64/scripts/cleanup_test_cluster.sh
```

**清理范围**：
- K8s 集群（sealos reset）
- containerd / docker 二进制
- 所有应用命名空间资源
- /var/lib/sealos / /etc/rancher / /var/lib/kubelet 等

### 10.2 卸载业务数据库

```bash
# 停止并删除所有数据库容器
cd /opt/install/offline-database-aarch64

docker compose -f compose/mysql/docker-compose.yml down
docker compose -f compose/redis/docker-compose.yml down
docker compose -f compose/kafka/docker-compose.yml down
docker compose -f compose/nebulagraph/docker-compose.yml down

# 删除数据（**危险**，不可恢复）
rm -rf /data/mysql /data/redis /data/kafka /data/nebula
```

### 10.3 完全清理（恢复出厂）

```bash
# K8s
ASSUME_YES=true bash /opt/install/k8s-offline-openEuler-aarch64/scripts/cleanup_test_cluster.sh

# Docker
systemctl stop docker
/usr/bin/rm -rf /var/lib/docker /etc/docker
/usr/bin/rm -f /usr/local/bin/docker* /usr/bin/docker*

# 业务数据库
rm -rf /data/mysql /data/redis /data/kafka /data/nebula
for c in $(docker ps -aq 2>/dev/null); do docker rm -f $c; done

# 安装目录
rm -rf /opt/install
```

---

## 附录 A：关键文件路径

| 文件 | 用途 |
|------|------|
| `/opt/install/arch.env` | 全局架构配置（ARCH=arm64\|amd64） |
| `/opt/install/k8s-offline-openEuler-aarch64/install_offline.sh` | K8s 一键安装 |
| `/opt/install/k8s-offline-openEuler-aarch64/scripts/add_worker.sh` | 在 master 上添加 worker 节点 (sealos add) |
| `/opt/install/k8s-offline-openEuler-aarch64/scripts/cleanup_test_cluster.sh` | K8s 清理 |
| `/opt/install/offline-docker-aarch64/install_docker_offline.sh` | Docker 安装 |
| `/opt/install/offline-database-aarch64/scripts/install_db.sh` | 数据库部署入口 |
| `/opt/install/offline-database-aarch64/config/database-package.conf` | 数据库服务配置 |
| `/opt/install/offline-database-aarch64/compose/` | docker-compose 文件 |

## 附录 B：端口清单

| 服务 | 端口 | 协议 |
|------|------|------|
| K8s API Server | 6443 | TCP |
| Kuboard | 30080 | TCP (NodePort) |
| ingress-nginx | 80, 443 | TCP (NodePort) |
| Prometheus | 9090 | HTTP (ClusterIP) |
| Grafana | 3000 | HTTP (ClusterIP) |
| Alertmanager | 9093 | HTTP (ClusterIP) |
| MySQL | 3306 | TCP |
| Redis | 6379 | TCP |
| Kafka | 9092 | TCP |
| Kafka UI | 8080 | HTTP |
| NebulaGraph | 9669, 19669, 19670 | TCP |
| NFS | 2049, 111 | TCP/UDP |
| sealos.hub registry | 5000 | HTTP (plain) |
| image-cri-shim | 50050 | gRPC |

## 附录 C：默认账号密码

| 服务 | 用户名 | 默认密码 | 备注 |
|------|--------|---------|------|
| Kuboard | admin | Kuboard123 | 首次登录后必须改 |
| MySQL | root | ChangeMe_123456 | 在 .password 文件中也存 |
| MySQL | app | ChangeMe_123456 | 业务用户 |
| Redis | - | ChangeMe_123456 | requirepass |
| Grafana | admin | admin | 首次登录后必须改 |

**生产环境必须修改所有默认密码**。

---

## 附录 D：版本信息

| 组件 | 版本 |
|------|------|
| Kubernetes | v1.33.6 |
| Calico | v3.28.1 |
| Sealos | v5.1.1 |
| image-cri-shim | latest (v0.5+) |
| ingress-nginx | controller-v1.15.1 |
| kube-prometheus-stack | latest |
| metrics-server | v0.7.1 |
| Kuboard | v4 |
| Docker Engine | 29.6.0 |
| Docker Compose | v2.36.1 |
| Docker Buildx | v0.25.0 |
| MySQL | 8.4 |
| Redis | 8.8 |
| Kafka | 4.0.2 (KRaft) |
| NebulaGraph | 3.8.0 |
| Doris | 2.1.11 |
| Elasticsearch | 7.17.29 |
| JDK | 8u412+ (third-party) |

---

**文档结束。如有问题请查阅 `/opt/install/README.md` 和 `/opt/install/OFFLINE_DEPLOYMENT_HANDOVER.md`。**
