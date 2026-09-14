# 离线部署包

面向 ARM64/amd64 内网服务器的完整离线部署方案。目标服务器无法访问外网，上传离线包后即可完成部署。

## 架构与前提

- **支持架构**：ARM64 (aarch64) / AMD64 (x86_64)
- **架构切换**：编辑 `/opt/install/arch.env` 中的 `ARCH=arm64` 或 `ARCH=amd64`
- **目标系统**：openEuler 22.03（兼容同类 RPM 系 Linux）
- **权限要求**：所有安装脚本均需 **root** 执行
- **前提条件**：已上传对应 `.tar.gz` 离线包到目标服务器

## 四个独立离线包

四个包**完全独立**，互不依赖，可按需选择安装：

| 包名 | 目录 | 内容 | 安装顺序 |
|------|------|------|----------|
| K8s | `offline-k8s` | Kubernetes v1.33.6 + Calico + ingress-nginx + Prometheus + metrics-server + NFS StorageClass | 1（如需 K8s） |
| Docker | `offline-docker` | Docker Engine 29.6.0 + Docker Compose v2.36.1 + Docker Buildx v0.25.0 | 2（如需运行容器/数据库） |
| Database | `offline-database` | MySQL 8.4 + Redis 8.8 + NebulaGraph 3.8.0 + Kafka 4.0.2 (KRaft) + Kafka UI，含一键部署脚本 | 3（依赖 Docker） |
| Kuboard *已整合* | `offline-k8s` (内置) | Kuboard v4 + 专用 MariaDB 11.3.2，集群内置部署 | 内置在 K8s 安装中（无需 Docker） |

### 交付文件说明

每个包的最终交付物在**全局 bundle 目录** `/opt/install/bundle/{arch}/{type}/` 下：

```
/opt/install/bundle/
├── arm64/                       # ARM64 离线包
│   ├── apps/                    # 业务应用镜像包
│   ├── database/                # 数据库/中间件包
│   ├── docker/                  # Docker 离线包
│   └── k8s/                     # K8s 离线包
└── amd64/                       # AMD64 离线包
    ├── database/
    ├── docker/
    └── k8s/
```

传输到目标服务器时，**只需传 tar.gz 文件**，不需要传整个项目目录。

| 包名 | tar.gz 文件 | 大小（ARM64 / AMD64） |
|------|------------|-----------------|
| K8s | `k8s-offline-openEuler-{aarch64\|x86_64}-*.tar.gz` | ~1.9G / ~1.3G |
| Docker | `offline-docker-{aarch64\|x86_64}-*.tar.gz` | ~112M / ~85M |
| Database | `offline-database-{aarch64\|x86_64}-*.tar.gz` | ~1.1G / ~1.9G |
| Apps | `offline-app-images-{aarch64\|x86_64}-*.tar.gz` | ~1.5G / - |
| Kuboard | *已整合到 K8s 包中* | - |

```bash
# 目标服务器上只需执行：
tar -xzf <包名>-*.tar.gz
cd <解压目录>/
./install_offline.sh        # K8s 包
./scripts/install_*.sh      # 其他包
```

> **注意**：K8s 集群自带 containerd 运行时，与 Docker 互不冲突，可共存在同一服务器。

---

## 一、K8s 离线包安装

### 功能

- Kubernetes v1.33.6 单节点集群
- Calico v3.28.1 网络插件
- ingress-nginx（hostNetwork 模式，直接监听宿主机 80/443）
- kube-prometheus 监控套件（Prometheus + Grafana + AlertManager）
- metrics-server（`kubectl top` 可用）
- NFS StorageClass（数据目录 `/data/nfs`）

### 安装步骤

```bash
# 1. 解压离线包
tar -xzf k8s-offline-openEuler-aarch64-*.tar.gz
cd k8s-offline-openEuler-aarch64

# 2. 执行安装（交互式，会确认 hostname 和 IP）
./scripts/install_offline.sh

# 如需指定 Master IP（多网卡场景）：
# MASTER_IP=192.168.1.100 ./scripts/install_offline.sh
```

### 安装前确认事项

安装脚本会交互确认以下信息：

- 当前 **hostname**（K8s 节点名来自 hostname，安装后不建议修改）
- 自动检测的 **Master IP**（多网卡时可选）
- 系统版本和架构

### 验证

