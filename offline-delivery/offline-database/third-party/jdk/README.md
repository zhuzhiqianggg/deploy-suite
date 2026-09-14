# JDK 目录占位

该目录用于放置 JDK 离线 tar 包（如 `jdk-<version>.tar.gz`）。

将 tar 包放入本目录后，执行 `scripts/install_third_party_placeholders.sh` 会自动解压到 `/opt/jdk-<version>` 并创建软链接 `/opt/jdk`。

目录约定：

- `/opt/jdk-<version>`：实际目录
- `/opt/jdk`：软链接
