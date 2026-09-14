# 离线部署包 - 最终状态

> 更新时间: 2026-07-04
> 架构控制: 编辑 `/opt/install/arch.env` 中的 `ARCH=` 切换 arm64/amd64

## 当前结论

项目拆成四个独立子目录，每个子目录产出独立的离线包，统一输出到全局 bundle 目录：

1. `offline-k8s` — Kubernetes 基础集群 + K8s 组件（含 Kuboard v4 集群内置部署）
2. `offline-docker` — Docker Engine + Docker Compose + Buildx
3. `offline-database` — MySQL、Redis、NebulaGraph、Kafka、ES、Doris、JDK
4. `offline-apps` — 业务应用镜像打包/部署工具

### 全局 Bundle 目录

```
/opt/install/bundle/{arch}/{type}/
├── arm64/
│   ├── apps/       offline-app-images-aarch64-*.tar.gz
│   ├── database/   offline-database-aarch64-*.tar.gz
│   ├── docker/     offline-docker-aarch64-*.tar.gz
│   └── k8s/        k8s-offline-openEuler-aarch64-*.tar.gz
└── amd64/
    ├── database/   offline-database-x86_64-*.tar.gz
    ├── docker/     offline-docker-x86_64-*.tar.gz
    └── k8s/        k8s-offline-openEuler-x86_64-*.tar.gz
```

每次打包自动清理该架构下该类型的历史版本，仅保留最新。

## K8s 离线包

### 已验证通过 (ARM64)

- Kubernetes: v1.33.6
- Calico: v3.28.1
- Sealos: v5.1.1
- ingress-nginx: controller-v1.15.1 (hostNetwork + DaemonSet + snippet annotations)
- kube-prometheus: Prometheus + Grafana + Alertmanager + node-exporter
- metrics-server: v0.7.1
- NFS StorageClass: `nfs-client`
- Kuboard v4: 集群内置部署 (NodePort 30080)，不再独立打包
- kubectl 自动补全
- Sealos 默认 100 年证书

### 当前实测结果

- 节点：Ready
- 异常 Pod：无
- `kubectl top nodes`：可用
- ingress-nginx：宿主机监听 80/443 (hostNetwork)
- NFS 服务：`nfs-server`、`rpcbind` active
- Kuboard v4：http://<IP>:30080 可访问

### Bundle 路径

- `bundle/arm64/k8s/k8s-offline-openEuler-aarch64-*.tar.gz` + `.sha256`
- `bundle/amd64/k8s/k8s-offline-openEuler-x86_64-*.tar.gz` + `.sha256`

### Kuboard 策略

Kuboard v4 已整合到 K8s 安装流程中，作为集群内置组件部署（NodePort 30080），不再需要独立的 Docker 环境和离线包。

## Docker 离线包

- Docker Engine 29.6.0（静态二进制，不依赖 yum）
- Docker Compose v2.36.1（CLI 插件模式）
- Docker Buildx v0.25.0（CLI 插件，支持 BuildKit）
- K8s 节点自动检测：跳过 containerd 安装，避免版本冲突

### Bundle 路径

- `bundle/arm64/docker/offline-docker-aarch64-*.tar.gz` + `.sha256`
- `bundle/amd64/docker/offline-docker-x86_64-*.tar.gz` + `.sha256`

## Database / Middleware 离线包

| 组件 | 版本 | 部署方式 |
|------|------|----------|
| MySQL | 8.4 | docker-compose |
| Redis | 8.8 | docker-compose |
| Kafka (KRaft) | 4.0.2 | docker-compose |
| Kafka UI | latest | docker-compose |
| NebulaGraph | 3.8.0 | docker-compose (metad/storaged/graphd + storage-activator) |
| Elasticsearch | 7.17.29 | docker-compose / binary |
| Doris | 2.1.11 | docker-compose / binary |
| JDK | - | binary (third-party 占位) |

### Bundle 路径

- `bundle/arm64/database/offline-database-aarch64-*.tar.gz` + `.sha256`
- `bundle/amd64/database/offline-database-x86_64-*.tar.gz` + `.sha256`

## Apps 离线包

业务应用镜像打包/部署工具，从联网 K8s 集群导出 namespace 资源 + 镜像。

### Bundle 路径

- `bundle/arm64/apps/offline-app-images-aarch64-*.tar.gz` + `.sha256`

## 目标服务器部署顺序

### 1. 安装 K8s

```bash
tar -xzf k8s-offline-openEuler-aarch64-*.tar.gz
cd k8s-offline-openEuler-aarch64
./install_offline.sh
```

### 2. 安装 Docker

```bash
tar -xzf offline-docker-aarch64-*.tar.gz
cd offline-docker-aarch64
./scripts/install_docker_offline.sh
```

### 3. 安装数据库/中间件

```bash
tar -xzf offline-database-aarch64-*.tar.gz
cd offline-database-aarch64
./scripts/install_db.sh          # 一键部署全部
# 或按需: ./scripts/install_db.sh mysql redis kafka
```

### 4. 部署业务应用（如有）

```bash
tar -xzf offline-app-images-aarch64-*.tar.gz
cd offline-app-images-aarch64
./scripts/load_app_images.sh     # 加载镜像到 containerd
./scripts/deploy_apps.sh         # 部署 K8s 资源
```