```bash
kubectl get nodes                          # 节点 Ready
kubectl get pods -A                        # 所有 Pod Running
kubectl top nodes                          # CPU/MEM 监控
kubectl get storageclass                   # nfs-client 存在
ss -tlnp | grep -E ':(80|443) '            # ingress 监听 80/443
```

### 清理集群

```bash
# 交互确认后清理（会提示输入 yes）
./scripts/cleanup_test_cluster.sh

# 跳过确认（自动化场景）
ASSUME_YES=true ./scripts/cleanup_test_cluster.sh
```

---

## 二、Docker 离线包安装

### 功能

- Docker Engine 29.6.0（静态二进制，不依赖 yum）
- Docker Compose v2.36.1（CLI 插件模式）
- Docker Buildx v0.25.0（CLI 插件，支持 BuildKit 镜像构建）
- systemd service 管理
- daemon.json 日志轮转：`100m` / `10` 文件
- K8s 节点自动检测：跳过 containerd 安装，避免版本冲突

### Docker 与 containerd 的关系

```
┌─────────────────────────────────────────────┐
│         /usr/bin/containerd (v1.7.29)       │  ← K8s (sealos) 安装
│            containerd.service               │
│                                             │
│  ┌───────────────┐  ┌───────────────────┐  │
│  │  namespace:   │  │   namespace:      │  │
│  │    k8s.io    │  │      moby         │  │
│  │               │  │                   │  │
│  │  K8s Pods     │  │  Docker Compose   │  │
│  │  (kubelet)    │  │   (dockerd)       │  │
│  └───────────────┘  └───────────────────┘  │
└─────────────────────────────────────────────┘
        ↑ CRI                      ↑ Docker API
        │                          │
   ┌────┴─────┐              ┌────┴─────┐
   │ kubelet  │              │ dockerd  │
   └──────────┘              └──────────┘
```

Docker 和 K8s **可以共存**，它们共享同一个 containerd 实例：
- **kubelet** 通过 CRI 接口连接 containerd，在 `k8s.io` namespace 下管理 Pod
- **dockerd** 通过 Docker API 连接同一个 containerd，在 `moby` namespace 下管理容器
- 两个 namespace 隔离，互不干扰

**版本冲突风险**：Docker 29.6.0 tgz 包含 containerd v2.2.4，而 K8s (sealos) 使用 containerd v1.7.29。如果 Docker 安装脚本将 v2.2.4 的 containerd/shim 覆盖到 `/usr/local/bin/`，会导致 v1.7.29 的 containerd 加载到 v2.2.4 的 shim，报错 `unsupported shim version (3)`。

**安装脚本的解决方案**：检测 kubelet 是否运行，若运行则跳过 `containerd`、`containerd-shim*`、`ctr`、`runc` 的安装，只安装 `docker`、`dockerd`、`docker-proxy`、`docker-init`。

### 安装步骤

```bash
# 1. 解压离线包
tar -xzf offline-docker-aarch64-*.tar.gz
cd offline-docker-aarch64

# 2. 执行安装
./scripts/install_docker_offline.sh
```

### 验证

```bash
docker version                             # Client + Server 正常
docker compose version                     # Compose v2 可用
docker buildx version                      # Buildx 可用
systemctl is-active docker                 # active
cat /etc/docker/daemon.json                # 日志配置 100m/10
docker info | grep "containerd version"    # 确认 containerd 版本
```

### daemon.json 配置

```json
{
  "data-root": "/var/lib/docker",
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "10"
  }
}
```

> 如需将 data-root 改为独立数据盘（如 `/data/docker`），安装前修改 `scripts/install_docker_offline.sh` 中的 daemon.json 配置。

---

## 三、Database 离线包安装

### 功能

| 组件 | 版本 | 端口 | 容器名 | 数据目录 |
|------|------|------|--------|----------|
| MySQL | 8.4 | 3306 | `mysql84` | `/data/mysql` |
| Redis | 8.8 | 6379 | `redis` | `/data/redis` |
| Kafka (KRaft) | 4.0.2 | 9092 | `kafka` | `/data/kafka` |
| Kafka UI | latest | 9090 | `kafka-ui` | - |
| NebulaGraph metad | 3.8.0 | 9559 | `nebula-metad` | `/data/nebulagraph/metad` |
| NebulaGraph storaged | 3.8.0 | 9779 | `nebula-storaged` | `/data/nebulagraph/storaged` |
| NebulaGraph graphd | 3.8.0 | 9669 | `nebula-graphd` | `/data/nebulagraph/graphd` |

