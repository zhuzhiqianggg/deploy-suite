# Elasticsearch 目录占位

该目录用于放置 Elasticsearch 离线 tar 包（如 `elasticsearch-<version>.tar.gz`）。

将 tar 包放入本目录后，执行 `scripts/install_third_party_placeholders.sh` 会自动解压到 `/opt/elasticsearch-<version>` 并创建软链接 `/opt/es`。

目录约定：

- `/opt/elasticsearch-<version>`：实际目录
- `/opt/es`：软链接
