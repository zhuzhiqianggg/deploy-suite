#!/usr/bin/env bash
# =============================================================================
# 数据库套件一键部署（纯 manifests，无 helm）
# 用法：./deploy.sh [namespace] [target]
#   namespace  默认 db-lianantech-hk-release（换集群部署只改这个参数）
#   target     all | mysql | redis | kafka | es | nebula | minio（默认 all）
# 示例：
#   ./deploy.sh                                # 默认 ns 全量部署
#   ./deploy.sh db-lianantech-hk-poc           # 换 ns 全量部署
#   ./deploy.sh db-lianantech-hk-poc mysql     # 换 ns 只部署 MySQL
# 前置条件：
#   1. 本机 NFS 服务可用（nfs-kernel-server），脚本会创建 /data/nfs/{ns}/{ns}-pvc
#   2. 镜像已通过 images-manager.sh 注入本机 containerd（或节点可在线拉取）
# =============================================================================
set -euo pipefail

DEFAULT_NS="db-lianantech-hk-release"
NS="${1:-$DEFAULT_NS}"
TARGET="${2:-all}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

command -v kubectl >/dev/null 2>&1 || { echo "错误: 未找到 kubectl"; exit 1; }

# 渲染：把模板 ns 替换为目标 ns（资源名/PV 路径内嵌 ns 一并替换）
render() { sed "s/${DEFAULT_NS}/${NS}/g" "$1"; }

apply_file() {
    echo ">>> apply: ${1#$DIR/}"
    render "$1" | kubectl apply -f -
}

echo "=== 数据库套件部署 namespace=${NS} target=${TARGET} ==="

# 1. 公共资源：命名空间 → 存储(SC/PV/PVC) → RBAC → 镜像凭据 → 数据库账号
apply_file "$DIR/common/00-namespace.yaml"
apply_file "$DIR/common/05-storage.yaml"
apply_file "$DIR/common/10-rbac.yaml"
apply_file "$DIR/common/10-secret-registry.yaml"
apply_file "$DIR/common/12-secret-database.yaml"

# 2. NFS 宿主机目录（05-storage 的 PV path 指向 /data/nfs/{ns}/{ns}-pvc）
if [ ! -d "/data/nfs/${NS}/${NS}-pvc" ]; then
    echo ">>> 创建 NFS 目录 /data/nfs/${NS}/${NS}-pvc"
    sudo mkdir -p "/data/nfs/${NS}/${NS}-pvc"
fi

# 3. 数据库（文件内已按 Secret→ConfigMap→StatefulSet/Deployment→Service→exporter 顺序编排）
case "$TARGET" in
    mysql)  apply_file "$DIR/mysql/mysql-standalone.yaml" ;;
    redis)  apply_file "$DIR/redis/redis-standalone.yaml" ;;
    kafka)  apply_file "$DIR/kafka/kafka-standalone.yaml" ;;
    es)     apply_file "$DIR/elasticsearch/elasticsearch-cluster.yaml" ;;
    nebula) apply_file "$DIR/nebulagraph/nebula-cluster.yaml" ;;
    minio)  apply_file "$DIR/minio/minio-standalone.yaml" ;;
    all)
        apply_file "$DIR/mysql/mysql-standalone.yaml"
        apply_file "$DIR/redis/redis-standalone.yaml"
        apply_file "$DIR/kafka/kafka-standalone.yaml"
        apply_file "$DIR/elasticsearch/elasticsearch-cluster.yaml"
        apply_file "$DIR/nebulagraph/nebula-cluster.yaml"
        apply_file "$DIR/minio/minio-standalone.yaml"
        ;;
    *)
        echo "错误: 未知 target '${TARGET}'（可选 all|mysql|redis|kafka|es|nebula|minio）"
        exit 1
        ;;
esac

echo "=== 部署命令执行完成，Pod 就绪验证: kubectl get pods -n ${NS} -w ==="