> NebulaGraph 还包含一个 one-shot 容器 `nebula-storage-activator`（`nebula-console` 镜像），用于首次启动时自动注册 storage 节点，执行完毕后正常退出（Exited (0)）。

### 前置条件

- 已安装 Docker 离线包（Database 通过 Docker Compose 运行）
- 脚本以 **root** 执行

### 一键安装（推荐）

```bash
# 1. 解压离线包
tar -xzf offline-database-aarch64-*.tar.gz
cd offline-database-aarch64

# 2. 一键部署全部服务（自动加载镜像 + 启动 + 健康检查）
./scripts/install_db.sh

# 3. 部署完成后查看连接信息（含密码、JDBC/Redis/Nebula 连接串）
cat .password
```

`install_db.sh` 是统一入口，内置镜像加载、权限修复、服务启动、健康检查全流程。

### 按需部署

```bash
# 仅部署指定服务（镜像已加载或自动加载）
./scripts/install_db.sh mysql redis
./scripts/install_db.sh kafka
./scripts/install_db.sh nebulagraph

# 仅启动服务，跳过镜像加载（镜像已导入）
./scripts/install_db.sh --start-only mysql redis kafka nebulagraph

# 部署全部
./scripts/install_db.sh all

# 查看运行状态
./scripts/install_db.sh --status
```

### 脚本设计说明

| 设计点 | 说明 |
|--------|------|
| **容错不中断** | 单个服务 unhealthy 不会导致脚本退出，其他服务继续部署 |
| **权限自动修复** | Kafka 目录自动设为 `1000:1000`（appuser），MySQL/Redis 设为 `999:999`，NebulaGraph 预建子目录 |
| **健康检查** | 使用 `docker inspect` 查询容器真实状态，兼容 one-shot 服务（storage-activator 退出码 0 视为成功） |
| **启动重试** | 每个服务 `compose up -d` 失败自动重试 3 次，间隔 5 秒 |
| **后台并行等待** | 各服务健康检查在后台并行执行，不阻塞后续服务启动 |

### 验证

```bash
# 查看所有数据库容器状态
./scripts/install_db.sh --status

# 或手动查看
docker ps -a --format "table {{.Names}}\t{{.Status}}" | grep -iE "mysql|redis|kafka|nebula"

# MySQL
docker exec -it mysql84 mysql -uroot -p<密码> -e "SELECT VERSION();"

# Redis
docker exec -it redis redis-cli -a <密码> ping

# Kafka
docker exec -it kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list

# Kafka UI
curl http://127.0.0.1:9090/actuator/health    # 应返回 {"status":"UP"}

# NebulaGraph
docker exec -it nebula-graphd nebula -addr=127.0.0.1 -port=9669 -u root -p nebula -e 'SHOW HOSTS;'
```

### 密码说明

安装时自动为 MySQL 和 Redis 生成随机密码（20 位，首尾字母数字，无 `@` `:` 等特殊字符），存储在：

```bash
# 部署完成后查看密码
cat /opt/install/offline-database/.password
```

示例输出：

```bash
# ----- MySQL -----
MYSQL_HOST=192.168.2.39
MYSQL_PORT=3306
MYSQL_DATABASE=app
MYSQL_USER=app
MYSQL_PASSWORD=9DGp6tUrbkco1z-fZ7Ld
MYSQL_ROOT_PASSWORD=25tBsGzGXM3p0nL1yWXi
MYSQL_JDBC_URL=jdbc:mysql://192.168.2.39:3306/app?useSSL=false&...

# ----- Redis -----
REDIS_HOST=192.168.2.39
REDIS_PORT=6379
REDIS_PASSWORD=7c4o7Kv_4DWsR_nzo5rD
REDIS_URL=redis://:7c4o7Kv_4DWsR_nzo5rD@192.168.2.39:6379/0

# ----- Kafka (无认证) -----
KAFKA_BOOTSTRAP_SERVERS=192.168.2.39:9092
KAFKA_UI_URL=http://192.168.2.39:8080

# ----- NebulaGraph (默认密码) -----
NEBULA_USER=root
NEBULA_PASSWORD=nebula
NEBULA_CONNECTION=graphd://root:nebula@192.168.2.39:9669
```

> 如需要自定义密码，部署前在 `compose/<服务>/docker-compose.yml` 中修改对应环境变量，或部署后在 `/data/<服务>/docker-compose.yml` 中修改并 `docker compose up -d` 重启。

