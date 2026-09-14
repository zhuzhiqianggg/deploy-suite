#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Apache Doris install.sh — 二进制直装, 不进 K8s
# 前置条件: 已在所有目标节点上安装好 JDK 17+, MySQL 客户端等
# ============================================================

DORIS_VERSION="2.1.8"
DORIS_HOME="/opt/apache-doris"
K8S_NS="database"  # 引用: Doris 不走 K8s, 此变量保留为风格一致

echo "==========================================="
echo "  Apache Doris ${DORIS_VERSION} 二进制安装"
echo "  (非 K8s 部署) namespace=${K8S_NS}"
echo "==========================================="

# 注: Doris (FE+BE) 作为二进制直接部署在宿主机或 VM 上
# - 下载: https://doris.apache.org/zh-CN/download
# - 部署文档: https://doris.apache.org/zh-CN/docs/install/cluster-deployment/
# - 与 MySQL 共存时确保端口不冲突 (FE 默认 9030/8030)

cat <<'EOF'
# 快速安装指南
# 1) 下载 Doris
wget https://apache-doris-releases.oss-accelerate.aliyuncs.com/apache-doris-2.1.8-bin.tar.gz
tar xf apache-doris-2.1.8-bin.tar.gz -C /opt/
ln -s /opt/apache-doris-2.1.8-bin /opt/apache-doris

# 2) 配置 FE
vim ${DORIS_HOME}/fe/conf/fe.conf   # priority_networks, meta_dir

# 3) 启动 FE
cd ${DORIS_HOME}/fe && ./bin/start_fe.sh --daemon

# 4) 配置 BE
vim ${DORIS_HOME}/be/conf/be.conf   # priority_networks, storage_root_path

# 5) 添加 BE 并启动
mysql -h <FE_IP> -P 9030 -u root -e "ALTER SYSTEM ADD BACKEND '<BE_IP>:9050';"
cd ${DORIS_HOME}/be && ./bin/start_be.sh --daemon

# 6) 停止
./bin/stop_be.sh
./bin/stop_fe.sh
EOF
