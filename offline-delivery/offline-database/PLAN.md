# 独立数据库/中间件离线包

此目录只负责数据库/中间件，不包含 Docker Engine，不包含 K8s。

目录结构:

- `images/`: Docker 镜像 tar
  - `mysql_8.4.tar`
  - `redis_latest.tar`
  - `vesoft_nebula-metad_v3.8.0.tar`
  - `vesoft_nebula-storaged_v3.8.0.tar`
  - `vesoft_nebula-graphd_v3.8.0.tar`
- `compose/mysql/`: MySQL 8.4 compose
- `compose/redis/`: Redis compose
- `compose/nebulagraph/`: NebulaGraph 3.8 compose
- `third-party/`: 非 Docker tar 包占位
  - `doris/`: 放 `doris-版本.tar.gz`，部署为 `/opt/doris-版本`，软链 `/opt/doris`
  - `elasticsearch/`: 放 `elasticsearch-版本-linux-aarch64.tar.gz`，部署为 `/opt/elasticsearch-版本`，软链 `/opt/es`
  - `jdk/`: 放 `jdk-版本-linux-aarch64.tar.gz`，部署为 `/opt/jdk-版本` 或 `/opt/jdk`
  - `nebula-graph/`: NebulaGraph 3.8 服务端 tar 包占位，软链 `/opt/nebula-graph`
  - `nebula-dashboard/`: Nebula Dashboard tar 包占位，软链 `/opt/nebula-dashboard`
  - `nebula-studio/`: Nebula Studio tar 包占位，软链 `/opt/nebula-studio`
- `scripts/`: 镜像导入、tar 包占位安装、打包脚本

目标服务器使用顺序:

```bash
# 1. 先安装 Docker 独立包
cd /opt/offline-docker-aarch64
./scripts/install_docker_offline.sh

# 2. 再安装数据库包
cd /opt/offline-database-aarch64
./scripts/load_database_images.sh
cd compose/mysql && docker compose up -d
cd ../redis && docker compose up -d
cd ../nebulagraph && docker compose up -d

# 3. 如有 ES/Doris/JDK tar 包
cd /opt/offline-database-aarch64
./scripts/install_third_party_placeholders.sh

# 4. 如有 NebulaGraph Dashboard/Studio/服务端 tar 包
./scripts/install_nebula_third_party.sh
```