### NebulaGraph 说明

**单机版**（`nebulagraph`）：开箱即用，`storage-activator` 容器会在首次启动时自动执行 `ADD HOSTS` 注册 storage 节点，无需手动操作。

**集群版**（`nebulagraph-cluster`）：使用 host 网络模式，需配置环境变量：

```bash
# 需要每台机器配置 LOCAL_IP 和 METAD_ADDRS
LOCAL_IP=192.168.2.39 METAD_ADDRS=192.168.2.39:9559 ./scripts/install_db.sh nebulagraph-cluster

# 或手动配置
cd /data/nebulagraph
cp .env.example .env
# 编辑 .env 填入 LOCAL_IP 和 METAD_ADDRS
docker compose up -d
```

### 权限说明

部署脚本会自动为各服务设置正确的目录权限，无需手动处理：

| 服务 | 容器用户 | UID:GID | 数据目录 |
|------|----------|---------|----------|
| Kafka | appuser | 1000:1000 | `/data/kafka` |
| MySQL | mysql | 999:999 | `/data/mysql/data` |
| Redis | redis | 999:999 | `/data/redis/data` |
| NebulaGraph | root | 0:0 | `/data/nebulagraph/*` |

> **常见问题**：Kafka 目录在 openEuler 上 `ls -la` 显示为 `es:es`，这是因为 UID 1000 对应宿主机的 `es` 用户。容器内 appuser 也是 UID 1000，权限匹配，不影响运行。

### 目录结构

部署后的目录结构：

```
/data/
├── mysql/
│   ├── docker-compose.yml      # 从 compose/ 复制
│   ├── data/                   # MySQL 数据 (owner: 999)
│   ├── conf/                   # MySQL 配置
│   └── logs/                   # MySQL 日志
├── redis/
│   ├── docker-compose.yml
│   └── data/                   # Redis AOF 数据 (owner: 999)
├── kafka/
│   ├── docker-compose.yml
│   ├── data/                   # Kafka 日志段 (owner: 1000)
│   └── logs/                   # Kafka 进程日志 (owner: 1000)
└── nebulagraph/
    ├── docker-compose.yml
    ├── .env                    # 仅集群版生成
    ├── .env.example
    ├── metad/{data,logs}/      # 元数据
    ├── storaged/{data,logs}/   # 存储数据
    └── graphd/{data,logs}/     # 图引擎日志
```

### 第三方组件占位

`third-party/` 目录包含以下占位目录，放入对应 tar 包后执行安装脚本即可部署：

| 目录 | 安装脚本 |
|------|----------|
| `nebula-graph/` | `scripts/install_nebula_third_party.sh` |
| `nebula-dashboard/` | `scripts/install_nebula_third_party.sh` |
| `nebula-studio/` | `scripts/install_nebula_third_party.sh` |
| `doris/` | `scripts/install_third_party_placeholders.sh` |
| `elasticsearch/` | `scripts/install_third_party_placeholders.sh` |
| `jdk/` | `scripts/install_third_party_placeholders.sh` |

### 故障排查

```bash
# 查看某个服务的日志
cd /data/<服务名> && docker compose logs --tail=50

# 重启某个服务
cd /data/<服务名> && docker compose restart

# 完全清理某个服务后重新部署
cd /data/<服务名> && docker compose down -v
rm -rf /data/<服务名>
./scripts/install_db.sh --start-only <服务名>

# Kafka 权限问题（极少出现，脚本已自动处理）
chown -R 1000:1000 /data/kafka
cd /data/kafka && docker compose restart
```

---

## 四、Kuboard v4（集群内置部署）

Kuboard v4 已整合到 K8s 安装流程中，作为集群内置组件部署（NodePort 30080），不再需要独立的 Docker 环境。

### 功能

- Kuboard v4 管理面板（NodePort 30080 → 80）
- 专用 MariaDB 11.3.2 数据库（不与其他数据库冲突）
- NFS 持久化存储（PVC 10Gi，使用 nfs-client StorageClass）
- 安装时自动生成 K8s 导入 Token

### 安装方式

Kuboard v4 由 `install_offline.sh` 自动部署：

```bash
# 解压 K8s 离线包 → 执行安装（step 16 自动部署 Kuboard）
./scripts/install_offline.sh
```

如需单独部署（集群已就绪）：

```bash
kubectl apply -f manifests/kuboard/kuboard-v4.yaml
```

