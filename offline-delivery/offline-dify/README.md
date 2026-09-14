# offline-dify - Dify 离线一键部署包

> 适用版本：Dify 1.16.0-rc1
> 支持架构：ARM64 / AMD64
> 部署方式：docker-compose (使用 dify 项目自带的 compose 文件)
> 离线包用途：在断网环境一键部署完整 Dify

本项目通过解析 dify 项目自带的 `docker-compose.yaml`，自动识别所有需要的镜像，按架构拉取、导出、打包成离线包。**不修改 dify 项目任何文件**。

---

## 目录

1. [工作流](#1-工作流)
2. [在线机器：打包](#2-在线机器打包)
3. [离线环境：部署](#3-离线环境部署)
4. [PROFILE 向量库切换](#4-profile-与向量库切换)
5. [运维操作](#5-运维操作)
6. [常见问题](#6-常见问题)

---

## 1. 工作流

```
┌────────────────────────┐                  ┌──────────────────────────┐
│  在线机器 (有外网)      │                  │  离线服务器 (无外网)       │
│                        │                  │                          │
│  1. clone dify 项目    │                  │  4. 上传离线包             │
│     git clone ...      │                  │  5. 解压                  │
│                        │                  │  6. bash load_dify.sh    │
│  2. bash pack_dify.sh  │  ── tar.gz ──>   │  7. bash install_dify.sh│
│     (解析 compose)     │                  │     (直接 docker compose) │
│     (拉镜像 + 导出)    │                  │                          │
│  3. 产出离线包          │                  │                          │
└────────────────────────┘                  └──────────────────────────┘
```

**核心设计**：
- 镜像打包与 Dify 部署**完全解耦**
- 加载镜像后直接用 dify 项目的 `docker-compose.yaml` 启动
- 不会因为 Dify 版本升级而失效（只跟着 compose 中 `image:` 字段走）

---

## 2. 在线机器：打包

### 2.1 准备 dify 项目

```bash
# 已经 clone 在 /opt/install/dify
ls /opt/install/dify/docker/
# docker-compose.yaml  docker-compose.middleware.yaml  .env.example  ...

# 或者重新 clone
cd /opt/install
git clone --branch 1.16.0-rc1 https://github.com/langgenius/dify.git
```

### 2.2 执行打包

```bash
cd /opt/install/offline-dify/scripts

# === 默认 (core 模式: 12 个核心镜像, weaviate 向量库) ===
bash pack_dify.sh

# === 全量 (full 模式: 34 个镜像, 所有可选向量库) ===
PROFILE=full bash pack_dify.sh

# === 切换向量库 ===
VECTOR_STORE=qdrant    bash pack_dify.sh   # Qdrant
VECTOR_STORE=milvus    bash pack_dify.sh   # Milvus (含 etcd/minio)
VECTOR_STORE=chroma    bash pack_dify.sh   # Chroma
VECTOR_STORE=pgvector  bash pack_dify.sh   # pgvector
VECTOR_STORE=opensearch bash pack_dify.sh  # OpenSearch

# === 其他选项 ===
DIFY_DIR=/path/to/dify bash pack_dify.sh    # 指定 dify 项目目录
FORCE_PULL=1 bash pack_dify.sh              # 强制重新拉取
CONF_FILE=/path/to/extra.conf bash pack_dify.sh   # 追加自定义镜像
```

### 2.3 产出

```
bundle/${ARCH}/dify/
└── offline-dify-aarch64-20260713132801.tar.gz   (~2.6G for core)
└── offline-dify-aarch64-20260713132801.tar.gz.sha256
```

**包内结构**：
```
offline-dify-aarch64/
├── images/
│   ├── images.list                         # 12 个镜像清单
│   ├── sha256sum.txt
│   ├── langgenius_dify-api_1.16.0-rc1.tar
│   ├── langgenius_dify-web_1.16.0-rc1.tar
│   ├── langgenius_dify-sandbox_0.2.15.tar
│   ├── langgenius_dify-plugin-daemon_0.6.3-local.tar
│   ├── langgenius_dify-agent-backend_1.16.0-rc1.tar
│   ├── langgenius_dify-agent-local-sandbox_1.16.0-rc1.tar
│   ├── postgres_15-alpine.tar
│   ├── redis_6-alpine.tar
│   ├── semitechnologies_weaviate_1.27.0.tar
│   ├── ubuntu_squid_latest.tar
│   ├── nginx_latest.tar
│   └── certbot_certbot.tar
├── scripts/
│   ├── load_dify.sh                        # 离线镜像导入
│   └── install_dify.sh                     # 一键启动
├── VERSION.txt
└── sha256sum.txt
```

---

## 3. 离线环境：部署

### 3.1 前置条件

```bash
# 1. Docker 已安装
docker --version   # 期望 29.x
docker compose version   # 期望 v2.36.x

# 2. dify 项目源码已 clone (load 脚本会调用 dify 项目的 docker-compose)
cd /opt/install
git clone --branch 1.16.0-rc1 https://github.com/langgenius/dify.git
# 或从已下载的 dify 包中复制
```

### 3.2 一键部署

```bash
# 1. 上传离线包 (假设已传到 /opt/install/)
ls /opt/install/offline-dify-aarch64-*.tar.gz

# 2. 解压
cd /opt/install
tar xzf offline-dify-aarch64-*.tar.gz
cd offline-dify-aarch64

# 3. 加载镜像到本地 docker
bash scripts/load_dify.sh
# 期望输出: 12 个镜像全部 imported, sha256 校验通过

# 4. 启动 Dify
bash scripts/install_dify.sh
# - 首次会从 dify/docker/.env.example 复制 .env
# - 自动处理 volumes 目录
# - docker compose up -d

# 5. 等待启动 (~30-60s)
docker compose -f /opt/install/dify/docker/docker-compose.yaml ps
# 期望所有服务 healthy 或 up
```

### 3.3 访问 Dify

```bash
# 默认端口 (从 dify/docker/.env 中 EXPOSE_NGINX_PORT)
http://<host>:80

# 首次访问:
# - 设置管理员邮箱
# - 设置密码
# - 登录后即可使用
```

---

## 4. PROFILE 与向量库切换

### 4.1 PROFILE 模式

| PROFILE | 镜像数 | 说明 |
|---------|--------|------|
| `core` (默认) | 12 | Dify 核心 + postgres + redis + weaviate + squid + nginx + certbot |
| `full` | 34 | 全部从 compose 解析的镜像 (含所有向量库) |

```bash
PROFILE=core bash pack_dify.sh   # 适合生产 (只装一个向量库)
PROFILE=full bash pack_dify.sh   # 适合 PoC (允许切换)
```

### 4.2 向量库切换

**离线环境**切换（修改 `.env`）：

```bash
cd /opt/install/dify/docker
vim .env
# 设置 VECTOR_STORE=qdrant    # 可选: weaviate|qdrant|milvus|chroma|pgvector|opensearch|oceanbase

# 重启
docker compose down
docker compose up -d
```

**重要**：切换向量库后，需要先重新 `pack_dify.sh` 拉取新向量库的镜像（如果之前没拉）。

### 4.3 镜像来源

`pack_dify.sh` 解析以下两个 docker-compose 文件：

| 文件 | 服务数 | 说明 |
|------|--------|------|
| `dify/docker/docker-compose.yaml` | 34 | 主 compose (含所有可选服务) |
| `dify/docker/docker-compose.middleware.yaml` | 7 | 中间件 (postgres/redis/etc) |

`build:` 指令定义的服务被自动跳过（如 `couchbase-server`），因为离线环境无源码。

---

## 5. 运维操作

### 5.1 启动/停止/状态

```bash
# 启动
bash scripts/install_dify.sh                # ACTION=up (默认)
# 或
ACTION=up bash scripts/install_dify.sh

# 停止
ACTION=down bash scripts/install_dify.sh

# 状态
ACTION=status bash scripts/install_dify.sh

# 实时日志
ACTION=logs bash scripts/install_dify.sh

# 完全清理 (含 volumes, 不可恢复)
ACTION=reset bash scripts/install_dify.sh
```

### 5.2 升级 Dify

```bash
# 1. 停止服务
ACTION=down bash scripts/install_dify.sh

# 2. 升级 dify 源码
cd /opt/install
git -C dify pull origin 1.16.0-rc1  # 或切换 tag

# 3. 重新打包镜像 (PROFILE=full 拉取新镜像)
cd offline-dify/scripts
FORCE_PULL=1 bash pack_dify.sh

# 4. 重新部署
cd /opt/install/offline-dify-aarch64
bash scripts/load_dify.sh
bash scripts/install_dify.sh
```

### 5.3 数据持久化

所有数据持久化到 dify 项目的 `volumes/`：

| 路径 | 内容 |
|------|------|
| `dify/docker/volumes/db/data/` | Postgres 数据库 |
| `dify/docker/volumes/redis/data/` | Redis 数据 |
| `dify/docker/volumes/weaviate/` | Weaviate 向量索引 |
| `dify/docker/volumes/app/storage/` | Dify 上传的文件 |
| `dify/docker/volumes/nginx/` | nginx 配置 + 证书 + 日志 |

**备份建议**：
```bash
tar czf dify-backup-$(date +%Y%m%d).tar.gz \
  /opt/install/dify/docker/volumes/db \
  /opt/install/dify/docker/volumes/redis \
  /opt/install/dify/docker/volumes/weaviate \
  /opt/install/dify/docker/volumes/app
```

---

## 6. 常见问题

### 6.1 pack_dify.sh 报 "no such file: docker-compose.yaml"

**原因**：DIFY_DIR 指向了错误的目录，或 dify 项目未 clone。

**解决**：
```bash
# 确认 dify 项目结构
ls /opt/install/dify/docker/docker-compose.yaml
# 或指定其他目录
DIFY_DIR=/path/to/dify bash pack_dify.sh
```

### 6.2 load_dify.sh 报 "docker daemon 未运行"

**解决**：
```bash
systemctl status docker
systemctl start docker
```

### 6.3 install_dify.sh 报 "找不到 dify 项目"

**原因**：DIFY_DIR 未设置且默认 /opt/install/dify 不存在。

**解决**：
```bash
export DIFY_DIR=/path/to/dify
bash scripts/install_dify.sh
```

### 6.4 docker compose up -d 报 "image not found"

**原因**：load_dify.sh 没跑成功，或 docker daemon 重启后丢失镜像。

**解决**：
```bash
# 重新加载
bash scripts/load_dify.sh
docker images | grep dify   # 确认镜像存在
```

### 6.5 向量库切换后服务起不来

**原因**：未加载新向量库的镜像。

**解决**：
```bash
# 在线机器重新打包 (指定新向量库)
VECTOR_STORE=qdrant PROFILE=full bash pack_dify.sh

# 离线机器重新加载
bash scripts/load_dify.sh
bash scripts/install_dify.sh
```

### 6.6 端口冲突

修改 `dify/docker/.env`：
```bash
EXPOSE_NGINX_PORT=8080        # 默认 80
EXPOSE_NGINX_SSL_PORT=8443    # 默认 443
EXPOSE_POSTGRES_PORT=5433     # 默认 5432
EXPOSE_REDIS_PORT=6379        # 默认 6379
SSRF_PROXY_PORT=3129          # 默认 3128
```

---

## 7. 与 Dify K8s 部署的关系

| 维度 | offline-dify (本项目) | Dify Helm/K8s |
|------|---------------------|---------------|
| **部署方式** | docker-compose | K8s Deployment + Service |
| **镜像打包** | `pack_dify.sh` 解析 compose | Helm chart 自带镜像 |
| **适用** | 单机/小规模生产 | 大规模/多副本 |
| **数据持久化** | bind mount to volumes/ | PVC |
| **高可用** | 手动扩展 | HPA/多副本 |
| **复杂度** | 低 | 高 |

**本项目是单机 docker-compose 方案**。如果需要 K8s 部署，请参考 [Dify 官方 K8s 部署文档](https://docs.dify.ai/getting-started/install-self-hosted/kubernetes)。

## 8. 关键文件

| 文件 | 用途 |
|------|------|
| `/opt/install/offline-dify/scripts/pack_dify.sh` | 在线: 拉取+打包 |
| `/opt/install/offline-dify/scripts/load_dify.sh` | 离线: docker load |
| `/opt/install/offline-dify/scripts/install_dify.sh` | 离线: 启动 Dify |
| `/opt/install/offline-dify/images/` | 镜像 tar 暂存 |
| `/opt/install/bundle/${ARCH}/dify/` | 离线包输出 |
| `/opt/install/dify/docker/.env` | Dify 配置 (密码/端口) |
| `/opt/install/dify/docker/volumes/` | 数据持久化 |
