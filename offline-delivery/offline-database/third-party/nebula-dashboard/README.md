# Nebula Dashboard 占位

将 Nebula Dashboard 离线包放到本目录，例如：

- `nebula-dashboard-*.tar.gz`
- 或已解压目录 `nebula-dashboard/`

执行 `scripts/install_nebula_third_party.sh` 后部署为：

- `/opt/nebula-dashboard-<version>` 或 `/opt/nebula-dashboard`
- 软链接：`/opt/nebula-dashboard`

systemd 服务模板后续根据实际启动命令补充。