### 验证

```bash
kubectl get pods -n kuboard          # kuboard + kuboard-db 均 Running
curl -s http://<服务器IP>:30080       # 返回 Kuboard 页面
```

### 访问地址

| 配置项 | 值 |
|--------|-----|
| **访问地址** | `http://<服务器IP>:30080` |
| **默认账号** | `admin` |
| **默认密码** | `Kuboard123` |

### 导入 K8s 集群

首次登录后需导入当前 K8s 集群：

```bash
# 方式一：Token（推荐）
# APIServer: https://<服务器IP>:6443
# 跳过 TLS 验证: 必须勾选
# Token: 在集群中执行以下命令生成

# 生成永久 Token
kubectl create serviceaccount kuboard-admin -n kube-system 2>/dev/null || true
kubectl create clusterrolebinding kuboard-admin --clusterrole=cluster-admin --serviceaccount=kube-system:kuboard-admin 2>/dev/null || true

cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: kuboard-admin-token
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: kuboard-admin
type: kubernetes.io/service-account-token
EOF

sleep 2
kubectl get secret kuboard-admin-token -n kube-system -o jsonpath='{.data.token}' | base64 -d
echo

# 方式二：kubeconfig
cat /root/.kube/config
# 把内容粘贴到 Kuboard 的 kubeconfig 输入框
# 注意把 server 改为 https://<服务器IP>:6443
# 添加 insecure-skip-tls-verify: true
```

---

## 访问地址汇总

| 服务 | 地址 | 说明 |
|------|------|------|
| K8s APIServer | `https://<IP>:6443` | K8s API |
| ingress-nginx HTTP | `http://<IP>:80` | Ingress 入口 |
| ingress-nginx HTTPS | `https://<IP>:443` | Ingress 入口 |
| Kuboard | `http://<IP>:30080` | K8s 管理面板（集群内置，NodePort） |
| Grafana | `http://<IP>:30030` | 监控面板（需通过 ingress 或 port-forward 访问） |
| Kafka | `<IP>:9092` | 消息队列 |
| Kafka UI | `http://<IP>:9090` | Kafka 管理面板 |
| MySQL | `<IP>:3306` | 数据库 |
| Redis | `<IP>:6379` | 缓存 |
| NebulaGraph | `<IP>:9669` | 图数据库 |

---

## 集群镜像操作

K8s 集群使用 containerd 运行时 + image-cri-shim 本地 registry（`sealos.hub:5000`），所有容器镜像统一管理。

### 镜像拉取拦截机制

```
Pod YAML 中写:   swr.cn-east-2.myhuaweicloud.com/kuboard/kuboard:v4
image-cri-shim:  拦截 → 重写为 sealos.hub:5000/kuboard/kuboard:v4
containerd:      从本地 registry 拉取
```

image-cri-shim 配置在 `/etc/image-cri-shim.yaml`，`force: true` 表示**全部镜像**走本地 registry。

### 手动上传镜像

将镜像 tar 包上传到离线服务器后，按以下步骤加载：

```bash
# 1. 导入 containerd
ctr -n k8s.io images import kuboard_v4.tar
ctr -n k8s.io images import kuboard_mariadb.tar

# 2. 推送到本地 registry（供 image-cri-shim 拦截）
#    注意 --platform linux/arm64 和多架构镜像的处理
#    registry 前缀会被剥离，只保留 repo/name:tag

ctr -n k8s.io images push --local --plain-http --user admin:passw0rd \
  --platform linux/arm64 \
  sealos.hub:5000/kuboard/kuboard:v4 \
  swr.cn-east-2.myhuaweicloud.com/kuboard/kuboard:v4

ctr -n k8s.io images push --local --plain-http --user admin:passw0rd \
  --platform linux/arm64 \
  sealos.hub:5000/kuboard/mariadb:11.3.2-jammy \
  swr.cn-east-2.myhuaweicloud.com/kuboard/mariadb:11.3.2-jammy

# 3. 验证
curl -u admin:passw0rd http://sealos.hub:5000/v2/kuboard/kuboard/tags/list
curl -u admin:passw0rd http://sealos.hub:5000/v2/kuboard/mariadb/tags/list
```

### 查看 registry 中的所有镜像

```bash
curl -sf --user admin:passw0rd http://sealos.hub:5000/v2/_catalog | python3 -m json.tool
```

