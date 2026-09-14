# deploy-suite — 部署工程套件

K8s 集群部署、数据库套件、离线交付与运维工具的一站式工程仓库。

## 目录结构

| 目录 | 功能 |
|---|---|
| [k8s-online-install/](k8s-online-install/) | **K8s 在线部署**：sealos 单机集群一键部署（Ubuntu 22.04 ARM64），01-前置检查 ~ 10-prometheus 全流程脚本 + 入口 `deploy.sh` |
| [databases/](databases/) | **数据库套件**：纯 manifests 部署 MySQL / Redis / Kafka / Elasticsearch / NebulaGraph / MinIO（Doris 为宿主机 systemd），一键入口 `deploy.sh` |
| [offline-delivery/](offline-delivery/) | **离线交付**：openEuler 离线安装包（docker / k8s / dify / apps / database 五包独立互不依赖），ARM64/AMD64 双架构 |
| [k8s-optimizations/](k8s-optimizations/) | **K8s 优化配置**：ingress-nginx 生产优化、node-tuning、priority-class、优化方案文档 |
| [delivery-tools/](delivery-tools/) | **交付工具**：镜像同步华为云 SWR（`images-manager.sh`）、应用导出/加载/部署（`app-export.sh` / `app-load-images.sh` / `app-deploy.sh`） |
| [linux-ops/](linux-ops/) | **Linux 运维 CLI**：服务器初始化、巡检、监控等模块化工具（lops） |

## 快速开始

### 在线部署 K8s 集群（sealos 单机）

```bash
cd k8s-online-install
# 先按需修改 config.env（镜像源、网络、存储等参数）
sudo ./deploy.sh                # 部署全部（跳过确认）
sudo ./deploy.sh 02 03 05       # 只跑指定编号的脚本
```

### 部署数据库套件

```bash
cd databases
./deploy.sh                                  # 默认 ns 全量部署（mysql/redis/kafka/es/nebula/minio）
./deploy.sh db-lianantech-hk-poc             # 换 namespace 全量部署
./deploy.sh db-lianantech-hk-poc mysql       # 换 ns 只部署 MySQL
```

前置条件：本机 NFS 服务可用、镜像已通过 `delivery-tools/images-manager.sh` 注入本机 containerd。

### 镜像同步与应用交付

```bash
cd delivery-tools
bash images-manager.sh sync       # 海外源拉取 → 推送华为云 SWR
bash images-manager.sh load2k8s   # K8s 服务器：拉取 → 打回官方名 → 注入集群
bash app-export.sh                # 导出 namespace 应用资源 + 镜像离线包
bash app-deploy.sh                # 应用离线包部署（幂等可重跑）
```

### 离线交付（openEuler）

详见 [offline-delivery/INSTALL_GUIDE.md](offline-delivery/INSTALL_GUIDE.md)。

### Linux 运维工具

```bash
cd linux-ops
bash lops.sh init all          # 新服务器一键初始化
bash lops.sh monitor check     # 一键健康巡检
bash lops.sh help              # 总帮助
```

## 约定

- 脚本路径解析基于 `$(dirname ...)` 相对定位，目录整体迁移/重命名不影响运行
- 凭据文件不入库（`.gitignore`）：`passwords.env`、`.swr-credentials`、`grafana-admin-password.txt`，分别由 `generate-passwords.sh`、`images-manager.sh login`、prometheus 部署脚本重新生成
- 运行日志（`logs/`、`*.log`）不入库
