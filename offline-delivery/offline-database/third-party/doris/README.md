# Doris 目录占位

该目录用于放置 Apache Doris 离线 tar 包（如 `apache-doris-<version>.tar.gz`）。

将 tar 包放入本目录后，执行 `scripts/install_third_party_placeholders.sh` 会自动解压到 `/opt/doris-<version>` 并创建软链接 `/opt/doris`。

目录约定：

- `/opt/doris-<version>`：实际目录
- `/opt/doris`：软链接