输出示例：
```json
{
  "repositories": [
    "kuboard/kuboard",
    "kuboard/mariadb",
    "ingress-nginx/controller",
    "sig-storage/nfs-subdir-external-provisioner"
  ]
}
```

### 查看具体镜像的标签

```bash
curl -u admin:passw0rd http://sealos.hub:5000/v2/<镜像名>/tags/list
# 示例
curl -u admin:passw0rd http://sealos.hub:5000/v2/ingress-nginx/controller/tags/list
```

### 镜像导入流程说明

`01_download_online.sh` 的完整流程：

```
extract_image_list()   扫描 manifests/ 下所有 YAML 的 image: 字段 → images.list
save_app_images()      读取 images.list，拉取每个镜像 → images/<safe-name>.tar
```

`install_offline.sh` 的加载流程：

```
load_app_images_to_containerd()
  ├─ 遍历 images/*.tar
  ├─ 读取 tar 中的 RepoTags（原始 registry URL）
  ├─ ctr import → containerd
  ├─ 剥离 registry 前缀（如 swr.cn-east-2.myhuaweicloud.com/）
  ├─ ctr push → sealos.hub:5000/<repo/name:tag>
  └─ curl 验证 registry 中镜像存在
```

### 离线打包时添加新应用镜像

1. 将新应用的 K8s YAML 放入 `manifests/<应用名>/`
2. 重新执行 `01_download_online.sh`（会自动扫描并下载新镜像）
3. 重新打包：`bash scripts/04_export_offline_bundle.sh`
4. 传输新包到离线服务器执行 `install_offline.sh`

也可手动编辑 `config/images.list`，每行一个镜像地址，再执行下载：

```bash
# 直接追加镜像到列表
echo "registry.example.com/myapp:latest" >> config/images.list
# 重新下载镜像
bash scripts/01_download_online.sh
```

---

## 目录结构

```
/opt/install/
├── README.md                              # 本文档
├── OFFLINE_DEPLOYMENT_HANDOVER.md         # 开发交接文档
├── arch.env                               # ★ 全局架构配置 (arm64|amd64)
├── bundle/                                # ★ 全局离线包输出目录 (按架构+类型组织)
│   ├── amd64/
│   │   ├── docker/                        # Docker 离线包 (x86_64)
│   │   ├── k8s/                           # K8s 离线包 (x86_64)
│   │   └── database/                      # 数据库离线包 (x86_64)
│   └── arm64/
│       ├── docker/                        # Docker 离线包 (aarch64)
│       ├── k8s/                           # K8s 离线包 (aarch64)
│       ├── database/                      # 数据库离线包 (aarch64)
│       └── apps/                          # 业务应用离线包
├── offline-k8s/                           # K8s 离线包源码
│   ├── scripts/
│   │   ├── install_offline.sh             # 一键安装（含 Kuboard v4）
│   │   ├── cleanup_test_cluster.sh        # 集群清理
│   │   └── ...
│   ├── manifests/                         # K8s YAML 清单
│   └── pkgs/                              # RPM 依赖包
├── offline-docker/                        # Docker 离线包源码
│   ├── scripts/
│   │   ├── install_docker_offline.sh       # Docker 安装脚本（含 buildx）
│   │   └── package_docker_bundle.sh        # 打包脚本
│   ├── bin/                               # CLI 插件二进制
│   │   ├── docker-compose                 # Compose v2.36.1
│   │   └── docker-buildx                  # Buildx v0.25.0
│   └── pkgs/                              # Docker Engine 二进制
├── offline-database/                      # Database 离线包源码
│   ├── scripts/
│   │   ├── install_db.sh                 # 一键部署入口（加载镜像+启动+健康检查）
│   │   ├── load_database_images.sh        # 镜像导入（含 sha256 校验）
│   │   ├── download_database_images.sh   # 在线机器下载镜像
│   │   ├── package_database_bundle.sh     # 打包离线 bundle
│   │   └── install_*_third_party.sh       # 第三方组件占位安装
│   ├── compose/                           # Docker Compose 文件
│   │   ├── mysql/
│   │   ├── redis/
│   │   ├── kafka/
│   │   ├── nebulagraph/                   # 单机版（自动注册 storage）
│   │   └── nebulagraph-cluster/           # 集群版（host 网络，需 .env）
│   ├── images/                            # 镜像 tar 包
│   └── third-party/                       # 第三方组件占位
└── offline-apps/                          # 业务应用离线打包
    ├── apps.conf                          # namespace 列表
    └── images.conf                        # 镜像清单
```

