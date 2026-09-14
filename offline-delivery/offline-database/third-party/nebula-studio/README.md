# Nebula Studio 占位

将 Nebula Studio 离线包放到本目录，例如：

- `nebula-studio-*.tar.gz`
- 或已解压目录 `nebula-studio/`

执行 `scripts/install_nebula_third_party.sh` 后部署为：

- `/opt/nebula-studio-<version>` 或 `/opt/nebula-studio`
- 软链接：`/opt/nebula-studio`

如果后续采用 Docker 镜像方式，也统一将镜像 tar 放入 `images/`，不要放入 K8s 或 Docker 安装包目录。
