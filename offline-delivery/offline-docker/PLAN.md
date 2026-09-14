# 独立 Docker 离线安装包

只负责 Docker Engine / Docker Compose 安装，不包含 K8s，不包含数据库镜像。

目录:
- `pkgs/`: 放 `docker-29.6.0.tgz` 或 `docker-29.6.0.tar`
- `bin/`: 放 `docker-compose` Linux aarch64 二进制
- `scripts/install_docker_offline.sh`: 离线安装 Docker
- `scripts/package_docker_bundle.sh`: 导出 Docker 离线包

目标服务器安装:

```bash
cd /opt/offline-docker-aarch64
./scripts/install_docker_offline.sh
```