### Bundle 输出策略
- **路径**：`bundle/{arch}/{type}/` 全局唯一
- **命名**：`{name}-{arch}-{timestamp}.tar.gz` + `.sha256`
- **清理**：每次打包前自动删除该路径下的历史版本，只保留最新
- **架构切换**：编辑 `arch.env` 中的 `ARCH=` 即可，无需手动改各子项目配置

---

## 五、业务应用离线打包与部署

用于将 K8s 集群中已运行的业务应用（指定 namespace）一键打包为离线包，传输到内网后一键部署。

### 功能

- 指定 namespace 列表，自动导出所有资源 YAML（Deployment/Service/ConfigMap/Secret/Ingress 等）
- 自动解析 YAML 中引用的容器镜像，从 containerd 导出为 tar 包
- 自动清理只读字段（uid/resourceVersion/creationTimestamp 等），确保可在新集群 apply
- 支持多 namespace 批量打包
- 部署时自动校验镜像 sha256、导入 containerd、apply YAML、验证 Pod 状态

### 打包（在已部署业务的集群上执行）

```bash
cd /opt/install/offline-apps

# 方式一：指定 namespace
NAMESPACES=app1,app2 ./scripts/export_apps.sh

# 方式二：交互式选择
./scripts/export_apps.sh
# 脚本会列出所有 namespace，输入要导出的名称
```

打包完成后生成：
```
bundle/{ARCH}/apps/offline-app-images-{arch}-<时间戳>.tar.gz
├── manifests/          # 按 namespace 分目录的 YAML
│   ├── app1/
│   │   ├── deployment_xxx.yaml
│   │   ├── service_xxx.yaml
│   │   └── ...
│   └── app2/
├── images/
│   ├── app-images.tar          # 所有镜像打包
│   └── app-images.tar.sha256   # 校验和
├── images.txt          # 镜像列表
├── VERSION.txt         # 版本信息
└── scripts/
    ├── export_apps.sh   # 导出脚本
    └── deploy_apps.sh   # 部署脚本
```

### 部署（在内网服务器执行）

```bash
# 1. 解压
tar -xzf offline-apps-*.tar.gz
cd offline-apps-*/

# 2. 一键部署（自动导入镜像 + apply YAML + 验证）
./scripts/deploy_apps.sh

# 跳过镜像导入（镜像已在 containerd 中）
SKIP_IMAGES=true ./scripts/deploy_apps.sh
```

### 导出的资源类型

| 类型 | 说明 |
|------|------|
| Deployment / StatefulSet / DaemonSet | 工作负载 |
| Service | 服务发现 |
| ConfigMap / Secret | 配置与密钥 |
| Ingress | 入口路由 |
| PersistentVolumeClaim | 持久化存储 |
| ServiceAccount / Role / RoleBinding | RBAC 权限 |
| CronJob / HorizontalPodAutoscaler | 定时任务与自动伸缩 |

> 自动跳过系统生成的资源（如 `kube-root-ca.crt`、Helm release secrets）

---

## 常见问题

### Q: Docker 和 K8s containerd 会冲突吗？

不会。Docker 使用 `/var/run/docker.sock`，K8s containerd 使用 `/run/containerd/containerd.sock`，两者完全独立。

### Q: ingress-nginx 为什么是 ClusterIP 而不是 LoadBalancer？

因为使用了 `hostNetwork: true` 模式，Pod 直接绑定宿主机 80/443 端口，不需要 Service 做转发。外部 LB 直接把流量转发到宿主机 80/443 即可。

### Q: Kuboard 导入集群报 401 Unauthorized？

必须勾选「跳过 TLS 证书验证」，因为 K8s 证书的 SAN 中只有域名没有 IP。同时确保使用 Secret 方式的永不过期 Token，而不是 `kubectl create token` 生成的临时 Token。

### Q: 安装后修改 hostname 会怎样？

K8s 节点名来自安装时的 hostname，安装后修改会导致节点名与证书/注册信息不一致。**安装前固定 hostname，安装后不要修改。** 如必须修改，建议重置集群后重装。

### Q: 多网卡如何指定 Master IP？

```bash
# 方式一：环境变量
MASTER_IP=192.168.1.100 ./scripts/install_offline.sh

# 方式二：交互选择（脚本自动列出所有非回环 IP）
./scripts/install_offline.sh
```
