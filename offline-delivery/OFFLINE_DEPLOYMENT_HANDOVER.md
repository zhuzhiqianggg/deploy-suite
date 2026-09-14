# 离线部署项目开发交接上下文

> 更新时间: 2026-07-04
> 架构控制: 编辑 `/opt/install/arch.env` 中的 `ARCH=` 切换 arm64/amd64

## 1. 项目目标

为 ARM64/amd64 内网服务器准备完整离线部署包，目标服务器无法访问外网，上传离线包后即可完成部署。

当前拆成四个独立子目录，每个子目录产出独立的离线包，统一输出到全局 bundle 目录 `/opt/install/bundle/{arch}/{type}/`：

1. `offline-k8s` — Kubernetes 基础集群 + K8s 组件（含 Kuboard v4 集群内置部署）
2. `offline-docker` — Docker Engine + Docker Compose + Buildx
3. `offline-database` — MySQL、Redis、NebulaGraph、Kafka、ES、Doris、JDK
4. `offline-apps` — 业务应用镜像打包/部署工具

## 2. 全局 Bundle 目录

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

## 3. 当前已验证状态

### K8s 集群（ARM64 已验证）

- Kubernetes v1.33.6 + Calico v3.28.1 + Sealos v5.1.1
- ingress-nginx controller-v1.15.1（hostNetwork + DaemonSet + snippet annotations 已启用）
- kube-prometheus（Prometheus + Grafana + Alertmanager + node-exporter）
- metrics-server v0.7.1（`kubectl top nodes` 可用）
- NFS StorageClass（`/data/nfs`，`nfs-server` / `rpcbind` active）
- Kuboard v4 集群内置部署（NodePort 30080，不再独立打包）
- 安装脚本增强：多网卡 IP 选择、hostname/IP 交互确认、`ASSUME_YES=true` 跳过

### Docker 包（已验证）

- Docker Engine 29.6.0 + Docker Compose v2.36.1 + Docker Buildx v0.25.0
- daemon.json 日志配置：`max-size=100m`，`max-file=10`
- K8s 节点自动检测：跳过 containerd 安装，避免版本冲突
- Docker 与 K8s 共享 containerd（namespace 隔离：k8s.io / moby）

### Database 包（已验证）

- MySQL 8.4 + Redis 8.8 + NebulaGraph 3.8.0 + Kafka 4.0.2 (KRaft) + Kafka UI
- 一键部署脚本 `install_db.sh`：容错不中断、权限自动修复、健康检查、后台并行等待
- 密码自动生成（20 位随机密码，存 `.password` 文件）
- ES 7.17.29 / Doris 2.1.11 支持 docker-compose 和 binary 两种部署方式
- JDK 为 third-party 占位

### Apps 包

- 从联网 K8s 集群导出 namespace 资源 + 镜像
- 部署时按依赖顺序 apply（SA→Role→ConfigMap→Secret→PVC→Service→Deployment）

## 4. 关键文件索引

| 文件 | 说明 |
|------|------|
| `/opt/install/arch.env` | 全局架构配置（ARCH=arm64\|amd64） |
| `/opt/install/README.md` | 项目主文档（安装步骤、验证命令、目录结构） |
| `/opt/install/offline-k8s/scripts/install_offline.sh` | K8s 一键安装脚本 |
| `/opt/install/offline-k8s/scripts/01_download_online.sh` | K8s 在线下载脚本 |
| `/opt/install/offline-k8s/scripts/04_export_offline_bundle.sh` | K8s 打包脚本 |
| `/opt/install/offline-k8s/scripts/patch_ingress_manifest.py` | ingress-nginx manifest 离线定制 |
| `/opt/install/offline-k8s/scripts/cleanup_test_cluster.sh` | K8s 集群清理脚本 |
| `/opt/install/offline-k8s/STATUS.md` | K8s 包状态文档 |
| `/opt/install/offline-docker/scripts/install_docker_offline.sh` | Docker 一键安装脚本 |
| `/opt/install/offline-docker/scripts/package_docker_bundle.sh` | Docker 打包脚本 |
| `/opt/install/offline-database/scripts/install_db.sh` | 数据库一键部署入口 |
| `/opt/install/offline-database/scripts/load_database_images.sh` | 数据库镜像加载脚本 |
| `/opt/install/offline-database/scripts/package_database_bundle.sh` | 数据库打包脚本 |
| `/opt/install/offline-apps/scripts/export_apps.sh` | 业务应用导出脚本 |
| `/opt/install/offline-apps/scripts/deploy_apps.sh` | 业务应用部署脚本 |
| `/opt/install/offline-apps/scripts/pack_app_images.sh` | 业务应用打包脚本 |

## 5. 架构切换

编辑 `/opt/install/arch.env`：

```bash
# ARM64 (aarch64)
ARCH=arm64

# AMD64 (x86_64)
ARCH=amd64
```

所有打包脚本和安装脚本统一读取此文件，自动按架构分目录管理。

## 6. 关键原则

1. K8s、Docker、Database、Apps 四个包必须保持独立。
2. 全局 bundle 输出到 `/opt/install/bundle/{arch}/{type}/`，不再使用各子目录的 `bundle/`。
3. 每次打包自动清理历史版本，仅保留最新。
4. Docker 与 K8s 共享 containerd，通过 namespace 隔离（k8s.io / moby），互不冲突。
5. Kuboard v4 已整合到 K8s 安装流程中，不再独立打包。
6. 所有安装脚本优先读取 `arch.env`，而非 `versions.lock` 中的硬编码架构。
7. 跨架构镜像拉取使用 skopeo（docker:// → docker-archive），避免 docker pull+save 失败。
8. sealos cluster image 无法跨架构构建，需在同架构主机上执行下载脚本。

## 7. 新会话启动建议提示词

```text
请读取 /opt/install/README.md 和 /opt/install/OFFLINE_DEPLOYMENT_HANDOVER.md 作为上下文，
继续完善离线部署项目。

当前状态：
- 四个独立子项目（k8s/docker/database/apps），统一输出到 /opt/install/bundle/{arch}/{type}/
- 架构切换: 编辑 /opt/install/arch.env 中的 ARCH=
- ARM64 已完整验证，AMD64 包已生成但未在 x86 服务器上实际安装验证
- ingress-nginx manifest 已自动 patch（hostNetwork + DaemonSet + snippet annotations）
- 数据库支持 docker-compose 和 binary 两种部署方式
```
