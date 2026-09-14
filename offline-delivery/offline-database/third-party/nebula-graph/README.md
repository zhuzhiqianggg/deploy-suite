# NebulaGraph 3.8 目录占位

该目录用于放置 NebulaGraph 服务端离线包或已解压目录。

支持两种方式:

1. Docker Compose 方式：优先使用 `compose/nebulagraph/docker-compose.yml`。
2. tar 包方式：将 `nebula-graph-*.tar.gz` 放到本目录，执行 `scripts/install_nebula_third_party.sh` 后部署到 `/opt/nebula-graph`。

目录约定:

- `/opt/nebula-graph-<version>`：实际目录
- `/opt/nebula-graph`：软链接
- 数据目录：`/data/nebulagraph`
